# Troubleshooting

Start with the read-only overview:

```bash
scripts/inspect.sh
kubectl get events -A --sort-by=.lastTimestamp | tail -50
```

## AWS identity, region, and quotas

- `aws sts get-caller-identity` must show the intended account and role. Do not change profiles mid-deployment.
- Check `terraform.tfvars` region and EKS version. `scripts/preflight.sh` checks the hosted zone, hostname, `t3a.xlarge` and `t3a.large` offerings in three AZs, EKS standard support, and a minimum 12 On-Demand vCPU quota (4 for baseline + 8 elastic).
- If EC2 quota or regional capacity is short, lower the Karpenter cap or request a quota/capacity adjustment before applying. The cap is in `bot_max_nodes_cpu`.

## Terraform state and drift

- `terraform init` issues: confirm network access to the provider registry and that no `.terraform` directory is partially populated; retry `terraform init` after fixing connectivity.
- State lock: first check whether another Terraform process is active. Do not force-unlock an active operation. `terraform force-unlock <LOCK_ID>` is only for a confirmed abandoned lock.
- Plan changes in VPC/EKS/IAM are owned by Terraform. Karpenter EC2 nodes are not declared in Terraform and their variable count is expected. Do not import Karpenter instances. Inspect with `kubectl get nodeclaims` and `aws ec2 describe-instances --filters Name=tag:Project,Values=meeting-bot-platform`.
- For accidental manual changes, inspect `terraform plan` and use `-refresh-only` to understand drift before deciding. Do not accept a destroy/recreate plan without understanding its impact.
- The two roots use separate S3 state keys after the one-time migration. Preserve local state backups until the S3 state and CI plans have been verified; never commit either copy.

## IAM and access entries

- `AccessDenied` from the API usually means its IRSA annotation, OIDC trust `sub`, or scoped IAM action/resource does not match. Check the service account and role ARN:

  ```bash
  kubectl -n meeting-bot get serviceaccount api -o yaml
  kubectl -n meeting-bot describe pod -l app.kubernetes.io/name=bot-api
  ```

- `AccessDenied` from the load balancer controller: inspect `kubectl -n kube-system logs deployment/aws-load-balancer-controller`, compare the policy with the pinned controller's [official IAM policy](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.6.0/docs/install/iam_policy.json), and verify its IRSA trust.
- If a node fails to join, verify the Karpenter node role's `EC2_LINUX` access entry exists (`aws eks list-access-entries --cluster-name meeting-bot-learning --region ap-south-1`). The managed node group's role is auto-mapped by EKS; do not add a duplicate manual entry.
- GitHub OIDC publish failures: verify the trust subject exactly matches `repo:<owner>/<repo>:ref:refs/heads/main`; the image workflow uses `AWS_ROLE_ARN`, which is the ECR-only `ci_role_arn` output. Terraform uses separate environment-scoped plan and apply roles; see [docs/cicd.md](cicd.md).

## Gateway, ALB, certificate, WAF, and DNS

- Check the CRDs and controller before the application:

  ```bash
  kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io loadbalancerconfigurations.gateway.k8s.aws targetgroupconfigurations.gateway.k8s.aws
  kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=150
  kubectl -n meeting-bot describe gateway bot-api
  kubectl -n meeting-bot describe httproute bot-api
  ```

- Gateway `Accepted=False`/`Programmed=False`: check GatewayClass controller name, pinned CRDs, `LoadBalancerConfiguration`, subnet tags, WAF ARN, and certificate ARN. ALB HTTPS requires the certificate in the same AWS region.
- ACM remains `PENDING_VALIDATION`: confirm the existing public zone ID is authoritative and the ACM validation CNAME exists. The configuration refuses to overwrite existing records.
- No Route 53 record: inspect ExternalDNS logs and its IRSA. It must run with `gateway-httproute`, the exact zone ID, exact API hostname filter, and matching Gateway/HTTPRoute name and namespace. Its TXT owner is the cluster name.
- Healthy targets missing: inspect `TargetGroupConfiguration` and `kubectl -n meeting-bot get targetgroupbindings`. The target group should use IP targets and HTTPS health checks to `/healthz`; the Service's port is `8443`.
- Do not edit controller-created ALBs in the console. Fix the Gateway/route configuration and let the controller reconcile it.

