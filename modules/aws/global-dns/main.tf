locals {
  primary_ingest_fqdn = (
    var.primary_logscale_hostname != "" ?
    "${var.primary_logscale_hostname}.${var.zone_name}" :
    null
  )

  secondary_ingest_fqdn = (
    var.secondary_logscale_hostname != "" ?
    "${var.secondary_logscale_hostname}.${var.zone_name}" :
    null
  )

  global_ingest_fqdn = (
    var.global_logscale_hostname != "" ?
    "${var.global_logscale_hostname}.${var.zone_name}" :
    null
  )

  create_dns_records = var.manage_global_dns
}

data "aws_route53_zone" "logscale_global" {
  count = var.manage_global_dns ? 1 : 0

  name = "${var.zone_name}."

  lifecycle {
    precondition {
      condition     = !var.manage_global_dns || var.dr == "active"
      error_message = "manage_global_dns=true is only supported on the primary (dr=\"active\") cluster. The secondary (dr=\"standby\") and non-DR (dr=\"\") clusters must not manage global DNS records."
    }
  }
}

resource "aws_route53_health_check" "logscale_global_primary" {
  count = var.manage_global_dns ? 1 : 0

  fqdn          = local.primary_ingest_fqdn
  port          = 443
  type          = "HTTPS"
  resource_path = "/api/v1/status"

  request_interval  = 10
  failure_threshold = 3

  tags = {
    Name = "${local.global_ingest_fqdn}-primary"
  }

  # The DR failover Lambda locks this health check during failover by swapping
  # the FQDN to "failover-locked.invalid" (permanent NXDOMAIN).  Terraform must
  # not revert the FQDN or the inversion flag — doing so would cause automatic
  # DNS failback.  Failback requires manual FQDN restoration by an operator.
  lifecycle {
    ignore_changes = [fqdn, invert_healthcheck]
  }
}

# When dr=active (primary cluster), create TCP health check for secondary ALB
# This checks that the ALB infrastructure is ready, even when nodeCount=0 (standby mode)
resource "aws_route53_health_check" "logscale_global_secondary" {
  count = var.manage_global_dns && var.dr == "active" ? 1 : 0

  fqdn = local.secondary_ingest_fqdn
  port = 443
  type = "TCP"

  request_interval  = 30
  failure_threshold = 2

  tags = {
    Name = "${local.global_ingest_fqdn}-secondary"
  }
}

# Primary Route53 failover record
# During failover, the DR Lambda locks the primary health check by swapping its
# FQDN to "failover-locked.invalid" (permanent NXDOMAIN), which makes Route53
# treat the primary as unhealthy even after it recovers.
# This prevents automatic failback — an operator must manually restore the
# health check FQDN after verifying primary readiness.
#
# Skipped when records already exist at the global hostname to avoid Route53
# CNAME conflicts.  Remove the existing records and re-apply to let Terraform
# create the correct failover pair.
resource "aws_route53_record" "logscale_global_primary" {
  count = local.create_dns_records ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.global_ingest_fqdn != null && local.primary_ingest_fqdn != null && local.secondary_ingest_fqdn != null && var.zone_name != ""
      error_message = "manage_global_dns=true requires global_logscale_hostname, primary_logscale_hostname, secondary_logscale_hostname, and zone_name to be non-empty."
    }
  }

  zone_id         = data.aws_route53_zone.logscale_global[0].zone_id
  name            = local.global_ingest_fqdn
  type            = "CNAME"
  ttl             = var.route53_record_ttl
  allow_overwrite = true

  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  records         = [local.primary_ingest_fqdn]
  health_check_id = aws_route53_health_check.logscale_global_primary[0].id
}

# Secondary Route53 failover record
# After failover, this record serves traffic because the primary health check
# FQDN is swapped to an unresolvable host (failover-locked.invalid), ensuring
# it always fails. DNS stays here until an operator manually restores the
# primary health check FQDN to initiate failback.
resource "aws_route53_record" "logscale_global_secondary" {
  count = local.create_dns_records ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.global_ingest_fqdn != null && local.primary_ingest_fqdn != null && local.secondary_ingest_fqdn != null && var.zone_name != ""
      error_message = "manage_global_dns=true requires global_logscale_hostname, primary_logscale_hostname, secondary_logscale_hostname, and zone_name to be non-empty."
    }
  }

  zone_id         = data.aws_route53_zone.logscale_global[0].zone_id
  name            = local.global_ingest_fqdn
  type            = "CNAME"
  ttl             = var.route53_record_ttl
  allow_overwrite = true

  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  records         = [local.secondary_ingest_fqdn]
  health_check_id = aws_route53_health_check.logscale_global_secondary[0].id
}
