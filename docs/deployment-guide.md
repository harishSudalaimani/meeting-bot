# Step-by-step deployment guide

This guide walks through a manual first deployment. It creates AWS resources only when you run the gated `--apply` commands and type their confirmation phrases. I have not deployed anything for you. Read [the cost estimate](cost-estimate.md) first; EKS, NAT, ALB, WAF, and the baseline node continue to cost money while idle.

## 1. Install the local tools

Use a workstation with AWS CLI v2, Terraform 1.9 or later, `kubectl`, Docker, Git, Python 3, `jq`, `curl`, `dig`, OpenSSL, and `envsubst` (`gettext`). Terraform must be able to reach the Terraform Registry and Helm repositories during setup.

```bash
aws --version
terraform version
kubectl version --client
docker version
git --version
```

The first four commands should print installed versions. If a command is missing, install it for your OS before continuing. Do not put AWS access keys in this project.

## 2. Put the project in your GitHub repository

Create an empty GitHub repository, then from this project directory initialize and push the source. Skip `git init` if you already initialized this project.

```bash
cd /home/harish/Documents/meetstream/meeting-bot-platform
git init -b main
git add .
git commit -m "Build EKS meeting-bot learning platform"
git remote add origin https://github.com/OWNER/REPOSITORY.git
git push -u origin main
```

Confirm the source is on the repository's `main` branch. For private repositories, you will also configure read access for Argo CD before connecting GitOps in step 8.

## 3. Sign in to the intended AWS account

For an AWS IAM Identity Center profile, use the browser-based login:

```bash
aws configure sso --profile meeting-bot
aws sso login --profile meeting-bot
export AWS_PROFILE=meeting-bot
export AWS_REGION=ap-south-1
aws sts get-caller-identity
```

Check that the account ID and assumed role are the account where you intend to create the demo. If they are wrong, stop and select the correct profile. The project scripts only use the normal AWS credential chain; they do not read credentials from the repository.

## 4. Set the account-specific Terraform inputs

```bash
cd terraform/environments/learning
cp terraform.tfvars.example terraform.tfvars
${EDITOR:-nano} terraform.tfvars
```

Set the existing **public** hosted-zone ID and domain, your API subdomain, and your current public IPv4 CIDR with `/32` in `admin_cidrs`. Set `owner_tag`; optionally set `budget_alert_email`. Leave all delivery settings empty unless the destination role and bucket policy are already prepared.

If you want the GitHub Actions publisher, set `github_repository = "OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID"` now, before Terraform creates the IAM role. Otherwise leave it empty and use the manual image publishing command in step 7. Never commit `terraform.tfvars`; it is gitignored.

## 5. Review costs, run preflight, and inspect the plan

Read [`cost-estimate.md`](cost-estimate.md). The estimate assumes one `t3a.xlarge` baseline and up to four `t3a.large` Karpenter nodes. T3a uses burstable CPU credits, which can add charges if average CPU stays above its baseline.

From the project root, run the read-only preflight explicitly:

```bash
scripts/preflight.sh ZONE_ID example.com api.example.com ap-south-1
```

It prints the active AWS identity and checks the hosted zone, dedicated hostname, three selected AZs, T3a offerings, EKS support, and vCPU quota. It must end with `Preflight passed`. It changes no AWS resources. `scripts/deploy.sh` repeats this check before planning.

From the project root, create a plan:

```bash
cd /home/harish/Documents/meetstream/meeting-bot-platform
scripts/deploy.sh
terraform -chdir=terraform/environments/learning show -no-color tfplan
```

The first command initializes and validates Terraform, creates the plan, and stops. Review every resource and any replacement or deletion in the `terraform show` output. It should use your existing Route 53 zone and add records only for the configured API host and ACM validation. If the plan is unexpected, do not apply it; fix the inputs or code and plan again.

## 6. Create the infrastructure and cluster add-ons

Only continue after you are satisfied with the account, cost estimate, preflight, and plan.

```bash
scripts/deploy.sh --apply
```

