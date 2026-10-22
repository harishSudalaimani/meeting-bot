output "jobs_table_name" { value = aws_dynamodb_table.jobs.name }
output "jobs_table_arn" { value = aws_dynamodb_table.jobs.arn }
output "request_queue_name" { value = aws_sqs_queue.requests.name }
output "request_queue_arn" { value = aws_sqs_queue.requests.arn }
output "request_queue_url" { value = aws_sqs_queue.requests.url }
output "request_dlq_name" { value = aws_sqs_queue.request_dlq.name }
output "delivery_queue_arn" { value = aws_sqs_queue.delivery.arn }
output "delivery_queue_url" { value = aws_sqs_queue.delivery.url }
output "artifact_bucket_name" { value = aws_s3_bucket.artifacts.bucket }
output "artifact_bucket_arn" { value = aws_s3_bucket.artifacts.arn }
output "ecr_repository_urls" { value = { for name, repo in aws_ecr_repository.services : name => repo.repository_url } }
