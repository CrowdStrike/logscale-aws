output "global_ingest_fqdn" {
  description = "Global Logscale ingest FQDN configured with Route53 DNS failover between primary and secondary clusters. Returns null when manage_global_dns is false."
  value       = var.manage_global_dns && local.global_ingest_fqdn != null ? local.global_ingest_fqdn : null
}

output "primary_health_check_id" {
  description = "Route53 health check ID for the primary ingest endpoint. Null when manage_global_dns is false."
  value       = var.manage_global_dns ? aws_route53_health_check.logscale_global_primary[0].id : null
}

output "secondary_health_check_id" {
  description = "Route53 health check ID for the secondary (TCP port 443 when dr=active for standby mode). Null when manage_global_dns is false or dr=standby."
  value       = var.manage_global_dns && var.dr == "active" ? aws_route53_health_check.logscale_global_secondary[0].id : null
}
