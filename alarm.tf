# alarm.tf — TechStream Self-Healing lab (Step 5)
# Creates the CloudWatch Alarm, SNS topic, and EventBridge rule via Terraform.
# Apply with:
#   terraform init && terraform apply -var="account_id=$(aws sts get-caller-identity --query Account --output text)"

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project = "TechStream"
      Lab     = "SelfHealing"
    }
  }
}

variable "account_id" {
  description = "AWS account ID — used to scope IAM/SNS ARN references"
  type        = string
}

variable "alert_email" {
  description = "Email address that receives SNS alarm notifications"
  type        = string
  default     = "ops@example.com"
}

variable "lambda_arn" {
  description = "ARN of the remediate Lambda function (created separately)"
  type        = string
  default     = "arn:aws:lambda:us-east-1:ACCOUNT_ID:function:TechStream-Remediate"
}

locals {
  region    = "us-east-1"
  namespace = "TechStream/WebServer"
}

# ---------------------------------------------------------------------------
# SNS topic — receives alarm notifications (email + EventBridge can both listen)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "TechStream-Alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Allow CloudWatch to publish to this topic
resource "aws_sns_topic_policy" "cw_publish" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:cloudwatch:${local.region}:${var.account_id}:alarm:*"
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Alarm — fires when error rate > 5 % for 2 consecutive minutes
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "TechStream-HighErrorRate"
  alarm_description   = "HTTP 5xx error rate exceeded 5% for 2 consecutive 1-minute periods"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  # Use a metric math expression (errors / total * 100) identical to the dashboard
  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = local.namespace
      metric_name = "techstream_errors_total"
      dimensions  = { AutoScalingGroupName = "TechStream-ASG" }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "total"
    return_data = false
    metric {
      namespace   = local.namespace
      metric_name = "techstream_requests_total"
      dimensions  = { AutoScalingGroupName = "TechStream-ASG" }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "IF(total > 0, (errors / total) * 100, 0)"
    label       = "ErrorRate"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# EventBridge rule — matches CloudWatch alarm state change → ALARM
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "alarm_trigger" {
  name        = "TechStream-AlarmStateChange"
  description = "Fires when TechStream-HighErrorRate transitions to ALARM"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = ["TechStream-HighErrorRate"]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.alarm_trigger.name
  target_id = "TechStream-RemediateLambda"
  arn       = var.lambda_arn
}

# Allow EventBridge to invoke the Lambda
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_trigger.arn
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alarm_name" {
  value = aws_cloudwatch_metric_alarm.error_rate.alarm_name
}

output "eventbridge_rule_arn" {
  value = aws_cloudwatch_event_rule.alarm_trigger.arn
}
