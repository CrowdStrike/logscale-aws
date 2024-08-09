
# Check if the CRD has been applied
data "kubernetes_resources" "check_humio_cluster_crd" {
  api_version    = "apiextensions.k8s.io/v1"
  kind           = "CustomResourceDefinition"
  field_selector = "metadata.name=humioclusters.core.humio.com"
}

resource "kubernetes_namespace" "logscale" {
  metadata {
    name = var.logscale_namespace
  }
}

resource "helm_release" "humio_operator" {
  name         = "humio-operator"
  repository   = var.logscale_operator_repo
  chart        = "humio-operator"
  namespace    = kubernetes_namespace.logscale.metadata[0].name
  version      = var.humio_operator_chart_version
  skip_crds    = true
  reset_values = true

  set {
    name  = "operator.image.tag"
    value = var.humio_operator_version
  }

  set {
    name  = "livenessProbe.initialDelaySeconds"
    value = 60
  }

  set {
    name  = "readinessProbe.initialDelaySeconds"
    value = 60
  }

  dynamic "set" {
    for_each = [for key, value in var.humio_operator_extra_values : {
      helm_variable_name  = key
      helm_variable_value = value
    } if length(value) > 0]
    content {
      name  = set.value.helm_variable_name
      value = set.value.helm_variable_value
    }
  }

  depends_on = [
    helm_release.cert_manager,
    data.kubernetes_resources.check_humio_cluster_crd,
    helm_release.topo_lvm_sc
  ]

}



resource "kubernetes_secret" "humiocluster_license" {
  metadata {
    name      = "${var.cluster_name}-license"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }
  data = {
    humio-license-key = var.humiocluster_license
  }
}

# Generate an encryption key that will be used by LogScale to encrypt the data in the S3 bucket
resource "random_password" "s3_encryption_password" {
  length  = 64
  special = false
}

resource "kubernetes_secret" "s3_storage_encryption_key" {
  metadata {
    name      = "${var.cluster_name}-s3-storage-encryption"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }
  data = {
    s3-storage-encryption-key = random_password.s3_encryption_password.result
  }
}

# create a single user password for accessing humio UI
resource "random_password" "single_user_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "single_user_password" {
  metadata {
    name      = "${var.cluster_name}-single-user-password"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }
  data = {
    password = random_password.single_user_password.result
  }
}


