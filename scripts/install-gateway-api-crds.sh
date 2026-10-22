#!/usr/bin/env bash
set -euo pipefail

echo "Installing Gateway API v1.6.0 standard CRDs and the AWS LBC v3.6.0 Gateway CRDs."
kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/bases/elbv2.k8s.aws_targetgroupbindings.yaml
kubectl wait --for=condition=Established --timeout=120s crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/loadbalancerconfigurations.gateway.k8s.aws crd/targetgroupconfigurations.gateway.k8s.aws crd/targetgroupbindings.elbv2.k8s.aws
