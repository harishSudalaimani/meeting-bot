locals {
  terraform_state_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::meeting-bot-tfstate-481665121849-ap-south-1"
  terraform_state_prefix     = "${local.terraform_state_bucket_arn}/meeting-bot-platform"
  terraform_learning_state   = "${local.terraform_state_prefix}/learning/terraform.tfstate"
}

resource "aws_iam_role" "terraform_plan" {
  count = var.api_repository == "" ? 0 : 1
  name  = "${var.name}-github-terraform-plan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:${var.api_repository}:environment:terraform-plan"
      } }
    }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  count      = var.api_repository == "" ? 0 : 1
  role       = aws_iam_role.terraform_plan[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "terraform_plan_state" {
  count = var.api_repository == "" ? 0 : 1
  name  = "terraform-state-read-and-lock"
  role  = aws_iam_role.terraform_plan[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.terraform_state_bucket_arn
        Condition = { StringLike = {
          "s3:prefix" = ["meeting-bot-platform/learning/*"]
        } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = local.terraform_learning_state
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.terraform_learning_state}.tflock"
      },
      {
        Effect      = "Deny"
        Action      = ["s3:GetObject*"]
        NotResource = "${local.terraform_state_prefix}/*"
      }
    ]
  })
}

resource "aws_iam_role" "terraform_apply" {
  count = var.api_repository == "" ? 0 : 1
  name  = "${var.name}-github-terraform-apply"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:${var.api_repository}:environment:terraform-apply"
      } }
    }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "terraform_apply_poweruser" {
  count      = var.api_repository == "" ? 0 : 1
  role       = aws_iam_role.terraform_apply[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "terraform_apply_state_and_project_iam" {
  count = var.api_repository == "" ? 0 : 1
  name  = "terraform-state-and-project-iam"
  role  = aws_iam_role.terraform_apply[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.terraform_state_bucket_arn
        Condition = { StringLike = {
          "s3:prefix" = ["meeting-bot-platform/learning/*"]
        } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = local.terraform_learning_state
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.terraform_learning_state}.tflock"
      },
      {
        Effect = "Deny"
        Action = ["s3:*"]
        NotResource = [
          local.terraform_state_bucket_arn,
          "${local.terraform_state_prefix}/*",
          var.workload_artifact_arn,
          "${var.workload_artifact_arn}/*"
        ]
      },
      {
        Effect = "Deny"
        Action = ["s3:DeleteObject"]
        Resource = [
          "${local.terraform_state_prefix}/learning/terraform.tfstate",
          "${local.terraform_state_prefix}/cluster-addons/terraform.tfstate"
        ]
      },
      {
        Effect = "Deny"
        Action = [
          "s3:DeleteBucket",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketPublicAccessBlock",
          "s3:DeleteBucketPublicAccessBlock",
          "s3:PutEncryptionConfiguration",
          "s3:DeleteEncryptionConfiguration",
          "s3:PutBucketVersioning",
          "s3:PutBucketOwnershipControls",
          "s3:DeleteBucketOwnershipControls"
        ]
        Resource = local.terraform_state_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = { StringLike = {
          "iam:AWSServiceName" = [
            "eks.amazonaws.com",
            "eks-nodegroup.amazonaws.com",
            "elasticloadbalancing.amazonaws.com",
            "autoscaling.amazonaws.com",
            "spot.amazonaws.com"
          ]
        } }
      },
      {
        Effect   = "Deny"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = { StringNotLike = {
          "iam:AWSServiceName" = [
            "eks.amazonaws.com",
            "eks-nodegroup.amazonaws.com",
            "elasticloadbalancing.amazonaws.com",
            "autoscaling.amazonaws.com",
            "spot.amazonaws.com"
          ]
        } }
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-*"
        Condition = { StringEquals = {
          "iam:PassedToService" = ["ec2.amazonaws.com", "eks.amazonaws.com"]
        } }
      },
      {
        Effect      = "Deny"
        Action      = ["iam:PassRole"]
        NotResource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-*"
      },
      {
        Effect   = "Deny"
        Action   = ["iam:PassRole"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-*"
        Condition = { StringNotEquals = {
          "iam:PassedToService" = ["ec2.amazonaws.com", "eks.amazonaws.com"]
        } }
      },
      {
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-*",
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.name}-*",
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.name}-*",
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com",
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::aws:policy/*"
      },
      {
        Effect   = "Deny"
        Action   = ["iam:AttachRolePolicy"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-*"
        Condition = { ArnNotLike = {
          "iam:PolicyARN" = [
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXrayWriteOnlyAccess",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess",
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"
          ]
        } }
      },
      {
        Effect   = "Allow"
        Action   = ["budgets:ModifyBudget", "budgets:ViewBudget", "aws-portal:ModifyBilling", "aws-portal:ViewBilling"]
        Resource = "*"
      },
      {
        Effect = "Deny"
        Action = ["iam:*"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-github-terraform-plan",
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-github-terraform-apply"
        ]
      }
    ]
  })
}

