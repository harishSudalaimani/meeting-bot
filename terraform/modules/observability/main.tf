resource "aws_cloudwatch_metric_alarm" "request_depth" {
  alarm_name          = "${var.name}-request-queue-depth"
  alarm_description   = "More than 20 meeting requests are waiting for over five minutes."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { QueueName = var.request_queue_name }
  treat_missing_data  = "notBreaching"
  tags                = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "request_dlq" {
  alarm_name          = "${var.name}-request-dlq-not-empty"
  alarm_description   = "A request reached the dead-letter queue and needs investigation."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { QueueName = var.request_dlq_name }
  treat_missing_data  = "notBreaching"
  tags                = var.common_tags
}

resource "aws_budgets_budget" "project_monthly" {
  name         = "${var.name}-monthly-cost-alert"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = [format("Project$%s", var.project)]
  }
  dynamic "notification" {
    for_each = var.budget_alert_email == "" ? [] : [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
  tags = var.common_tags
}
