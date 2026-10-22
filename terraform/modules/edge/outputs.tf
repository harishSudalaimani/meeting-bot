output "certificate_arn" { value = aws_acm_certificate_validation.api.certificate_arn }
output "waf_arn" { value = aws_wafv2_web_acl.api.arn }
output "zone_name" { value = data.aws_route53_zone.existing.name }