The script repeats preflight and planning. It displays the infrastructure plan and waits for you to type exactly `APPLY <cluster-name>`; the default is `APPLY meeting-bot-learning`. After the first stack applies, it updates kubeconfig and plans add-ons. Review that add-on plan. The second confirmation is `APPLY ADDONS <cluster-name>`. Only after that does it install the pinned Gateway API CRDs and add-ons. Do not type either phrase if a plan contains changes you do not expect.

Success looks like the script reporting `Platform provisioned`, and these commands showing one Ready baseline node and system Pods becoming Ready:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get gatewayclass
```

If Terraform cannot reach `registry.terraform.io`, fix workstation network access and rerun `scripts/deploy.sh`; no AWS changes occur before the first typed confirmation. If nodes do not join, follow the IAM/access-entry and subnet checks in [`troubleshooting.md`](troubleshooting.md).

## 7. Create secrets and publish the four application images

The script `deploy.sh` already configures kubeconfig; this is safe to repeat if your shell changed:

```bash
aws eks update-kubeconfig --region ap-south-1 --name meeting-bot-learning
scripts/create-api-secrets.sh
scripts/build-push.sh "bootstrap-$(date +%Y%m%d%H%M%S)"
```

`create-api-secrets.sh` creates a random API token and short-lived backend TLS certificate under gitignored `.local/`, then installs them as Kubernetes Secrets. `build-push.sh` builds and pushes the four images to the project's ECR repositories and fills `kubernetes/chart/values-learning.yaml` with your real image, certificate, WAF, and hostname values.

Review the generated values file, then commit and push it:

```bash
git diff -- kubernetes/chart/values-learning.yaml
git add kubernetes/chart/values-learning.yaml
git commit -m "Configure learning cluster images and endpoint"
git push
```

Do not commit `.local/`, tokens, certificates, Terraform state, or `terraform.tfvars`. The API bearer token is in `.local/api-token`; treat it like a password.

## 8. Connect Argo CD to the GitOps repository

For a private repository, configure the repository credentials in Argo CD first without putting the password/token in shell history or Git. Then apply the project Application:

```bash
scripts/connect-gitops.sh https://github.com/OWNER/REPOSITORY.git
kubectl -n argocd get application meeting-bot-platform -w
kubectl -n meeting-bot get pods -w
kubectl -n meeting-bot get gateway,httproute
```

The Application should become `Synced` and `Healthy`; the API, controller, delivery worker, and collector Pods should be Ready. The Gateway should gain an ALB address. Wait for ExternalDNS and ACM to finish, then verify:

```bash
curl --fail --show-error https://api.example.com/healthz
```

HTTP `204` is the expected health response. If Gateway, DNS, or target health is not ready, see the Gateway and DNS section in [`troubleshooting.md`](troubleshooting.md).

## 9. Run the end-to-end workflow

```bash
tests/integration/e2e.sh
```

This creates sample jobs and artifacts. It checks DNS, HTTPS, WAF and ALB health, request validation, idempotency, DynamoDB persistence, job completion, S3 upload and download, and cancellation. The script reports pass only when each check succeeds. It needs AWS CLI, `curl`, `dig`, `jq`, `kubectl`, and Terraform.

To submit and inspect smaller manual requests, use `scripts/submit-bots.sh` and `scripts/inspect.sh`. The meeting bot is a simulator: it writes a text artifact and does not join a real meeting service.

## 10. Destroy the demo when finished

Download any artifacts you want to keep first. Delete the Argo Application so its finalizer removes the Gateway and other chart resources:

```bash
kubectl -n argocd delete application meeting-bot-platform
kubectl -n argocd wait --for=delete application/meeting-bot-platform --timeout=10m
```

Wait for the command to report that the Application was deleted. Give ExternalDNS and the ALB controller time to remove the API records and ALB, then run:

```bash
scripts/teardown.sh
```

It lists project-tagged resources and refuses to continue while jobs, Karpenter nodes, the Application, Gateway/ALB, or API-host records remain. Review the list and type exactly `DELETE meeting-bot-learning` when prompted. Teardown preserves your Route 53 hosted zone and unrelated records, but empties and deletes this project's artifact bucket. Review the final leftover-resource report and keep Terraform state until cleanup is confirmed.