## Karpenter capacity and Pods

- Pending meeting Pod: `kubectl -n meeting-bot describe pod -l app.kubernetes.io/name=meeting-bot`; check node selectors/toleration, NodePool CPU limit, memory/CPU requests, and available quota.
- Karpenter provisioning: `kubectl -n kube-system logs deployment/karpenter --tail=200`; inspect `kubectl get nodepools,nodeclaims,ec2nodeclasses`.
- Incorrect subnet discovery: private subnets need both `karpenter.sh/discovery=<cluster-name>` and `kubernetes.io/role/internal-elb=1`; the cluster security group needs the same discovery tag.
- EC2 capacity error: check `t3a.xlarge` and `t3a.large` offerings in three AZs and request an EC2 quota increase if required. This configuration intentionally uses on-demand only.
- Subnet IP exhaustion: inspect private-subnet free IPv4 counts. VPC CNI assigns Pod IPs from subnet addresses; a node can have available CPU and still be unable to place Pods without IPs.
- Instance starts but does not join: inspect the access entry, instance profile/role, SSM connectivity/NAT, cluster endpoint reachability, cluster security group, and AL2023 node bootstrap. Use SSM Session Manager where configured and inspect nodeadm/kubelet logs. `aws eks describe-cluster` should show the private endpoint enabled and the configured admin CIDRs for public endpoint access.
- Two simulator Pods per `t3a.large` is a request-based target only. Check `kubectl describe node <node>` Allocatable/Allocated resources and DaemonSet/system requests; do not infer capacity from EC2's advertised totals.
- Karpenter does not consolidate non-empty bot nodes (`WhenEmpty`). If a node remains after jobs finish, inspect completed/failed Pods, daemonsets, and NodeClaim events. Empty nodes become eligible after five minutes.

## Queue, Jobs, and artifact recovery

- Check queue depth and oldest age:

  ```bash
  aws sqs get-queue-attributes --queue-url "$(terraform -chdir=terraform/environments/learning output -raw request_queue_url)" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage
  aws sqs get-queue-attributes --queue-url "$(terraform -chdir=terraform/environments/learning output -raw request_queue_url)" --attribute-names RedrivePolicy
  ```

- A job in `REQUESTED` may be waiting on the outbox dispatcher/controller. Check controller logs and SQS visible/in-flight counts. `STARTING` with no Job may indicate controller interruption; redeliver the original request event only after verifying the deterministic `meeting-<job-id>` Job does not exist.
- A message in the DLQ exceeded five receives. Read the body, find the matching DynamoDB job, fix the root cause, then redrive. Do not replay `START` after a session is already active.
- Job Pod `ImagePullBackOff`: check immutable image tag, ECR URL, node role ECR pull policy, and NAT egress. `scripts/build-push.sh` requires a new unique tag because ECR tags are immutable.
- `FAILED` upload: inspect bot Pod logs and its S3/DynamoDB IRSA permissions. The bot uploads `artifacts/<job-id>/artifact.txt` with a SHA-256 checksum. Retry is a new job request with a new idempotency key.
- Delivery `FAILED`: inspect delivery-worker logs, destination role trust, `s3:PutObject` destination-prefix policy, bucket owner ID, and source read policy. The worker retries until SQS redrive; source artifacts expire after seven days.
- CloudWatch alarms: check `AWS/SQS` `ApproximateNumberOfMessagesVisible`, request DLQ depth, and the EKS log group `/aws/eks/<cluster>/cluster`. Application JSON logs remain in Pod stdout in this version; use `kubectl logs` or enable a CloudWatch container log pipeline separately.

## API and secret handling

- `401`: `API_TOKEN_FILE` must match `.local/api-token`, and the Kubernetes secret must be in namespace `meeting-bot`.
- TLS/backend health check errors: recreate `bot-api-backend-tls` with `scripts/create-api-secrets.sh`; verify the secret is mounted and the API listens on 8443. The public certificate is on the ALB, not in this secret.
- `409` on `POST /bots` with a reused idempotency key means the key was previously used with a different URL/duration. Use a fresh key.
- The shared bearer token provides single-tenant access. Rotate it by updating the Kubernetes secret; do not commit it or include it in logs.
