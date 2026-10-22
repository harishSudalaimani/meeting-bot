data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_ssm_parameter" "recommended_ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2023/x86_64/standard/recommended"
}

locals {
  partition      = data.aws_partition.current.partition
  account        = data.aws_caller_identity.current.account_id
  oidc_host      = trimprefix(aws_iam_openid_connect_provider.eks.url, "https://")
  node_role_name = "${var.name}-karpenter-node"
  irsa_trusts = {
    api                      = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:meeting-bot:api" } } }] })
    controller               = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:meeting-bot:controller" } } }] })
    meeting_bot              = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:meeting-bot:meeting-bot" } } }] })
    delivery                 = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:meeting-bot:delivery-worker" } } }] })
    otel_collector           = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:observability:otel-collector" } } }] })
    load_balancer_controller = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller" } } }] })
    external_dns             = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:external-dns" } } }] })
  }
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 7
  tags              = var.common_tags
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-control-plane"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = var.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs
  }
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  depends_on                = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
  tags                      = var.common_tags
}

resource "aws_ec2_tag" "cluster_security_group_discovery" {
  for_each    = toset(["karpenter.sh/discovery", "kubernetes.io/cluster/${var.name}"])
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = each.value
  value       = each.value == "karpenter.sh/discovery" ? var.name : "owned"
}

resource "aws_iam_role" "baseline_node" {
  name               = "${var.name}-baseline-node"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = var.common_tags
}

resource "aws_iam_role_policy_attachment" "baseline" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  ])
  role       = aws_iam_role.baseline_node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "baseline" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "baseline"
  node_role_arn   = aws_iam_role.baseline_node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = ["t3a.xlarge"]
  capacity_type   = "ON_DEMAND"
  ami_type        = "AL2023_x86_64_STANDARD"
  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }
  update_config { max_unavailable = 1 }
  labels = { "workload" = "platform" }
  # EKS creates the node access mapping for managed node groups itself.
  depends_on = [aws_iam_role_policy_attachment.baseline]
  tags       = var.common_tags
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = "v1.22.4-eksbuild.3"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.baseline]
  tags                        = var.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = "v1.14.7-eksbuild.10"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.baseline]
  tags                        = var.common_tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = "v1.36.0-eksbuild.21"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.baseline]
  tags                        = var.common_tags
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da0afd10d33"]
  tags            = var.common_tags
}

