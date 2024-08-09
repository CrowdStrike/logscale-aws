[![CrowdStrike Falcon](https://raw.githubusercontent.com/CrowdStrike/falconpy/main/docs/asset/cs-logo.png)]((https://www.crowdstrike.com/)) [![Twitter URL](https://img.shields.io/twitter/url?label=Follow%20%40CrowdStrike&style=social&url=https%3A%2F%2Ftwitter.com%2FCrowdStrike)](https://twitter.com/CrowdStrike)<br/>

# LogScale Reference Automations for AWS


This repository contains Terraform configurations to deploy a comprehensive AWS-based architecture for LogScale. It leverages multiple AWS services such as EKS, MSK, and S3, as well as Kubernetes components like cert-manager and Helm to create a scalable, secure and robust logscale deployment on AWS.

## Prerequisites

Before starting the deployment, ensure you have the following tools and access:

- **Terraform 1.5.7+**: Terraform is the infrastructure as code tool used to manage the deployment. Ensure you have version 1.1.0 or higher installed.
- **kubectl 1.27+**: kubectl is the command-line tool for interacting with the Kubernetes cluster. Make sure you have version 1.22 or above.
- **AWS CLI 1.32+**: The AWS Command Line Interface (CLI) allows you to interact with AWS services from the command line. Version 2 or higher is recommended.
- **Helm v3**: Helm is the package manager for Kubernetes, used to manage Kubernetes applications. Ensure you have version 3 or higher installed.
- **Access to an AWS account**: You need access to an AWS account with permissions to create and manage the necessary resources such as VPCs, EKS clusters, MSK clusters, and S3 buckets.


## Repository Structure

- `main.tf`: Contains the main Terraform configuration and module definitions for setting up the VPC, EKS, MSK, CRDs, and LogScale.
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


### CRDs Module
his module deploys the Custom Resource Definitions (CRDs) for Kubernetes required for cert-manager and Humio. CRDs extend the Kubernetes API to manage and automate the deployment of these custom resources within the cluster.
- **Source:** `./modules/kubernetes/crds`
- **Variables:**
    - `humio_operator_version`: Version of the Humio operator
    - `cluster_endpoint`: EKS cluster endpoint

### LogScale Module
Deploys the LogScale application on the EKS cluster.
- **Source:** `./modules/kubernetes/logscale`
- **Variables:**
    - `aws_region`, `aws_profile`: AWS region and profile for the deployment
    - `cluster_name`: Name of the EKS cluster
    - `cluster_endpoint`, `cluster_certificate_authority_data`: Cluster endpoint and CA data
    - `humio_operator_chart_version`, `humio_operator_version`, `logscale_operator_repo`, `humio_operator_extra_values`: Humio operator versions
    - `ca_server`, `issuer_name`, `issuer_email`, `issuer_kind`, `issuer_private_key`: Certificate issuer details
    - `cm_namespace`, `cm_repo`, `cm_version`, `issuer_kind`, `issuer_private_key`: Certificate Manager details
    - `external_dns_iam_role_arn`: The ARN of the IAM role used by ExternalDNS
    - `zone_name`: Route53 hosted zone domain name
    - `logscale_namespace`: Namespace for LogScale
    - `logscale_cluster_type`: Type of the LogScale cluster
    - `acm_certificate_arn`: The Amazon Resource Name (ARN) of the ACM certificate issued by ingress
    - `s3_bucket_prefix`: The ID of the LogScale S3 bucket
    - `msk_bootstrap_brokers`: MSK Bootstrap brokers address
    - `service_account_aws_iam_role_arn`: The Amazon Resource Name (ARN) of the IAM role for the logscale service account
    - `eks_lb_controller_role_arn`: The Amazon Resource Name (ARN) of the IAM role for the LB controller
    - `humiocluster_license`: LogScale license
    - `zookeeper_connect_string`: Connection string to the MSK Zookeeper cluster
    - `hostname`: Hostname of the LogScale cluster


## Terraform Variables in `terraform.tfvars`

| Variable Name                       | Description                                    | Type           | Default Value          |
|-------------------------------------|------------------------------------------------|----------------|------------------------|
| `tags`                              | Tags for AWS resources                         | map(string)    |                        |
| `aws_region`                        | AWS region                                     | string         | `us-west-2`            |
| `aws_profile`                       | AWS profile                                    | string         | `sandbox`              |
| `vpc_name`                          | Name of the VPC                                | string         | `logscale-eks-vpc`              |
| `vpc_cidr`                          | CIDR block for the VPC                         | string         | `10.0.0.0/16`          |
| `cluster_name`                      | Name of the EKS cluster                        | string         |                        |
| `cluster_version`                   | Kubernetes version for the EKS cluster         | string         | `1.29`                 |
| `ami_type`                          | AMI used for EKS nodes                         | string         | `AL2_x86_64`           |
| `logscale_namespace`                | Namespace for LogScale                         | string         | `logging`              |
| `cm_namespace`                      | Namespace for cert-manager                     | string         | `cert-manager`         |
| `cm_repo`                           | Repository for cert-manager                    | string         | `https://charts.jetstack.io` |
| `cm_version`                        | Version of cert-manager                        | string         | `v1.15.1`              |
| `logscale_operator_repo`            | Repository for LogScale operator               | string         | `https://humio.github.io/humio-operator` |
| `issuer_kind`                       | Kind of certificate issuer                     | string         | `ClusterIssuer`        |
| `issuer_name`                       | Name of certificate issuer                     | string         | `letsencrypt-cluster-issuer` |
| `issuer_email`                      | Email of certificate issuer                    | string         |                        |
| `issuer_private_key`                | Private key for certificate issuer             | string         | `letsencrypt-cluster-issuer-key` |
| `ca_server`                         | CA server                                      | string         | `https://acme-v02.api.letsencrypt.org/directory` |
| `humio_operator_chart_version`      | Version of the Humio operator chart            | string         | `0.22.0`               |
| `humio_operator_version`            | Version of the Humio operator                  | string         | `0.22.0`               |
| `humio_operator_extra_values`       | Extra values for Humio operator                | map(string)    | `cpu: 250m, mem: 750Mi` |
| `logscale_cluster_type`             | Type of the LogScale cluster                   | string         | `basic`                |
| `kafka_version`                     | Kafka version                                  | string         | `3.5.1`                |
| `msk_cluster_name`                  | Name of the MSK cluster                        | string         | `msk-cluster`          |
| `zone_name`                         | Route53 hosted zone domain name                | string         |                        |
| `hostname`                          | Hostname of the LogScale cluster               | string         |                        |
| `route53_record_ttl`                | TTL for the hostname.zone_name domain          | number         | 60                     |


## Terraform Code Execution
1. Export the LogScale license as a Terraform environment variable:
    ```bash
    export TF_VAR_humiocluster_license=<your_logscale_license>
    ```
2. Create and switch to a new Terraform workspace:
    ```bash
    terraform workspace new <workspace_name>
    terraform workspace select <workspace_name>
    ```
3. Run the following Terraform commands against each Terraform module in sequence to provision the EKS cluster and deploy the LogScale application:

    2.1 Initialize Terraform
    ```bash
    terraform init
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

## References
- [Cert Manager Documentation](https://cert-manager.io/docs/)
- [ExternalDNS Documentation](https://kubernetes-sigs.github.io/external-dns/v0.14.2/)
- [MSK Documentation](https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html)
- [EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html)
- [LogScale Deployment on AWS](https://library.humio.com/falcon-logscale-self-hosted-1.82/installation-containers-kubernetes-operator-aws-install.html)
- [Humio Operator](https://github.com/humio/humio-operator)