resource "kubernetes_manifest" "humio_cluster_type_basic" {
  count = contains(["basic"], var.logscale_cluster_type) ? 1 : 0
  manifest = {
    "apiVersion" = "core.humio.com/v1alpha1"
    "kind"       = "HumioCluster"
    "metadata" = {
      "name"      = var.cluster_name
      "namespace" = kubernetes_namespace.logscale.metadata[0].name
    }
    "spec" = {
      "affinity" = {
        "nodeAffinity" = {
          "requiredDuringSchedulingIgnoredDuringExecution" = {
            "nodeSelectorTerms" = [
              {
                "matchExpressions" = [
                  {
                    "key"      = "kubernetes.io/arch"
                    "operator" = "In"
                    "values" = [
                      "amd64",
                    ]
                  },
                  {
                    "key"      = "kubernetes.io/os"
                    "operator" = "In"
                    "values" = [
                      "linux",
                    ]
                  },
                  {
                    "key"      = "k8s-app"
                    "operator" = "In"
                    "values" = [
                      "logscale",
                    ]
                  },
                ]
              },
            ]
          }
        }
        "podAntiAffinity" = {
          "requiredDuringSchedulingIgnoredDuringExecution" = [
            {
              "labelSelector" = {
                "matchExpressions" = [
                  {
                    "key"      = "app.kubernetes.io/name"
                    "operator" = "In"
                    "values" = [
                      "humio",
                    ]
                  },
                ]
              }
              "topologyKey" = "kubernetes.io/hostname"
            },
          ]
        }
      }
      "dataVolumePersistentVolumeClaimSpecTemplate" = {
        "accessModes" = [
          "ReadWriteOnce",
        ]
        "resources" = {
          "requests" = {
            "storage" = var.logscale_digest_data_disk_size
          }
        }
        "storageClassName" = "topolvm-provisioner"
      }
      "digestPartitionsCount" = 840
      "extraKafkaConfigs"     = "security.protocol=SSL"
      "environmentVariables" = [
        {
          "name"  = "S3_STORAGE_BUCKET"
          "value" = var.logscale_s3_bucket_id
        },
        {
          "name"  = "S3_STORAGE_REGION"
          "value" = var.aws_region
        },
        {
          "name" = "S3_STORAGE_ENCRYPTION_KEY"
          "valueFrom" = {
            "secretKeyRef" = {
              "key"  = "s3-storage-encryption-key"
              "name" = kubernetes_secret.s3_storage_encryption_key.metadata[0].name
            }
          }
        },
        {
          "name"  = "USING_EPHEMERAL_DISKS"
          "value" = "true"
        },
        {
          "name"  = "LOCAL_STORAGE_PERCENTAGE"
          "value" = "80"
        },
        {
          "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
          "value" = "true"
        },
        {
          "name"  = "LOCAL_STORAGE_MIN_AGE_DAYS"
          "value" = "7"
        },
        {
          "name"  = "ZOOKEEPER_URL"
          "value" = var.zookeeper_connect_string
        },
        {
          "name"  = "KAFKA_SERVERS"
          "value" = var.msk_bootstrap_brokers
        },
        {
          "name"  = "SINGLE_USER_USERNAME"
          "value" = "admin"
        },
        {
          "name" = "SINGLE_USER_PASSWORD"
          "valueFrom" = {
            "secretKeyRef" = {
              "key"  = "password"
              "name" = kubernetes_secret.single_user_password.metadata[0].name
            }
          }
        },
      ]
      "hostname" = "${var.hostname}.${var.zone_name}"
      "humioServiceAccountAnnotations" = {
        "eks.amazonaws.com/role-arn" = var.service_account_aws_iam_role_arn
      }
      "autoRebalancePartitions" = "true"
      "image"                   = "humio/humio-core:${var.logscale_image_version}"
      "license" = {
        "secretKeyRef" = {
          "key"  = "humio-license-key"
          "name" = kubernetes_secret.humiocluster_license.metadata[0].name
        }
      }
      "nodeCount" = var.logscale_digest_node_count
      "resources" = {
        "limits" = {
          "cpu"    = var.logscale_digest_resources["limits"]["cpu"],
          "memory" = var.logscale_digest_resources["limits"]["memory"]
        }
        "requests" = {
          "cpu"    = var.logscale_digest_resources["requests"]["cpu"]
          "memory" = var.logscale_digest_resources["requests"]["memory"]
        },
      }
      "targetReplicationFactor" = 2
      "tls" = {
        "enabled" = true
      }
    }
  }
  depends_on = [
    data.kubernetes_resources.check_humio_cluster_crd,
    helm_release.cert_manager,
    helm_release.topo_lvm_sc,
  ]
  computed_fields = ["metadata.labels"]

  field_manager {
    name            = "tfapply"
    force_conflicts = true
  }

}