resource "aws_iam_role" "karpenter_node" {
  name               = local.node_role_name
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = var.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

resource "aws_iam_role" "karpenter_controller" {
  name = "${var.name}-karpenter-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = {
      StringEquals = { "${local.oidc_host}:aud" = "sts.amazonaws.com", "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:karpenter" }
    } }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.name}-karpenter-controller"
  role = aws_iam_role.karpenter_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:RunInstances", "ec2:CreateFleet"], Resource = ["arn:${local.partition}:ec2:${var.region}::image/*", "arn:${local.partition}:ec2:${var.region}::snapshot/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:security-group/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:subnet/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:capacity-reservation/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:placement-group/*"] },
      { Effect = "Allow", Action = ["ec2:RunInstances", "ec2:CreateFleet"], Resource = "arn:${local.partition}:ec2:${var.region}:${local.account}:launch-template/*", Condition = { StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.name}" = "owned" }, StringLike = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" } } },
      { Effect = "Allow", Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"], Resource = ["arn:${local.partition}:ec2:${var.region}:${local.account}:fleet/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:instance/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:volume/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:network-interface/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:launch-template/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:spot-instances-request/*"], Condition = { StringEquals = { "aws:RequestTag/kubernetes.io/cluster/${var.name}" = "owned", "aws:RequestTag/eks:eks-cluster-name" = var.name }, StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" } } },
      { Effect = "Allow", Action = ["ec2:CreateTags"], Resource = ["arn:${local.partition}:ec2:${var.region}:${local.account}:fleet/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:instance/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:volume/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:network-interface/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:launch-template/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:spot-instances-request/*"], Condition = { StringEquals = { "aws:RequestTag/kubernetes.io/cluster/${var.name}" = "owned", "aws:RequestTag/eks:eks-cluster-name" = var.name, "ec2:CreateAction" = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"] }, StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" } } },
      { Effect = "Allow", Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"], Resource = ["arn:${local.partition}:ec2:${var.region}:${local.account}:instance/*", "arn:${local.partition}:ec2:${var.region}:${local.account}:launch-template/*"], Condition = { StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.name}" = "owned" }, StringLike = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" } } },
      { Effect = "Allow", Action = ["ec2:DescribeImages", "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeLaunchTemplates", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeAvailabilityZones", "ec2:DescribeSpotPriceHistory", "ec2:DescribeInstanceStatus", "ec2:DescribeCapacityReservations"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
      { Effect = "Allow", Action = ["ssm:GetParameter"], Resource = "arn:${local.partition}:ssm:${var.region}::parameter/aws/service/*" },
      { Effect = "Allow", Action = ["pricing:GetProducts", "iam:ListInstanceProfiles"], Resource = "*" },
      { Effect = "Allow", Action = ["iam:GetInstanceProfile"], Resource = "arn:${local.partition}:iam::${local.account}:instance-profile/*" },
      { Effect = "Allow", Action = ["iam:PassRole"], Resource = aws_iam_role.karpenter_node.arn, Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } } },
      { Effect = "Allow", Action = ["iam:CreateInstanceProfile"], Resource = "arn:${local.partition}:iam::${local.account}:instance-profile/*", Condition = { StringEquals = { "aws:RequestTag/kubernetes.io/cluster/${var.name}" = "owned", "aws:RequestTag/eks:eks-cluster-name" = var.name, "aws:RequestTag/topology.kubernetes.io/region" = var.region }, StringLike = { "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*" } } },
      { Effect = "Allow", Action = ["iam:TagInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"], Resource = "arn:${local.partition}:iam::${local.account}:instance-profile/*", Condition = { StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.name}" = "owned", "aws:ResourceTag/topology.kubernetes.io/region" = var.region }, StringLike = { "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*" } } },
      { Effect = "Allow", Action = ["eks:DescribeCluster"], Resource = aws_eks_cluster.this.arn }
    ]
  })
}

resource "aws_iam_role" "api" {
  name               = "${var.name}-api"
  assume_role_policy = local.irsa_trusts.api
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "api" {
  name = "api-data-access"
  role = aws_iam_role.api.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:TransactWriteItems", "dynamodb:Query"], Resource = [var.dynamodb_table_arn, "${var.dynamodb_table_arn}/index/*"] },
    { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = var.request_queue_arn },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.workload_artifact_arn}/artifacts/*" }
  ] })
}

resource "aws_iam_role" "controller" {
  name               = "${var.name}-controller"
  assume_role_policy = local.irsa_trusts.controller
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "controller" {
  name = "controller-data-access"
  role = aws_iam_role.controller.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = var.request_queue_arn },
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = [var.dynamodb_table_arn, "${var.dynamodb_table_arn}/index/*"] }
  ] })
}

resource "aws_iam_role" "meeting_bot" {
  name               = "${var.name}-meeting-bot"
  assume_role_policy = local.irsa_trusts.meeting_bot
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "meeting_bot" {
  name = "meeting-bot-data-access"
  role = aws_iam_role.meeting_bot.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:UpdateItem", "dynamodb:GetItem"], Resource = var.dynamodb_table_arn },
    { Effect = "Allow", Action = ["s3:PutObject", "s3:AbortMultipartUpload"], Resource = "${var.workload_artifact_arn}/artifacts/*" },
    { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = var.delivery_queue_arn }
  ] })
}

resource "aws_iam_role" "delivery" {
  name               = "${var.name}-delivery"
  assume_role_policy = local.irsa_trusts.delivery
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "delivery" {
  name = "delivery-data-access"
  role = aws_iam_role.delivery.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = var.delivery_queue_arn },
    { Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = var.dynamodb_table_arn },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.workload_artifact_arn}/artifacts/*" }
  ], var.delivery_destination_role_arn == "" ? [] : [{ Effect = "Allow", Action = ["sts:AssumeRole"], Resource = var.delivery_destination_role_arn }]) })
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${var.name}-load-balancer-controller"
  assume_role_policy = local.irsa_trusts.load_balancer_controller
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "load_balancer_controller" {
  name   = "aws-load-balancer-controller-reference-policy"
  role   = aws_iam_role.load_balancer_controller.id
  policy = file("${path.module}/../../policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.name}-external-dns"
  assume_role_policy = local.irsa_trusts.external_dns
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "external_dns" {
  name = "external-dns-single-zone"
  role = aws_iam_role.external_dns.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets"], Resource = "arn:${local.partition}:route53:::hostedzone/${var.hosted_zone_id}" },
    { Effect = "Allow", Action = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"], Resource = "*" }
  ] })
}

resource "aws_iam_role" "otel_collector" {
  name               = "${var.name}-otel-collector"
  assume_role_policy = local.irsa_trusts.otel_collector
  tags               = var.common_tags
}

resource "aws_iam_role_policy_attachment" "otel_collector" {
  role       = aws_iam_role.otel_collector.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.api_repository != "" && var.github_oidc_provider_arn == "" ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.common_tags
}

locals {
  github_oidc_arn = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : try(aws_iam_openid_connect_provider.github[0].arn, "")
}

resource "aws_iam_role" "ci" {
  count = var.api_repository == "" ? 0 : 1
  name  = "${var.name}-github-ci"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Federated = local.github_oidc_arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com", "token.actions.githubusercontent.com:sub" = "repo:${var.api_repository}:ref:refs/heads/main" } } }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy" "ci" {
  count = var.api_repository == "" ? 0 : 1
  name  = "publish-images-to-ecr"
  role  = aws_iam_role.ci[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart", "ecr:BatchGetImage"], Resource = "arn:${local.partition}:ecr:${var.region}:${local.account}:repository/${var.name}/*" }
  ] })
}

