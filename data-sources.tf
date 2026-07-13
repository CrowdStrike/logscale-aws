# Remote state from the primary cluster (only when standby needs to read primary outputs)
# Uses effective config from locals.tf which handles S3 workspace path construction
data "terraform_remote_state" "primary" {
  count   = local.effective_primary_remote_state_config != null ? 1 : 0
  backend = local.effective_primary_remote_state_config.backend
  config  = local.effective_primary_remote_state_config.config
}