resource "kubernetes_manifest" "humio_cluster_type_ingress" {
  count = contains(["ingress"], var.logscale_cluster_type) ? 1 : 0
  manifest = {
    "apiVersion" = "core.humio.com/v1alpha1"
    "kind"       = "HumioCluster"
    "metadata" = {
      "name"      = var.cluster_name
      "namespace" = kubernetes_namespace.logscale.metadata[0].name
    }
    "spec" = {
      "affinity" = {
        "nodeAffinity" = {
          "requiredDuringSchedulingIgnoredDuringExecution" = {
            "nodeSelectorTerms" = [
              {
                "matchExpressions" = [
                  {
                    "key"      = "kubernetes.io/arch"
                    "operator" = "In"
                    "values" = [
                      "amd64",
                    ]
                  },
                  {
                    "key"      = "kubernetes.io/os"
                    "operator" = "In"
                    "values" = [
                      "linux",
                    ]
                  },
                  {
                    "key"      = "k8s-app"
                    "operator" = "In"
                    "values" = [
                      "logscale",
                    ]
                  },
                ]
              },
            ]
          }
        }
        "podAntiAffinity" = {
          "requiredDuringSchedulingIgnoredDuringExecution" = [
            {
              "labelSelector" = {
                "matchExpressions" = [
                  {
                    "key"      = "app.kubernetes.io/name"
                    "operator" = "In"
                    "values" = [
                      "humio",
                    ]
                  },
                ]
              }
              "topologyKey" = "kubernetes.io/hostname"
            },
          ]
        }
      }
      "dataVolumePersistentVolumeClaimSpecTemplate" = {
        "accessModes" = [
          "ReadWriteOnce",
        ]
        "resources" = {
          "requests" = {
            "storage" = var.logscale_ingress_data_disk_size
          }
        }
        "storageClassName" = "topolvm-provisioner"
      }
      "digestPartitionsCount" = 840
      "extraKafkaConfigs"     = "security.protocol=SSL"
      "environmentVariables" = [
        {
          "name"  = "S3_STORAGE_BUCKET"
          "value" = var.logscale_s3_bucket_id
        },
        {
          "name"  = "S3_STORAGE_REGION"
          "value" = var.aws_region
        },
        {
          "name" = "S3_STORAGE_ENCRYPTION_KEY"
          "valueFrom" = {
            "secretKeyRef" = {
              "key"  = "s3-storage-encryption-key"
              "name" = kubernetes_secret.s3_storage_encryption_key.metadata[0].name
            }
          }
        },
        {
          "name"  = "USING_EPHEMERAL_DISKS"
          "value" = "true"
        },
        {
          "name"  = "LOCAL_STORAGE_PERCENTAGE"
          "value" = "80"
        },
        {
          "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
          "value" = "true"
        },
        {
          "name"  = "LOCAL_STORAGE_MIN_AGE_DAYS"
          "value" = "7"
        },
        {
          "name"  = "ZOOKEEPER_URL"
          "value" = var.zookeeper_connect_string
        },
        {
          "name"  = "KAFKA_SERVERS"
          "value" = var.msk_bootstrap_brokers
        },
        {
          "name"  = "SINGLE_USER_USERNAME"
          "value" = "admin"
        },
        {
          "name" = "SINGLE_USER_PASSWORD"
          "valueFrom" = {
            "secretKeyRef" = {
              "key"  = "password"
              "name" = kubernetes_secret.single_user_password.metadata[0].name
            }
          }
        },
      ]
      "hostname" = "${var.hostname}.${var.zone_name}"
      "humioServiceAccountAnnotations" = {
        "eks.amazonaws.com/role-arn" = var.service_account_aws_iam_role_arn
      }
      "image" = "humio/humio-core:${var.logscale_image_version}"
      "ingress" = {
        "enabled" = false
      }
      "license" = {
        "secretKeyRef" = {
          "key"  = "humio-license-key"
          "name" = kubernetes_secret.humiocluster_license.metadata[0].name
        }
      }
      "nodeCount" = var.logscale_ingress_node_count
      "nodePools" = [
        {
          "name" = "ingress-only"
          "spec" = {
            "affinity" = {
              "nodeAffinity" = {
                "requiredDuringSchedulingIgnoredDuringExecution" = {
                  "nodeSelectorTerms" = [
                    {
                      "matchExpressions" = [
                        {
                          "key"      = "kubernetes.io/arch"
                          "operator" = "In"
                          "values" = [
                            "amd64",
                          ]
                        },
                        {
                          "key"      = "kubernetes.io/os"
                          "operator" = "In"
                          "values" = [
                            "linux",
                          ]
                        },
                        {
                          "key"      = "k8s-app"
                          "operator" = "In"
                          "values" = [
                            "logscale-ingress",
                          ]
                        },
                      ]
                    },
                  ]
                }
              }
              "podAntiAffinity" = {
                "requiredDuringSchedulingIgnoredDuringExecution" = [
                  {
                    "labelSelector" = {
                      "matchExpressions" = [
                        {
                          "key"      = "app.kubernetes.io/name"
                          "operator" = "In"
                          "values" = [
                            "humio",
                          ]
                        },
                      ]
                    }
                    "topologyKey" = "kubernetes.io/hostname"
                  },
                ]
              }
            }
            "dataVolumePersistentVolumeClaimSpecTemplate" = {
              "accessModes" = [
                "ReadWriteOnce",
              ]
              "resources" = {
                "requests" = {
                  "storage" = var.logscale_ingress_data_disk_size
                }
              }
              "storageClassName" = "topolvm-provisioner"
            }
            "extraKafkaConfigs" = "security.protocol=SSL"
            "environmentVariables" = [
              {
                "name"  = "NODE_ROLES"
                "value" = "httponly"
              },
              {
                "name"  = "ENABLE_QUERY_LOAD_BALANCING"
                "value" = "true"
              },
              {
                "name"  = "QUERY_COORDINATOR"
                "value" = "false"
              },
              {
                "name"  = "S3_STORAGE_BUCKET"
                "value" = var.logscale_s3_bucket_id
              },
              {
                "name"  = "S3_STORAGE_REGION"
                "value" = var.aws_region
              },
              {
                "name" = "S3_STORAGE_ENCRYPTION_KEY"
                "valueFrom" = {
                  "secretKeyRef" = {
                    "key"  = "s3-storage-encryption-key"
                    "name" = kubernetes_secret.s3_storage_encryption_key.metadata[0].name
                  }
                }
              },
              {
                "name"  = "USING_EPHEMERAL_DISKS"
                "value" = "true"
              },
              {
                "name"  = "LOCAL_STORAGE_PERCENTAGE"
                "value" = "80"
              },
              {
                "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
                "value" = "true"
              },
              {
                "name"  = "LOCAL_STORAGE_MIN_AGE_DAYS"
                "value" = "7"
              },
              {
                "name"  = "ZOOKEEPER_URL"
                "value" = var.zookeeper_connect_string
              },
              {
                "name"  = "KAFKA_SERVERS"
                "value" = var.msk_bootstrap_brokers
              },
              {
                "name"  = "SINGLE_USER_USERNAME"
                "value" = "admin"
              },
              {
                "name" = "SINGLE_USER_PASSWORD"
                "valueFrom" = {
                  "secretKeyRef" = {
                    "key"  = "password"
                    "name" = kubernetes_secret.single_user_password.metadata[0].name
                  }
                }
              },
            ]
            "humioServiceAccountAnnotations" = {
              "eks.amazonaws.com/role-arn" = var.service_account_aws_iam_role_arn
            }
            "image"     = "humio/humio-core:${var.logscale_image_version}"
            "nodeCount" = var.logscale_ingress_node_count
            "resources" = {
              "limits" = {
                "cpu"    = var.logscale_ingress_resources["limits"]["cpu"],
                "memory" = var.logscale_ingress_resources["limits"]["memory"]
              }
              "requests" = {
                "cpu"    = var.logscale_ingress_resources["requests"]["cpu"]
                "memory" = var.logscale_ingress_resources["requests"]["memory"]
              },
            }
            "updateStrategy" = {
              "type" = "RollingUpdate"
            }
          }
        },
      ]
      "nodeUUIDPrefix" = "/logscale_ingest"
      "resources" = {
        "requests" = {
          "cpu"    = 1
          "memory" = "2Gi"
        }
      }
      "targetReplicationFactor" = 2
      "tls" = {
        "enabled" = true
      }
    }

  }
  depends_on = [
    data.kubernetes_resources.check_humio_cluster_crd,
    helm_release.cert_manager,
    helm_release.topo_lvm_sc,
  ]
  field_manager {
    name            = "tfapply"
    force_conflicts = true
  }
}

