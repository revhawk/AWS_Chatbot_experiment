# Module: Internal ALB (HTTPS 443 + ACM) + AWS WAFv2 + Private VPCE Target Groups (Control C2, C10)

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "sg_alb_id" {
  type = string
}

variable "acm_certificate_arn" {
  description = "ACM TLS certificate ARN for the Internal ALB HTTPS/443 listener"
  type        = string
}

variable "execute_api_vpce_eni_ids" {
  type = list(string)
}

variable "s3_interface_vpce_eni_ids" {
  type = list(string)
}

variable "access_logs_bucket" {
  type = string
}

data "aws_network_interface" "execute_api" {
  for_each = toset(var.execute_api_vpce_eni_ids)
  id       = each.value
}

data "aws_network_interface" "s3_interface" {
  for_each = toset(var.s3_interface_vpce_eni_ids)
  id       = each.value
}

# --- AWS WAFv2 Web ACL (AWS Managed Rules + Rate Limiting) ---

resource "aws_wafv2_web_acl" "alb" {
  name  = "${var.name_prefix}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIp"
    priority = 30
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 500
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }
}

# --- Internal ALB (Private Subnets, HTTPS 443, Drop Invalid Headers) ---

resource "aws_lb" "internal" {
  name                       = substr("${var.name_prefix}-alb", 0, 32)
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [var.sg_alb_id]
  subnets                    = var.private_subnet_ids
  drop_invalid_header_fields = true

  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = "alb-access-logs"
    enabled = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.internal.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

resource "aws_lb_target_group" "api_vpce" {
  name        = substr("${var.name_prefix}-api-tg", 0, 32)
  port        = 443
  protocol    = "HTTPS"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "HTTPS"
    path     = "/"
    matcher  = "200,403"
  }
}

resource "aws_lb_target_group_attachment" "api_vpce" {
  for_each         = data.aws_network_interface.execute_api
  target_group_arn = aws_lb_target_group.api_vpce.arn
  target_id        = each.value.private_ip
  port             = 443
}

resource "aws_lb_target_group" "spa_vpce" {
  name        = substr("${var.name_prefix}-spa-tg", 0, 32)
  port        = 443
  protocol    = "HTTPS"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "HTTPS"
    path     = "/"
    matcher  = "200,307,403,405"
  }
}

resource "aws_lb_target_group_attachment" "spa_vpce" {
  for_each         = data.aws_network_interface.s3_interface
  target_group_arn = aws_lb_target_group.spa_vpce.arn
  target_id        = each.value.private_ip
  port             = 443
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.spa_vpce.arn
  }
}

resource "aws_lb_listener_rule" "api_route" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_vpce.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

output "alb_dns_name" {
  value = aws_lb.internal.dns_name
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.alb.arn
}
