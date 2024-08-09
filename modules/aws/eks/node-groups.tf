locals {
  eks_managed_node_groups = lookup({
    "basic" = {
      logscale_node_group = local.logscale_node_group
    }
    "ingress" = {
      logscale_node_group         = local.logscale_node_group
      logscale_ingress_node_group = local.logscale_ingress_node_group
    }
    "internal-ingest" = {
      logscale_node_group        = local.logscale_node_group
      logscale_ingest_node_group = local.logscale_ingest_node_group
      logscale_ui_node_group     = local.logscale_ui_node_group
    }
  }, var.logscale_cluster_type, {})

  # Commons
  common_labels = {
    managed_by = "terraform"
  }

  common_properties = {
    use_name_prefix = true
    ami_type        = var.ami_type

    subnet_ids = var.private_subnets
    vpc_security_group_ids = [
      module.eks.node_security_group_id,
      var.msk_sg_id
    ]

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = var.logscale_node_root_volume_size
          volume_type           = var.logscale_node_root_volume_type
          delete_on_termination = true
        }
      }
    }

    iam_role_additional_policies = {
      "ssm_managed_core" = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    }


    timeouts = {
      delete = "1h"
    }
  }

  # Basic cluster node group
  logscale_node_group = merge(local.common_properties, {
    name = "logscale"

    min_size     = var.logscale_node_min_capacity
    max_size     = var.logscale_node_max_capacity
    desired_size = var.logscale_node_desired_capacity

    instance_types = [var.logscale_instance_type]

    pre_bootstrap_user_data = templatefile("${path.module}/${var.user_data_script}", {
      humio_data_dir            = var.humio_data_dir,
      humio_data_dir_owner_uuid = var.humio_data_dir_owner_uuid
    })

    labels = merge(local.common_labels, {
      k8s-app      = "logscale"
      storageclass = "nvme"
    })
  })

  logscale_ingress_node_group = merge(local.common_properties, {
    name = "logscale-ingress"

    min_size     = var.ingress_node_min_capacity
    max_size     = var.ingress_node_max_capacity
    desired_size = var.ingress_node_desired_capacity

    instance_types = [var.ingress_instance_type]

    pre_bootstrap_user_data = templatefile("${path.module}/${var.user_data_script}", {
      humio_data_dir            = var.humio_data_dir,
      humio_data_dir_owner_uuid = var.humio_data_dir_owner_uuid
    })

    labels = merge(local.common_labels, {
      k8s-app = "logscale-ingress"
    })
  })

  logscale_ingest_node_group = merge(local.common_properties, {
    name = "logscale-ingest"

    min_size     = var.ingest_node_min_capacity
    max_size     = var.ingest_node_max_capacity
    desired_size = var.ingest_node_desired_capacity

    instance_types = [var.ingest_instance_type]

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"

        ebs = {
          volume_size           = var.logscale_ingest_root_disk_size
          volume_type           = var.logscale_ingest_root_disk_type
          delete_on_termination = true
        }
      }
      xvdb = {
        device_name = "/dev/xvdb"
        ebs = {
          volume_size           = trimsuffix(var.logscale_ingest_data_disk_size, "Gi")
          volume_type           = var.logscale_ingest_data_disk_type
          delete_on_termination = true
        }
      }
    }

    labels = merge(local.common_labels, {
      k8s-app = "logscale-ingest"
    })
  })

  logscale_ui_node_group = merge(local.common_properties, {
    name = "logscale-ui"

    min_size     = var.ui_node_min_capacity
    max_size     = var.ui_node_max_capacity
    desired_size = var.ui_node_desired_capacity

    instance_types = [var.ui_instance_type]

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = var.logscale_ui_root_disk_size
          volume_type           = var.logscale_ui_root_disk_type
          delete_on_termination = true
        }
      }
      xvdb = {
        device_name = "/dev/xvdb"
        ebs = {
          volume_size           = trimsuffix(var.logscale_ui_data_disk_size, "Gi")
          volume_type           = var.logscale_ui_data_disk_type
          delete_on_termination = true
        }
      }
    }

    labels = merge(local.common_labels, {
      k8s-app = "logscale-ui"
    })
  })
}
