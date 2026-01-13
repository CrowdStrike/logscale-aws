apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${cluster_endpoint}
    certificate-authority-data: ${cluster_ca}
  name: ${cluster_name}
contexts:
- context:
    cluster: ${cluster_name}
    user: ${cluster_name}
  name: ${cluster_name}
current-context: ${cluster_name}
users:
- name: ${cluster_name}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: aws
      args:
        - --profile
        - ${aws_profile}
        - eks
        - get-token
        - --cluster-name
        - ${cluster_name}
        - --region
        - ${aws_region}
      interactiveMode: Never
