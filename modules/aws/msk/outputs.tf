output "msk_bootstrap_brokers" {
  description = "One or more DNS names (or IP addresses) and TLS port pairs. This attribute will have a value if `encryption_in_transit_client_broker` is set to `TLS_PLAINTEXT` or `TLS`"
  value       = module.msk_cluster.bootstrap_brokers_tls
}

output "zookeeper_connect_string" {
  description = "A comma separated list of one or more hostname:port pairs to use to connect to the Apache Zookeeper cluster."
  value       = module.msk_cluster.zookeeper_connect_string
}

output "msk_cluster_arn" {
  description = "Amazon Resource Name (ARN) of the MSK cluster"
  value       = module.msk_cluster.arn
}
