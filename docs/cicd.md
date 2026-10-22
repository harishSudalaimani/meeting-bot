# CI/CD setup

## Application delivery

The application workflow is `.github/workflows/ci-publish.yml`:

1. Pull requests run Go formatting, vet, unit tests, build checks, Terraform validation, Helm lint, and Trivy scans.
2. A merge to `main` builds and scans the four service images, then pushes immutable `git-<commit-sha>` tags to ECR using the existing ECR-only GitHub OIDC role.
3. The workflow opens a pull request updating `kubernetes/chart/values-learning.yaml`.
4. Merge the image update PR; Argo CD follows `main` and synchronizes the chart.

Protect `main` with required CI checks and review. GitHub-hosted CI validates Terraform on pull requests; after a reviewed change is merged, the Terraform workflow produces a saved plan and waits for approval before applying it. Keep image updates as a separate reviewed Git change so Argo CD deploys only the tag recorded in Git.

## Terraform delivery

`.github/workflows/terraform-plan-apply.yml` plans and applies the learning infrastructure root on GitHub-hosted `ubuntu-latest` runners. The `terraform-apply` GitHub Environment gates applying the reviewed plan. GitHub-hosted runners cannot reach this cluster's restricted EKS API, so cluster add-ons remain a manual Terraform plan/apply from your workstation. The application workflow still runs Terraform format and validation for both roots.

The workflow expects these GitHub settings:

- Environments `terraform-plan` and `terraform-apply`, both restricted to the `main` branch. Add required reviewers to `terraform-apply` to gate AWS mutations. The plan runs only after a change is merged to `main`.
- In the `terraform-plan` environment, add a secret named `TERRAFORM_TFVARS` containing the learning stack's `terraform.tfvars` contents. This file is gitignored and includes the hosted zone, domain, and allowed admin CIDRs.
- Environment variable `TF_PLAN_ROLE_ARN` in `terraform-plan`, and `TF_APPLY_ROLE_ARN` in `terraform-apply`.
- Repository variable `TF_CICD_ENABLED=true`, set only after state migration, role creation, and GitHub environment setup are complete. This keeps the Terraform job skipped while those prerequisites are being configured.
- Terraform creates separate IAM roles when `github_repository` is set. The plan role trusts only the `terraform-plan` GitHub environment and receives AWS read-only access plus access to read the learning state and lock it. The apply role trusts only the `terraform-apply` environment and receives `PowerUserAccess`, scoped IAM permissions for this project's roles, and access to update the learning state. Neither role receives Kubernetes API access. This is a learning-account policy; review and further narrow it before using the pattern in a production account. Keep the existing image-publish role separate.

GitHub environment features depend on repository visibility and plan. Private/internal repositories need Pro, Team, or Enterprise for environments and environment secrets; required reviewers on private/internal repositories require Enterprise. If this repository cannot enforce the `terraform-apply` reviewer gate, leave `TF_CICD_ENABLED` unset and keep Terraform applies manual until a protected approval mechanism is available. [GitHub environment plan requirements](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments#who-can-use-this-feature)

Set `github_repository = "harishSudalaimani/meeting-bot"` in the learning Terraform variables before the learning plan. If the account already has the GitHub Actions OIDC provider, set `github_oidc_provider_arn` to its ARN too; otherwise Terraform will try to create a duplicate. Retrieve it with `aws iam list-open-id-connect-providers --profile meeting-bot --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" --output text`. After applying the learning Terraform changes, get the role ARNs with `terraform -chdir=terraform/environments/learning output -raw terraform_plan_role_arn` and `terraform -chdir=terraform/environments/learning output -raw terraform_apply_role_arn`. Set each value as the matching environment variable above. The existing image-publish role uses the same GitHub OIDC provider.

The plan workflow publishes the readable plan in the Actions run summary. For pushes to `main`, it stores the exact saved plan as a one-day artifact; after environment approval, the apply job applies it. Treat the artifact as sensitive state data and keep Actions access limited to trusted repository collaborators. Workflow runs are serialized. Apply learning infrastructure changes through this workflow. For cluster add-ons, plan and apply manually after the learning infrastructure is up to date.

## One-time state migration

The S3 bucket has already been created and configured with TLS-only access, public access blocked, bucket-owner-enforced ownership, SSE-S3 encryption, and versioning. Migrate both existing local state files before running plans. Keep `TF_CICD_ENABLED` unset until every prerequisite is complete. Run these commands from the repository root and review each migration prompt:

```bash
export AWS_PROFILE=meeting-bot
export AWS_REGION=ap-south-1

terraform -chdir=terraform/environments/learning init -migrate-state
terraform -chdir=terraform/environments/cluster-addons init -migrate-state

terraform -chdir=terraform/environments/learning state list
terraform -chdir=terraform/environments/cluster-addons state list
terraform -chdir=terraform/environments/learning plan -out=tfplan
terraform -chdir=terraform/environments/learning show -no-color tfplan
terraform -chdir=terraform/environments/learning apply tfplan
terraform -chdir=terraform/environments/cluster-addons plan
```

Run the learning migration first because the add-ons state reads it. The learning plan will include the two GitHub Terraform roles; review those additions, then apply that plan from your workstation. Read the role ARNs with:

```bash
terraform -chdir=terraform/environments/learning output -raw terraform_plan_role_arn
terraform -chdir=terraform/environments/learning output -raw terraform_apply_role_arn
```

Set the outputs as `TF_PLAN_ROLE_ARN` and `TF_APPLY_ROLE_ARN` in their matching GitHub Environments. The add-ons plan should have no unexpected changes. Keep the ignored local state backups until remote state and CI plans are verified. Never commit Terraform state or plan files.

The add-ons root reads outputs from the learning state. When an infrastructure change affects those outputs, apply the learning root first, then create and apply a fresh add-ons plan from your workstation.