resource "kubernetes_manifest" "humio_cluster_type_internal_ingest" {
  count = contains(["internal-ingest"], var.logscale_cluster_type) ? 1 : 0
  manifest = {
    "apiVersion" = "core.humio.com/v1alpha1"
    "kind"       = "HumioCluster"
    "metadata" = {
      "name"      = var.cluster_name
      "namespace" = kubernetes_namespace.logscale.metadata[0].name
    }
    "spec" = {
      "resources" = {
        "limits" = {
          "cpu"    = var.logscale_digest_resources["limits"]["cpu"],
          "memory" = var.logscale_digest_resources["limits"]["memory"]
        }
        "requests" = {
          "cpu"    = var.logscale_digest_resources["requests"]["cpu"]
          "memory" = var.logscale_digest_resources["requests"]["memory"]
        },
      }
      "affinity" = {
        "nodeAffinity" = {
          "requiredDuringSchedulingIgnoredDuringExecution" = {
            "nodeSelectorTerms" = [
              {
                "matchExpressions" = [
                  {
                    "key"      = "kubernetes.io/arch"
                    "operator" = "In"
                    "values" = [
                      "amd64",
                    ]
                  },
                  {
                    "key"      = "kubernetes.io/os"
                    "operator" = "In"
                    "values" = [
                      "linux",
                    ]
                  },
                  {
                    "key"      = "k8s-app"
                    "operator" = "In"
                    "values" = [
                      "logscale",
                    ]
                  },
                ]
              },
            ]
          }
        }
        "podAntiAffinity" = {
          "requiredDuringSchedulingIgnoredDuringExecution" = [
            {
              "labelSelector" = {
                "matchExpressions" = [
                  {
                    "key"      = "app.kubernetes.io/name"
                    "operator" = "In"
                    "values" = [
                      "humio",
                    ]
                  },
                ]
              }
              "topologyKey" = "kubernetes.io/hostname"
            },
          ]
        }
      }
      "dataVolumePersistentVolumeClaimSpecTemplate" = {
        "accessModes" = [
          "ReadWriteOnce",
        ]
        "resources" = {
          "requests" = {
            "storage" = var.logscale_ingest_data_disk_size
          }
        }
        "storageClassName" = "topolvm-provisioner"
      }
      "digestPartitionsCount" = 840
      "extraKafkaConfigs"     = "security.protocol=SSL"
      "environmentVariables" = [
        {
          "name"  = "S3_STORAGE_BUCKET"
          "value" = var.logscale_s3_bucket_id
        },
        {
          "name"  = "S3_STORAGE_REGION"
          "value" = var.aws_region
        },
        {
          "name" = "S3_STORAGE_ENCRYPTION_KEY"
          "valueFrom" = {
            "secretKeyRef" = {
              "key"  = "s3-storage-encryption-key"
              "name" = kubernetes_secret.s3_storage_encryption_key.metadata[0].name
            }
          }
        },
        {
          "name"  = "USING_EPHEMERAL_DISKS"
          "value" = "true"
        },
        {
          "name"  = "LOCAL_STORAGE_PERCENTAGE"
          "value" = "80"
        },
        {
          "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
          "value" = "true"
        },
        {
          "name"  = "LOCAL_STORAGE_MIN_AGE_DAYS"
          "value" = "7"
        },
        {
          "name"  = "ZOOKEEPER_URL"
          "value" = var.zookeeper_connect_string
        },
        {
          "name"  = "KAFKA_SERVERS"
          "value" = var.msk_bootstrap_brokers
        },
        {
          "name"  = "SINGLE_USER_USERNAME"
          "value" = "admin"
        },
        {
          "name" = "SINGLE_USER_PASSWORD"
          "valueFrom" = {
            "secretKeyRef" = {
              "key"  = "password"
              "name" = kubernetes_secret.single_user_password.metadata[0].name
            }
          }
        },
      ]
      "hostname"   = "${var.hostname}.${var.zone_name}"
      "esHostname" = "${var.hostname}-es.${var.zone_name}"
      "humioServiceAccountAnnotations" = {
        "eks.amazonaws.com/role-arn" = var.service_account_aws_iam_role_arn
      }
      "image" = "humio/humio-core:${var.logscale_image_version}"
      "ingress" = {
        "enabled" = false
      }
      "license" = {
        "secretKeyRef" = {
          "key"  = "humio-license-key"
          "name" = kubernetes_secret.humiocluster_license.metadata[0].name
        }
      }
      "nodeCount" = var.logscale_digest_node_count
      "nodePools" = [
        {
          "name" = "ingest-only"
          "spec" = {
            "affinity" = {
              "nodeAffinity" = {
                "requiredDuringSchedulingIgnoredDuringExecution" = {
                  "nodeSelectorTerms" = [
                    {
                      "matchExpressions" = [
                        {
                          "key"      = "kubernetes.io/arch"
                          "operator" = "In"
                          "values" = [
                            "amd64",
                          ]
                        },
                        {
                          "key"      = "kubernetes.io/os"
                          "operator" = "In"
                          "values" = [
                            "linux",
                          ]
                        },
                        {
                          "key"      = "k8s-app"
                          "operator" = "In"
                          "values" = [
                            "logscale-ingest",
                          ]
                        },
                      ]
                    },
                  ]
                }
              }
              "podAntiAffinity" = {
                "requiredDuringSchedulingIgnoredDuringExecution" = [
                  {
                    "labelSelector" = {
                      "matchExpressions" = [
                        {
                          "key"      = "app.kubernetes.io/name"
                          "operator" = "In"
                          "values" = [
                            "humio",
                          ]
                        },
                      ]
                    }
                    "topologyKey" = "kubernetes.io/hostname"
                  },
                ]
              }
            }
            "dataVolumePersistentVolumeClaimSpecTemplate" = {
              "accessModes" = [
                "ReadWriteOnce",
              ]
              "resources" = {
                "requests" = {
                  "storage" = var.logscale_ingest_data_disk_size
                }
              }
              "storageClassName" = "gp2"
            }
            "extraKafkaConfigs" = "security.protocol=SSL"
            "environmentVariables" = [
              {
                "name"  = "NODE_ROLES"
                "value" = "ingestonly"
              },
              {
                "name"  = "QUERY_COORDINATOR"
                "value" = "false"
              },

              {
                "name"  = "S3_STORAGE_BUCKET"
                "value" = var.logscale_s3_bucket_id
              },
              {
                "name"  = "S3_STORAGE_REGION"
                "value" = var.aws_region
              },
              {
                "name" = "S3_STORAGE_ENCRYPTION_KEY"
                "valueFrom" = {
                  "secretKeyRef" = {
                    "key"  = "s3-storage-encryption-key"
                    "name" = kubernetes_secret.s3_storage_encryption_key.metadata[0].name
                  }
                }
              },
              {
                "name"  = "USING_EPHEMERAL_DISKS"
                "value" = "true"
              },
              {
                "name"  = "LOCAL_STORAGE_PERCENTAGE"
                "value" = "80"
              },
              {
                "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
                "value" = "true"
              },
              {
                "name"  = "LOCAL_STORAGE_MIN_AGE_DAYS"
                "value" = "7"
              },
              {
                "name"  = "ZOOKEEPER_URL"
                "value" = var.zookeeper_connect_string
              },
              {
                "name"  = "KAFKA_SERVERS"
                "value" = var.msk_bootstrap_brokers
              },
              {
                "name"  = "SINGLE_USER_USERNAME"
                "value" = "admin"
              },
              {
                "name" = "SINGLE_USER_PASSWORD"
                "valueFrom" = {
                  "secretKeyRef" = {
                    "key"  = "password"
                    "name" = kubernetes_secret.single_user_password.metadata[0].name
                  }
                }
              },
            ]
            "humioServiceAccountAnnotations" = {
              "eks.amazonaws.com/role-arn" = var.service_account_aws_iam_role_arn
            }
            "image"     = "humio/humio-core:${var.logscale_image_version}"
            "nodeCount" = var.logscale_ingest_node_count
            "resources" = {
              "limits" = {
                "cpu"    = var.logscale_ingest_resources["limits"]["cpu"],
                "memory" = var.logscale_ingest_resources["limits"]["memory"]
              }
              "requests" = {
                "cpu"    = var.logscale_ingest_resources["requests"]["cpu"]
                "memory" = var.logscale_ingest_resources["requests"]["memory"]
              },
            }
            "updateStrategy" = {
              "type" = "RollingUpdate"
            }
          }
        },
        {
          "name" = "ui-only"
          "spec" = {
            "affinity" = {
              "nodeAffinity" = {
                "requiredDuringSchedulingIgnoredDuringExecution" = {
                  "nodeSelectorTerms" = [
                    {
                      "matchExpressions" = [
                        {
                          "key"      = "kubernetes.io/arch"
                          "operator" = "In"
                          "values" = [
                            "amd64",
                          ]
                        },
                        {
                          "key"      = "kubernetes.io/os"
                          "operator" = "In"
                          "values" = [
                            "linux",
                          ]
                        },
                        {
                          "key"      = "k8s-app"
                          "operator" = "In"
                          "values" = [
                            "logscale-ui",
                          ]
                        },
                      ]
                    },
                  ]
                }
              }
              "podAntiAffinity" = {
                "requiredDuringSchedulingIgnoredDuringExecution" = [
                  {
                    "labelSelector" = {
                      "matchExpressions" = [
                        {
                          "key"      = "app.kubernetes.io/name"
                          "operator" = "In"
                          "values" = [
                            "humio",
                          ]
                        },
                      ]
                    }
                    "topologyKey" = "kubernetes.io/hostname"
                  },
                ]
              }
            }
            "dataVolumePersistentVolumeClaimSpecTemplate" = {
              "accessModes" = [
                "ReadWriteOnce",
              ]
              "resources" = {
                "requests" = {
                  "storage" = var.logscale_ui_data_disk_size
                }
              }
              "storageClassName" = "gp2"
            }
            "extraKafkaConfigs" = "security.protocol=SSL"
            "environmentVariables" = [
              {
                "name"  = "NODE_ROLES"
                "value" = "httponly"
              },

              {
                "name"  = "QUERY_COORDINATOR"
                "value" = "false"
              },

              {
                "name"  = "S3_STORAGE_BUCKET"
                "value" = var.logscale_s3_bucket_id

              },
              {
                "name"  = "S3_STORAGE_REGION"
                "value" = var.aws_region
              },
              {
                "name" = "S3_STORAGE_ENCRYPTION_KEY"
                "valueFrom" = {
                  "secretKeyRef" = {
                    "key"  = "s3-storage-encryption-key"
                    "name" = kubernetes_secret.s3_storage_encryption_key.metadata[0].name
                  }
                }
              },
              {
                "name"  = "USING_EPHEMERAL_DISKS"
                "value" = "true"
              },
              {
                "name"  = "LOCAL_STORAGE_PERCENTAGE"
                "value" = "80"
              },
              {
                "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
                "value" = "true"
              },
              {
                "name"  = "LOCAL_STORAGE_MIN_AGE_DAYS"
                "value" = "7"
              },
              {
                "name"  = "ZOOKEEPER_URL"
                "value" = var.zookeeper_connect_string
              },
              {
                "name"  = "KAFKA_SERVERS"
                "value" = var.msk_bootstrap_brokers
              },
              {
                "name"  = "SINGLE_USER_USERNAME"
                "value" = "admin"
              },
              {
                "name" = "SINGLE_USER_PASSWORD"
                "valueFrom" = {
                  "secretKeyRef" = {
                    "key"  = "password"
                    "name" = kubernetes_secret.single_user_password.metadata[0].name
                  }
                }
              },
            ]
            "humioServiceAccountAnnotations" = {
              "eks.amazonaws.com/role-arn" = var.service_account_aws_iam_role_arn
            }
            "image"          = "humio/humio-core:${var.logscale_image_version}"
            "nodeCount"      = var.logscale_ui_node_count
            "nodeUUIDPrefix" = "/logscale_ui"
            "resources" = {
              "limits" = {
                "cpu"    = var.logscale_ui_resources["limits"]["cpu"],
                "memory" = var.logscale_ui_resources["limits"]["memory"]
              }
              "requests" = {
                "cpu"    = var.logscale_ui_resources["requests"]["cpu"]
                "memory" = var.logscale_ui_resources["requests"]["memory"]
              },
            }
            "updateStrategy" = {
              "type" = "RollingUpdate"
            }
          }
        },
      ]
      "nodeUUIDPrefix" = "/logscale_ingest"
      "resources" = {
        "limits" = {
          "cpu"    = var.logscale_ingest_resources["limits"]["cpu"],
          "memory" = var.logscale_ingest_resources["limits"]["memory"]
        }
        "requests" = {
          "cpu"    = var.logscale_ingest_resources["requests"]["cpu"]
          "memory" = var.logscale_ingest_resources["requests"]["memory"]
        },
      }
      "targetReplicationFactor" = 2
      "tls" = {
        "enabled" = true
      }
    }
  }

  depends_on = [
    data.kubernetes_resources.check_humio_cluster_crd,
    helm_release.cert_manager,
    helm_release.topo_lvm_sc,
  ]

  field_manager {
    name            = "tfapply"
    force_conflicts = true
  }
}
