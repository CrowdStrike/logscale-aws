# Local Variables
locals {
  # Workspace validation
  current_workspace        = terraform.workspace
  expected_workspace_final = coalesce(var.expected_workspace, "default")

  # Validate workspace matches expected_workspace from tfvars (defaults to "default" if not set)
  # workspace_check = local.current_workspace != local.expected_workspace_final ? (
  #   file("ERROR: Workspace mismatch! Current workspace: '${local.current_workspace}', expected: '${local.expected_workspace_final}'. Please switch to the correct workspace or use the correct tfvars file.")
  # ) : null

  # S3 workspace path workaround for terraform_remote_state:
  # S3 backend stores state at env:/<workspace>/<key> but the data source
  # doesn't prepend this path automatically. We construct it manually.
  _primary_workspace = try(var.primary_remote_state_config.workspace, null)
  _primary_base_key  = try(var.primary_remote_state_config.config.key, "")

  _primary_full_key = (
    local._primary_workspace != null && local._primary_workspace != "default" && local._primary_base_key != ""
    ? "env:/${local._primary_workspace}/${local._primary_base_key}"
    : local._primary_base_key
  )

  effective_primary_remote_state_config = (
    var.primary_remote_state_config != null
    ? {
      backend = try(var.primary_remote_state_config.backend, "s3")
      config = merge(
        var.primary_remote_state_config.config,
        { key = local._primary_full_key }
      )
    }
    : null
  )

  logscale_base_envvars = [
    {
      "name"  = "INGEST_FEED_AWS_ROLE_ARN"
      "value" = module.eks.service_account_aws_iam_role_arn
    },
    {
      "name"  = "S3_STORAGE_REGION"
      "value" = var.aws_region
    },
    {
      "name"  = "S3_STORAGE_BUCKET"
      "value" = module.eks.logscale_s3_bucket_id
    },
    {
      "name" = "S3_STORAGE_ENCRYPTION_KEY"
      "valueFrom" = {
        "secretKeyRef" = {
          "key"  = "s3-storage-encryption-key"
          "name" = module.pre-install.s3_storage_encryption_key_k8s_secret_name
        }
      }
    },
    {
      "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
      "value" = "true"
    },
  ]

  # Render a template of available cluster sizes
  cluster_size_template = jsondecode(templatefile("${path.module}/cluster_size.tpl", {}))
  cluster_size_rendered = {
    for key in keys(local.cluster_size_template) :
    key => local.cluster_size_template[key]
  }
  cluster_size_selected = local.cluster_size_rendered[var.logscale_cluster_size]
  cluster_size          = merge(local.cluster_size_selected, { kafka_broker_data_storage_class = local.cluster_size_selected["kafka_broker_data_disk_type"] })
  kubeconfig_filepath   = var.kubeconfig_filepath != "" ? var.kubeconfig_filepath : "${path.root}/kubeconfig-${var.cluster_name}.yaml"

  # S3 encryption key configuration
  # Priority: explicit variable > remote state from primary > null (pre-install module generates for primary)
  remote_s3_encryption_key    = var.primary_remote_state_config != null ? try(data.terraform_remote_state.primary[0].outputs.s3_storage_encryption_key, null) : null
  effective_s3_encryption_key = var.existing_s3_encryption_key != null ? var.existing_s3_encryption_key : local.remote_s3_encryption_key

  # DR recovery configuration
  # DR peer bucket configuration for cross-region IAM permissions
  # Priority order:
  # 1. Explicitly set dr_primary_s3_bucket in tfvars (highest priority)
  # 2. Fall back to s3_recover_from_bucket from tfvars (lowest priority)
  # This ensures secondary can get primary bucket from tfvars
  # Primary cluster must manually specify the secondary bucket in tfvars
  effective_dr_peer_s3_bucket = coalesce(
    var.dr_primary_s3_bucket,
    var.s3_recover_from_bucket
  )

  # DR failover Lambda health check IDs
  # Priority: explicit variable > remote state from primary > empty string
  remote_primary_health_check_id   = var.primary_remote_state_config != null ? try(data.terraform_remote_state.primary[0].outputs.primary_health_check_id, "") : ""
  remote_secondary_health_check_id = var.primary_remote_state_config != null ? try(data.terraform_remote_state.primary[0].outputs.secondary_health_check_id, "") : ""
  final_primary_health_check_id    = try(coalesce(var.dr_primary_health_check_id, local.remote_primary_health_check_id), "")
  final_secondary_health_check_id  = try(coalesce(var.dr_secondary_health_check_id, local.remote_secondary_health_check_id), "")

  # DR DNS defaults for pre-install module
  dr_global_dns_default    = var.global_logscale_hostname != "" ? "${var.global_logscale_hostname}.${var.zone_name}" : ""
  dr_primary_dns_default   = var.primary_logscale_hostname != "" ? "${var.primary_logscale_hostname}.${var.zone_name}" : ""
  dr_secondary_dns_default = var.secondary_logscale_hostname != "" ? "${var.secondary_logscale_hostname}.${var.zone_name}" : ""

  # DR recovery environment variables with simple string values
  # Keep these env vars in BOTH standby AND active DR modes to prevent pod recreation during promotion.
  # The env vars are only used at startup by DataSnapshotLoader and are safely ignored after recovery.
  # Changing env vars during promotion (standby → active) would change the pod hash in humio-operator,
  # triggering pod recreation and data loss with ephemeral PVCs.
  bucket_recover_from_replace_bucket = var.s3_recover_from_replace_bucket != null && var.s3_recover_from_replace_bucket != "" ? var.s3_recover_from_replace_bucket : (
    var.s3_recover_from_bucket != null && module.eks.logscale_s3_bucket_id != null ?
    format("%s/%s", var.s3_recover_from_bucket, module.eks.logscale_s3_bucket_id) :
    null
  )

  dr_recovery_simple_envvars = var.dr == "" ? [] : concat(
    var.s3_recover_from_replace_region != null ? [
      {
        name  = "S3_RECOVER_FROM_REPLACE_REGION"
        value = var.s3_recover_from_replace_region
      }
    ] : [],
    local.bucket_recover_from_replace_bucket != null ? [
      {
        name  = "S3_RECOVER_FROM_REPLACE_BUCKET"
        value = local.bucket_recover_from_replace_bucket
      }
    ] : [],
    var.s3_recover_from_bucket != null ? [
      {
        name  = "S3_RECOVER_FROM_BUCKET"
        value = var.s3_recover_from_bucket
      }
    ] : [],
    var.s3_recover_from_region != null ? [
      {
        name  = "S3_RECOVER_FROM_REGION"
        value = var.s3_recover_from_region
      }
    ] : [],
    var.dr == "standby" ? [
      {
        name  = "ENABLE_ALERTS"
        value = "false"
      }
    ] : []
  )

  # DR recovery environment variables with secretKeyRef
  # Keep these env vars in BOTH standby AND active DR modes to prevent pod recreation during promotion.
  dr_recovery_secret_envvars = var.dr == "" ? [] : (
    var.s3_recover_from_encryption_key_secret_name != null && var.s3_recover_from_encryption_key_secret_key != null ? [
      {
        name = "S3_RECOVER_FROM_ENCRYPTION_KEY"
        valueFrom = {
          secretKeyRef = {
            name = module.pre-install.s3_storage_encryption_key_k8s_secret_name
            key  = var.s3_recover_from_encryption_key_secret_key
          }
        }
      }
    ] : []
  )

  # Combine all DR recovery environment variables
  dr_recovery_envvars = concat(local.dr_recovery_simple_envvars, local.dr_recovery_secret_envvars)

  logscale_envvars = concat(local.logscale_base_envvars, local.dr_recovery_envvars)
}
