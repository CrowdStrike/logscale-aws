data "aws_route53_zone" "logscale_zone" {
  name = "${var.zone_name}."
}


resource "aws_acm_certificate" "logscale_cert" {
  domain_name       = "${var.hostname}.${var.zone_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags

}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.logscale_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = var.route53_record_ttl
  type            = each.value.type
  zone_id         = data.aws_route53_zone.logscale_zone.zone_id
}

# resource "aws_acm_certificate_validation" "example_cert_validation" {
#   certificate_arn         = aws_acm_certificate.logscale_cert.arn
#   validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
# }
