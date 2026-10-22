data "aws_caller_identity" "current" {}
resource "random_id" "bucket_suffix" { byte_length = 3 }

locals {
  artifact_bucket_name = "${substr(var.name, 0, 32)}-${data.aws_caller_identity.current.account_id}-${random_id.bucket_suffix.hex}-artifacts"
  images               = ["api", "controller", "meeting-bot", "delivery-worker"]
}

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.name}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"
  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }
  point_in_time_recovery { enabled = false }
  server_side_encryption { enabled = true }
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
  tags = var.common_tags
}

resource "aws_sqs_queue" "request_dlq" {
  name                      = "${var.name}-requests-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.common_tags
}

resource "aws_sqs_queue" "requests" {
  name                       = "${var.name}-requests"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.request_dlq.arn, maxReceiveCount = 5 })
  tags                       = var.common_tags
}

resource "aws_sqs_queue" "delivery_dlq" {
  name                      = "${var.name}-delivery-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.common_tags
}

resource "aws_sqs_queue" "delivery" {
  name                       = "${var.name}-deliveries"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.delivery_dlq.arn, maxReceiveCount = 5 })
  tags                       = var.common_tags
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifact_bucket_name
  force_destroy = true
  tags          = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-demo-artifacts"
    status = "Enabled"
    filter { prefix = "artifacts/" }
    expiration { days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(local.images)
  name                 = "${var.name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = var.common_tags
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name
  policy     = jsonencode({ rules = [{ rulePriority = 1, description = "Keep the ten most recent images", selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }, action = { type = "expire" } }] })
}
