[![CrowdStrike Falcon](https://raw.githubusercontent.com/CrowdStrike/falconpy/main/docs/asset/cs-logo.png)]((https://www.crowdstrike.com/)) [![Twitter URL](https://img.shields.io/twitter/url?label=Follow%20%40CrowdStrike&style=social&url=https%3A%2F%2Ftwitter.com%2FCrowdStrike)](https://twitter.com/CrowdStrike)<br/>

# LogScale Reference Automations for AWS


This repository contains Terraform configurations to deploy a comprehensive AWS-based architecture for LogScale. It leverages multiple AWS services such as EKS, MSK, and S3, as well as Kubernetes components like cert-manager and Helm to create a scalable, secure and robust LogScale deployment on AWS.

## Prerequisites

Before starting the deployment, ensure you have the following tools and access:

- **Terraform 1.5.7+**: Terraform is the infrastructure as code tool used to manage the deployment. Ensure you have version 1.5.7 or higher installed.
- **kubectl 1.27+**: kubectl is the command-line tool for interacting with the Kubernetes cluster. Make sure you have version 1.27 or above.
- **AWS CLI 2.0+**: The AWS Command Line Interface (CLI) allows you to interact with AWS services from the command line. Version 2 or higher is recommended.
- **Helm v3**: Helm is the package manager for Kubernetes, used to manage Kubernetes applications. Ensure you have version 3 or higher installed.
- **Access to an AWS account**: You need access to an AWS account with permissions to create and manage the necessary resources such as VPCs, EKS clusters, MSK clusters, and S3 buckets.


## Terraform Code Execution
1. #### Setup steps
    1.1 Ensure an AWS Route 53 public zone is created and add its name to `zonename` in `example.tfvars`.

    1.2 Ensure an S3 bucket is created to hold the terraform state. Create or update the backend configuration file in `backend-configs/`:
    ```bash
    # Copy the example and customize for your environment
    cp backend-configs/example.hcl backend-configs/primary-aws.hcl
    ```

    Edit the backend config file with your values:
    ```hcl
    bucket  = "your-terraform-state-bucket"
    region  = "us-west-2"
    key     = "env:/logscale-aws-eks"
    profile = "your-aws-profile"
    encrypt = true

    # Optional: Enable state locking with DynamoDB
    # dynamodb_table = "terraform-state-lock"
    ```

    1.3 (Optional) For state locking, ensure a DynamoDB table with partition key `LockID` is created and add its name to `dynamodb_table` in the backend config file.

    1.4 Configure the following variables in the `example.tfvars` file: `hostname`, `cluster_name`, `msk_cluster_name`, `vpc_name` and `aws_region`.

    1.5 Export the LogScale license as a Terraform environment variable:
    ```bash
    export TF_VAR_humiocluster_license=<your_logscale_license>
    ```

    1.6 Create and switch to a new Terraform workspace:
    ```bash
    terraform workspace new <workspace_name>
    terraform workspace select <workspace_name>
    ```

2. #### Deployment steps

    Run the following Terraform commands against each Terraform module in sequence to provision the EKS cluster and deploy the LogScale application:

    2.1 Initialize Terraform with backend configuration
    ```bash
    terraform init -backend-config=backend-configs/primary-aws.hcl
    ```

    2.2 Plan the Terraform deployment
    ```bash
    terraform plan
    ```
    Or you could target a specific module
    ```bash
    terraform plan -target="module.vpc"
    ```

    2.3 Deploy VPC
    ```bash
    terraform apply -target="module.vpc"
    ```

    2.4 Deploy MSK cluster
    ```bash
    terraform apply -target="module.msk"
    ```

    2.5 Build EKS cluster
    ```bash
    terraform apply -target="module.eks"
    ```

    2.6 Deploy CRDs

    * Observation : You may need to update the local .kube/config if running this command locally

    ```bash
    aws eks update-kubeconfig --name "<your-eks-cluster-name>" --region <your-region>
    Updated context arn:aws:eks:<region>:<id>:cluster/<your-eks-cluster-name> in /Users/<local_user>/.kube/config
    ```

    ```bash
    terraform apply -target="module.crds
    ```

    2.7 Deploy LogScale
    ```bash
    terraform apply -target="module.logscale"
    ```


## Repository Structure

- `main.tf`: Contains the main Terraform configuration and module definitions for setting up the VPC, EKS, MSK, CRDs, and LogScale.
- `backend.tf`: Declares the S3 backend for Terraform state (values loaded from backend-configs/).
- `backend-configs/`: Directory containing backend configuration files for different workspaces.
  - `primary-aws.hcl`: Backend config for the primary workspace.
  - `secondary-aws.hcl`: Backend config for the secondary workspace.
  - `example.hcl`: Template for creating new backend configs.
- `providers.tf`: Configures the necessary providers for the Terraform configuration.
- `variables.tf`: Declares the variables used in the Terraform configuration.
- `outputs.tf`: Specifies the outputs for the Terraform run.
- `locals.tf`: Contains local variables and templates for cluster size configurations.
- `cluster_size.tpl`: Template file specifying the available parameters for different sizes of LogScale clusters.
- `terraform.tfvars`: Variable values for the configuration.
- `versions.tf`: Specifies the required versions of Terraform and providers.

### Cluster Size Configuration

The `cluster_size.tpl` file specifies the available parameters for different sizes of LogScale clusters. This template defines various cluster sizes (e.g., xsmall, small, medium, large, xlarge) and their associated configurations, including node counts, instance types, disk sizes, and resource limits. The Terraform configuration uses this template to dynamically configure the LogScale deployment based on the selected cluster size.

- **File:** `cluster_size.tpl`
- **Usage:**
  The data from `cluster_size.tpl` is retrieved and rendered by the `locals.tf` file. The `locals.tf` file uses the `jsondecode` function to parse the template and select the appropriate cluster size configuration based on the `logscale_cluster_size` variable.

- **Example:**
```hcl
  # Local Variables
  locals {
    # Render a template of available cluster sizes
    cluster_size_template = jsondecode(templatefile("${path.module}/cluster_size.tpl", {}))
    cluster_size_rendered = {
      for key in keys(local.cluster_size_template) :
      key => local.cluster_size_template[key]
    }
    cluster_size_selected = local.cluster_size_rendered[var.logscale_cluster_size]
  }
```

## Modules

### VPC Module
This module provisions the necessary networking components for the infrastructure, including both private and public subnets across three availability zones. This setup ensures high availability and fault tolerance for the deployed resources. Additionally, the `main.tf` file within the VPC module contains the declaration of security groups that manage inbound and outbound traffic for the instances within the VPC. These security groups are configured to allow only necessary traffic, enhancing the security posture of the deployed environment. Specific rules are defined to control access based on protocol, port range, and source/destination IP addresses.
- **Source:** `./modules/aws/vpc`
- **Variables:**
  - `name`: Name of the VPC
  - `vpc_cidr`: CIDR block for the VPC
  - `cluster_name`: The name of the LogScale cluster
  - `tags`: Tags for the VPC resources

### MSK Module
This module provisions an Amazon Managed Streaming for Apache Kafka (MSK) cluster, which is required by LogScale for reliable and scalable data streaming. MSK ensures efficient handling of large volumes of log data, enabling LogScale to process and analyze logs in real-time. For more information, you can refer to the [LogScale MSK installation guide](https://library.humio.com/falcon-logscale-self-hosted/installation-baremetal-msk.html?redirected=true?redirected=true).

> **Note:** MSK is only deployed when `provision_kafka_servers = false` (using external Kafka) and `dr != "standby"`. Standby clusters use Strimzi-managed Kafka within the EKS cluster instead.

- **Source:** `./modules/aws/msk`
- **Variables:**
    - `cluster_name`: Name of the LogScale cluster
    - `private_subnets`: Private subnets for the MSK cluster
    - `broker_node_instance_type`: Instance type for the Kafka brokers
    - `msk_number_of_broker_nodes`: Number of Kafka brokers
    - `msk_cluster_name`: Name of the MSK cluster
    - `msk_sg_id`: Security group ID for the MSK cluster
    - `msk_node_volume_size`: Size of the MSK node disk volume
    - `kafka_version`: Kafka software version


### EKS Module
Sets up the Amazon EKS cluster and associated resources. This module performs the following tasks:
- **Creates IAM Roles:** The module provisions several IAM roles necessary for the EKS cluster operations, including roles for the EKS control plane, worker nodes, ExternalDNS, and service accounts used by various Kubernetes services. These roles ensure proper permissions and security for cluster operations.
- **Creates ACM Certificate:** An AWS Certificate Manager (ACM) certificate is created to be used by the ingress controller for secure HTTPS communication within the cluster.
- **Creates EKS Cluster and Managed Node Groups:** The module provisions the EKS cluster along with managed node groups. The managed node groups consist of EC2 instances that serve as worker nodes for the EKS cluster, automatically managed and updated by AWS to ensure high availability and security.
- **Creates S3 Bucket:** An S3 bucket is created to be used by LogScale to store segment files, ensuring durable and scalable storage for log data.
- **Source:** `./modules/aws/eks`
- **Variables:**
    - `vpc_id`: VPC ID for the EKS cluster
    - `cluster_name`: Name of the EKS cluster
    - `cluster_version`: Kubernetes version for the EKS cluster
    - `private_subnets`: Private subnets for the EKS nodes
    - `intra_subnets`: Subnets used for intranet communication
    - `ami_type`: AMI used for EKS nodes
    - `*_node_desired_capacity`, `*_node_max_capacity`, `*_node_min_capacity`: Node scaling settings
    - `logscale_node_root_volume_size`: Root disk volume size for LogScale nodes
    - `*logscale_node_root_volume_type`: Root disk volume type for LogScale nodes
    - `*_instance_type`: Node instance type
    - `hostname`: Hostname of the LogScale cluster
    - `zone_name`: Route53 hosted zone domain name
    - `msk_sg_id`: Security group ID for the MSK cluster
    - `route53_record_ttl`: TTL for the hostname.zone_name domain
    - `s3_bucket_prefix`: The prefix of the LogScale S3 bucket
    - `dr`: DR mode (`"active"`, `"standby"`, or `""`)
    - `dr_primary_s3_bucket`: Peer cluster's S3 bucket name for cross-region IAM policies


### Pre-Install Module
Deploys Kubernetes prerequisites required before the LogScale application can be installed. This includes creating the LogScale namespace, generating the S3 storage encryption key (as a Kubernetes secret), deploying the AWS Load Balancer Controller, and configuring ExternalDNS for Route53 integration.
- **Source:** `./modules/kubernetes/pre-install`
- **Variables:**
    - `aws_region`, `aws_profile`: AWS region and profile for the deployment
    - `zone_name`: Route53 hosted zone domain name
    - `hostname`: Hostname of the LogScale cluster
    - `logscale_namespace`: Namespace for LogScale
    - `cluster_name`: Name of the EKS cluster
    - `cluster_endpoint`: EKS cluster endpoint
    - `cluster_certificate_authority_data`: Cluster CA data
    - `service_account_aws_iam_role_arn`: IAM role ARN for the LogScale service account
    - `external_dns_iam_role_arn`: IAM role ARN for ExternalDNS
    - `eks_lb_controller_role_arn`: IAM role ARN for the ALB controller
    - `existing_s3_encryption_key`: Pre-existing encryption key (for DR secondary clusters)
    - `dr`: DR mode (`"active"`, `"standby"`, or `""`)

### LogScale Module
Deploys the LogScale application on the EKS cluster. This module is sourced from a private GitLab repository (`"git::https://github.com/CrowdStrike/logscale-kubernetes"`) and includes Kafka (Strimzi), Gateway API, cert-manager issuers, and the HumioCluster custom resource.
- **Source:** `"git::https://github.com/CrowdStrike/logscale-kubernetes"`
- **Key Variables:**
    - `k8s_cluster_name`: Name of the EKS cluster
    - `logscale_cluster_size`, `logscale_cluster_type`: Cluster sizing and type
    - `logscale_license`: LogScale license key
    - `logscale_public_fqdn`: Public FQDN for the LogScale cluster
    - `humio_operator_chart_version`, `humio_operator_version`: Humio operator versions
    - `provision_kafka_servers`: Whether to deploy Strimzi-managed Kafka
    - `dr`: DR mode -- controls operator replicas, node counts, and recovery settings
    - `dr_use_dedicated_routing`: Enable dedicated ingress/ingest/UI routing during DR promotion
    - `user_logscale_envvars`: Additional environment variables including `S3_RECOVER_FROM_*` for DR

### Global DNS Module
Provides automatic traffic failover between primary and secondary clusters using AWS Route53 Failover Routing Policy. Creates health checks for both clusters and failover DNS records under a global FQDN. During failover, the DR Lambda locks the primary health check FQDN to `failover-locked.invalid` to prevent automatic DNS failback.
- **Source:** `./modules/aws/global-dns`
- **Deployed when:** `manage_global_dns = true` (set only on the primary/active workspace)
- **Variables:**
    - `zone_name`: Route53 hosted zone domain name
    - `route53_record_ttl`: TTL for DNS records
    - `manage_global_dns`: Enable/disable global DNS management
    - `global_logscale_hostname`: Hostname for the global DR FQDN
    - `primary_logscale_hostname`: Hostname for the primary cluster
    - `secondary_logscale_hostname`: Hostname for the secondary cluster
    - `dr`: DR mode (`"active"` or `"standby"`)
- **Key Resources:**
    - `aws_route53_health_check` (primary): HTTPS health check probing `/api/v1/status` every 10s
    - `aws_route53_health_check` (secondary): TCP health check on port 443 (ALB infrastructure readiness)
    - `aws_route53_record` (primary/secondary): Failover routing records under the global FQDN
- **See:** [DR Operations Guide, Section 4.1.1](DR_OPERATIONS_GUIDE.md#411-global-dns-moduleglobal-dns) for full architecture details

### DR Failover Lambda Module
Automates the failover process when the primary cluster becomes unhealthy. Triggered by a CloudWatch alarm monitoring the primary Route53 health check, the Lambda scales the humio-operator deployment from 0 to 1 replica on the secondary EKS cluster and locks the primary health check FQDN to prevent automatic DNS failback. Uses EKS Access Entries for secure, auditable Kubernetes authentication.
- **Source:** `./modules/aws/dr-failover-lambda`
- **Deployed when:** `dr = "standby"` and `dr_failover_lambda_enabled = true`
- **Variables:**
    - `enabled`: Enable/disable the Lambda
    - `name_prefix`: Prefix for resource names
    - `primary_health_check_id`: Route53 health check ID to monitor
    - `secondary_health_check_id`: Secondary health check ID (optional)
    - `cluster_name`: EKS cluster name for the standby cluster
    - `cluster_region`: AWS region of the standby cluster
    - `cluster_namespace`: Kubernetes namespace containing the HumioCluster
    - `humiocluster_name`: Name of the HumioCluster custom resource
    - `operator_target_replicas`: Target replica count for the humio-operator (default: 1)
    - `pre_failover_failure_seconds`: Minimum consecutive failure seconds before triggering (default: 180)
    - `failover_cooldown_seconds`: Cooldown between failover attempts (default: 300)
    - `max_retries`: Retry attempts for K8s API calls (default: 3)
    - `skip_secondary_health_check`: Skip secondary health check validation (default: false)
- **Key Resources:**
    - `aws_lambda_function`: Python 3.12 handler for failover logic
    - `aws_cloudwatch_metric_alarm`: Triggers on primary health check failure
    - `aws_sns_topic`: Connects alarm to Lambda
    - `aws_eks_access_entry`: Grants Lambda namespace-scoped Kubernetes access
    - `aws_kms_key`: Encrypts Lambda environment variables
- **See:** [DR Operations Guide, Section 4.1.2](DR_OPERATIONS_GUIDE.md#412-dr-failover-lambda-moduledr-failover-lambda) for the full failover chain and timing


## Disaster Recovery (DR)

This repository supports active/standby disaster recovery across two AWS regions. The DR implementation provides:

- **Automated failover**: Route53 health check failure triggers a Lambda that scales up the standby LogScale cluster
- **Automatic failback prevention**: The Lambda locks the primary health check FQDN to `failover-locked.invalid` during failover, preventing Route53 from automatically routing traffic back to the primary before operator verification
- **Cross-region S3 recovery**: Standby cluster reads the primary's S3 bucket using synchronized encryption keys
- **Zero-downtime promotion**: Two-phase `terraform apply` promotes standby to active without disrupting the running LogScale pod

| DR Mode | Variable | Behavior |
|---------|----------|----------|
| Non-DR | `dr = ""` | Standard single-cluster deployment |
| Primary | `dr = "active"` | Full production cluster with global DNS and health checks |
| Standby | `dr = "standby"` | Minimal cluster with operator scaled to 0; Lambda watches primary |

For the complete DR setup, failover, and promotion procedures, see **[DR Operations Guide](DR_OPERATIONS_GUIDE.md)**.

For failover simulation and testing, see:
- [DR Failover Simulation HOWTO](test/DR_FAILOVER_SIMULATION_HOWTO.md)
- [DR Failover Simulation Script](test/simulate-aws-dr-failover.sh)


## Terraform Variables in `terraform.tfvars`

### Core Variables

| Variable Name | Description | Type | Default Value |
|-------------------------------------|------------------------------------------------|----------------|------------------------|
| `tags` | Tags for AWS resources | map(string) | |
| `aws_region` | AWS region | string | `us-west-2` |
| `aws_profile` | AWS profile | string | `sandbox` |
| `vpc_name` | Name of the VPC | string | `logscale-eks-vpc` |
| `vpc_cidr` | CIDR block for the VPC | string | `10.0.0.0/16` |
| `cluster_name` | Name of the EKS cluster | string | |
| `cluster_version` | Kubernetes version for the EKS cluster | string | `1.29` |
| `ami_type` | AMI used for EKS nodes | string | `AL2_x86_64` |
| `logscale_namespace` | Namespace for LogScale | string | `logging` |
| `cm_namespace` | Namespace for cert-manager | string | `cert-manager` |
| `cm_repo` | Repository for cert-manager | string | `https://charts.jetstack.io` |
| `cm_version` | Version of cert-manager | string | `v1.15.1` |
| `logscale_operator_repo` | Repository for LogScale operator | string | `https://humio.github.io/humio-operator` |
| `issuer_kind` | Kind of certificate issuer | string | `ClusterIssuer` |
| `issuer_name` | Name of certificate issuer | string | `letsencrypt-cluster-issuer` |
| `issuer_email` | Email of certificate issuer | string | |
| `issuer_private_key` | Private key for certificate issuer | string | `letsencrypt-cluster-issuer-key` |
| `ca_server` | CA server | string | `https://acme-v02.api.letsencrypt.org/directory` |
| `humio_operator_chart_version` | Version of the Humio operator chart | string | `0.22.0` |
| `humio_operator_version` | Version of the Humio operator | string | `0.22.0` |
| `humio_operator_extra_values` | Extra values for Humio operator | map(string) | `cpu: 250m, mem: 750Mi` |
| `logscale_cluster_type` | Type of the LogScale cluster | string | `basic` |
| `kafka_version` | Kafka version | string | `3.5.1` |
| `msk_cluster_name` | Name of the MSK cluster | string | `msk-cluster` |
| `zone_name` | Route53 hosted zone domain name | string | |
| `hostname` | Hostname of the LogScale cluster | string | |
| `route53_record_ttl` | TTL for the hostname.zone_name domain | number | 60 |

### DR Variables

| Variable Name | Description | Type | Default Value |
|-------------------------------------|------------------------------------------------|----------------|------------------------|
| `dr` | DR mode: `"active"`, `"standby"`, or `""` | string | `""` |
| `manage_global_dns` | Enable Route53 global DNS failover records | bool | `false` |
| `global_logscale_hostname` | Hostname for the global DR FQDN | string | `""` |
| `primary_logscale_hostname` | Hostname for the primary cluster DNS record | string | `""` |
| `secondary_logscale_hostname` | Hostname for the secondary cluster DNS record | string | `""` |
| `dr_failover_lambda_enabled` | Enable the DR failover Lambda on standby | bool | `false` |
| `dr_failover_lambda_pre_failover_failure_seconds` | Minimum failure duration before failover (seconds) | number | `180` |
| `dr_use_dedicated_routing` | Enable dedicated routing during DR promotion | bool | `false` |
| `primary_remote_state_config` | Remote state config to read primary outputs | object | `null` |
| `s3_recover_from_bucket` | Primary S3 bucket for DR recovery | string | `""` |
| `s3_recover_from_region` | Primary S3 bucket region for DR recovery | string | `""` |
| `existing_s3_encryption_key` | Pre-existing encryption key (fallback) | string | `""` |
| `eks_s3_bucket_name` | Explicit S3 bucket name (deterministic naming) | string | `""` |


## References
- [Cert Manager Documentation](https://cert-manager.io/docs/)
- [ExternalDNS Documentation](https://kubernetes-sigs.github.io/external-dns/v0.14.2/)
- [MSK Documentation](https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html)
- [EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html)
- [LogScale Deployment on AWS](https://library.humio.com/falcon-logscale-self-hosted-1.82/installation-containers-kubernetes-operator-aws-install.html)
- [Humio Operator](https://github.com/humio/humio-operator)
- [LogScale DR Documentation (Upstream)](https://library.humio.com/deployment/cluster-management-storage-bucket.html#cluster-management-storage-bucket-start-another-cluster)
- [AWS Route53 Failover Routing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy-failover.html)
- [DR Operations Guide](DR_OPERATIONS_GUIDE.md)
