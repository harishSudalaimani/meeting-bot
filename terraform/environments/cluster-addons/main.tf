locals {
  infra = data.terraform_remote_state.infra.outputs
}

resource "kubernetes_namespace_v1" "meeting_bot" {
  metadata {
    name   = "meeting-bot"
    labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
  }
}

resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name   = "observability"
    labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
  }
}

resource "kubernetes_service_account_v1" "otel_collector" {
  metadata {
    name        = "otel-collector"
    namespace   = kubernetes_namespace_v1.observability.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = local.infra.otel_collector_role_arn }
  }
}

resource "kubernetes_service_account_v1" "api" {
  metadata {
    name        = "api"
    namespace   = kubernetes_namespace_v1.meeting_bot.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = local.infra.api_role_arn }
  }
}

resource "kubernetes_service_account_v1" "controller" {
  metadata {
    name        = "controller"
    namespace   = kubernetes_namespace_v1.meeting_bot.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = local.infra.controller_role_arn }
  }
}

resource "kubernetes_service_account_v1" "meeting_bot" {
  metadata {
    name        = "meeting-bot"
    namespace   = kubernetes_namespace_v1.meeting_bot.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = local.infra.meeting_bot_role_arn }
  }
}

resource "kubernetes_service_account_v1" "delivery" {
  metadata {
    name        = "delivery-worker"
    namespace   = kubernetes_namespace_v1.meeting_bot.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = local.infra.delivery_role_arn }
  }
}

resource "kubernetes_config_map_v1" "app" {
  metadata {
    name      = "meeting-bot-config"
    namespace = kubernetes_namespace_v1.meeting_bot.metadata[0].name
  }
  data = {
    AWS_REGION             = local.infra.region
    JOBS_TABLE             = local.infra.jobs_table_name
    REQUEST_QUEUE_URL      = local.infra.request_queue_url
    DELIVERY_QUEUE_URL     = local.infra.delivery_queue_url
    ARTIFACT_BUCKET        = local.infra.artifact_bucket
    DELIVERY_BUCKET        = local.infra.delivery_bucket
    DESTINATION_ROLE_ARN   = local.infra.delivery_destination_role_arn
    DESTINATION_ACCOUNT_ID = local.infra.delivery_destination_account_id
    AWS_ACCOUNT_ID         = local.infra.account_id
  }
}

resource "kubernetes_role_v1" "controller" {
  metadata {
    name      = "bot-job-controller"
    namespace = kubernetes_namespace_v1.meeting_bot.metadata[0].name
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "controller" {
  metadata {
    name      = "bot-job-controller"
    namespace = kubernetes_namespace_v1.meeting_bot.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.controller.metadata[0].name
    namespace = kubernetes_namespace_v1.meeting_bot.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.controller.metadata[0].name
  }
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.15.0"
  wait       = true
  timeout    = 900
  values = [yamlencode({
    replicas = 1
    settings = {
      clusterName     = local.infra.cluster_name
      clusterEndpoint = local.infra.cluster_endpoint
    }
    serviceAccount = {
      create      = true
      name        = "karpenter"
      annotations = { "eks.amazonaws.com/role-arn" = local.infra.karpenter_controller_role_arn }
    }
    controller = {
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]
}

resource "helm_release" "karpenter_config" {
  name      = "karpenter-config"
  namespace = "kube-system"
  chart     = "../../charts/karpenter-config"
  wait      = true
  values = [yamlencode({
    nodeRoleName = local.infra.karpenter_node_role_name
    amiAlias     = local.infra.karpenter_ami_alias
    clusterName  = local.infra.cluster_name
    region       = local.infra.region
    maxCPU       = local.infra.bot_max_nodes_cpu
    commonTags   = { Project = "meeting-bot-platform", Environment = "learning", ManagedBy = "terraform" }
  })]
  depends_on = [helm_release.karpenter]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.0"
  wait       = true
  timeout    = 600
  values = [yamlencode({
    clusterName = local.infra.cluster_name
    region      = local.infra.region
    vpcId       = local.infra.vpc_id
    serviceAccount = {
      create      = true
      name        = "aws-load-balancer-controller"
      annotations = { "eks.amazonaws.com/role-arn" = local.infra.load_balancer_controller_role_arn }
    }
    enableServiceMutatorWebhook = false
    controllerConfig            = { featureGates = { ALBGatewayAPI = true, NLBGatewayAPI = false } }
  })]
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.19.0"
  wait       = true
  values = [yamlencode({
    provider         = { name = "aws" }
    sources          = ["gateway-httproute"]
    policy           = "sync"
    registry         = "txt"
    txtOwnerId       = local.infra.cluster_name
    gatewayNamespace = "meeting-bot"
    serviceAccount = {
      create      = true
      name        = "external-dns"
      annotations = { "eks.amazonaws.com/role-arn" = local.infra.external_dns_role_arn }
    }
    extraArgs = {
      "namespace"      = "meeting-bot"
      "gateway-name"   = "bot-api"
      "zone-id-filter" = local.infra.hosted_zone_id
    }
    # sync removes records owned by this TXT owner when the Gateway disappears.
    logLevel = "info"
  })]
}

resource "kubernetes_config_map_v1" "otel_collector" {
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    "config.yaml" = <<-YAML
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
      processors:
        batch: {}
      exporters:
        awsxray:
          region: ${local.infra.region}
      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [awsxray]
    YAML
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.5.0"
  wait             = true
  timeout          = 900
  values = [yamlencode({
    dex            = { enabled = false }
    notifications  = { enabled = false }
    applicationSet = { enabled = false }
    server = {
      service = { type = "ClusterIP" }
      ingress = { enabled = false }
    }
    configs = { params = { "server.insecure" = true } }
  })]
}

output "cluster_name" { value = local.infra.cluster_name }
output "api_hostname" { value = local.infra.api_hostname }
