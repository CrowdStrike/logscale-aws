#!/usr/bin/env bash
#
# simulate-aws-dr-failover.sh
#
# Comprehensive DR failover simulation for AWS LogScale clusters.
# Supports auto-discovery of cluster pairs from tfvars files, colored output,
# snapshot fetch tracking, CloudWatch alarm monitoring, and multiple failure scenarios.
#
# Architecture:
#   - Route53 health check monitors https://<primary>/api/v1/status
#   - When primary LogScale pods go down, the ALB returns unhealthy responses
#   - Route53 health check fails -> CloudWatch alarm triggers
#   - CloudWatch alarm -> SNS -> Lambda scales secondary humio-operator 0->1
#   - Lambda locks the primary health check FQDN to prevent DNS failback
#   - Secondary LogScale pod starts and recovers from primary S3 bucket
#
# Scenarios:
#   - primary-down      : Scale primary humio-operator to 0, delete pods (real failure sim)
#   - region-down       : Lock Route53 health check FQDN (network isolation sim)
#   - az-down           : Same as region-down
#   - eks-down          : Same as region-down
#   - transient-outage  : Brief health check FQDN lock to test anti-flap gating
#   - logscale-crash    : Kill LogScale process or block health endpoint
#   - dns-failover-check: Show DNS resolution and endpoint health
#   - failback          : Restore primary, reset secondary cluster state
#   - status            : Show current status of both clusters
#
# Usage:
#   ./test/simulate-aws-dr-failover.sh [options] <scenario>
#
# Options:
#   --cluster <primary> <secondary>  Specify EKS cluster names (finds matching tfvars)
#   --primary <tfvars>     Specify primary cluster tfvars file
#   --secondary <tfvars>   Specify secondary cluster tfvars file
#   --debug                Enable debug output
#   --no-auto-discover     Disable automatic cluster pair discovery
#   -h, --help             Show usage
#
# Auto-discovery:
#   By default, the script scans *.tfvars in the repository root for
#   dr = "active" (primary) and dr = "standby" (secondary), then extracts
#   hostnames, regions, cluster names, and constructs FQDNs automatically.
#
# WARNING:
#   - This script modifies humio-operator deployments and health checks
#   - Use only in non-production or during controlled DR tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Colors and Logging
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DEBUG="${DEBUG:-0}"

log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [ "$DEBUG" = "1" ] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2 || true; }

print_timed() {
  local msg="$1"
  local ts
  ts=$(date +"%H:%M:%S")
  echo -e "[$ts] $msg"
}

# ============================================================================
# Configuration (defaults, overridable by env vars or auto-discovery)
# ============================================================================

SCENARIO=""
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-}"
PRIMARY_HEALTH_CHECK_ID="${PRIMARY_HEALTH_CHECK_ID:-}"
PRIMARY_KUBE_CONTEXT="${PRIMARY_KUBE_CONTEXT:-}"
SECONDARY_KUBE_CONTEXT="${SECONDARY_KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-logging}"
PRIMARY_FQDN="${PRIMARY_FQDN:-}"
SECONDARY_FQDN="${SECONDARY_FQDN:-}"
GLOBAL_DR_FQDN="${GLOBAL_DR_FQDN:-}"
FAILOVER_TIMEOUT_SECONDS="${FAILOVER_TIMEOUT_SECONDS:-600}"
TRIGGER_LAMBDA="${TRIGGER_LAMBDA:-true}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-}"

# Auto-discovery configuration
AUTO_DISCOVER_CLUSTERS="${AUTO_DISCOVER_CLUSTERS:-true}"
PRIMARY_TFVARS="${PRIMARY_TFVARS:-}"
SECONDARY_TFVARS="${SECONDARY_TFVARS:-}"
CLUSTER_ARG_PRIMARY=""
CLUSTER_ARG_SECONDARY=""

# Transient outage configuration
TRANSIENT_OUTAGE_DURATION_SECONDS="${TRANSIENT_OUTAGE_DURATION_SECONDS:-30}"
TRANSIENT_OBSERVATION_SECONDS="${TRANSIENT_OBSERVATION_SECONDS:-180}"

# Discovered state
DISCOVERED_PRIMARY_TFVARS=""
DISCOVERED_SECONDARY_TFVARS=""
PRIMARY_CLUSTER_NAME=""
SECONDARY_CLUSTER_NAME=""
PRIMARY_AWS_REGION=""
SECONDARY_AWS_REGION=""

# ============================================================================
# Argument Parsing
# ============================================================================

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] <scenario>

Scenarios:
  primary-down        Simulate PRIMARY cluster failure (scale operator to 0, delete pods)
  region-down         Simulate region outage (lock Route53 health check FQDN)
  az-down             Simulate a full AZ outage (same as region-down)
  eks-down            Simulate EKS cluster unreachable (same as region-down)
  transient-outage    Brief health check FQDN lock to test anti-flap gating
  logscale-crash      Crash LogScale process (modes: kill-process, block-health)
  dns-failover-check  Show DNS resolution and endpoint health for all FQDNs
  failback            Restore PRIMARY, reset SECONDARY cluster state
  status              Show current status of both clusters

Options:
  --cluster <primary> <secondary>  Specify EKS cluster names to find matching tfvars
  --primary <tfvars>     Specify primary cluster tfvars file
  --secondary <tfvars>   Specify secondary cluster tfvars file
  --debug                Enable verbose debug output
  --no-auto-discover     Disable automatic cluster pair discovery from tfvars
  -h, --help             Show this help message

Environment Variables (override auto-discovered values):
  AWS_PROFILE               AWS CLI profile (required if not in tfvars)
  PRIMARY_KUBE_CONTEXT      kubeconfig context for primary cluster
  SECONDARY_KUBE_CONTEXT    kubeconfig context for secondary cluster
  NAMESPACE                 Kubernetes namespace (default: logging)
  PRIMARY_FQDN              Primary cluster FQDN
  SECONDARY_FQDN            Secondary cluster FQDN
  GLOBAL_DR_FQDN            Global DR FQDN
  PRIMARY_HEALTH_CHECK_ID   Route53 health check ID (auto-detected)
  FAILOVER_TIMEOUT_SECONDS  Timeout for tracking failover (default: 600)
  TRIGGER_LAMBDA            Manually trigger Lambda via SNS (default: true)
  SNS_TOPIC_ARN             SNS topic ARN (auto-detected)

Auto-Discovery:
  By default, the script scans *.tfvars files in the repository root for
  dr = "active" and dr = "standby" to find the primary/secondary cluster pair.
  It then reads hostname, zone_name, cluster_name, aws_region, aws_profile,
  and global_logscale_hostname to configure itself automatically.

Examples:
  # Auto-discover clusters (simplest invocation)
  ./test/simulate-aws-dr-failover.sh status

  # Specify by EKS cluster name (recommended)
  ./test/simulate-aws-dr-failover.sh --cluster dr-primary dr-secondary primary-down

  # Explicit tfvars files
  ./test/simulate-aws-dr-failover.sh --primary primary-us-west-2.tfvars --secondary secondary-us-east-2.tfvars region-down

  # With debug output
  ./test/simulate-aws-dr-failover.sh --debug --cluster dr-primary dr-secondary primary-down

  # Override specific values
  AWS_PROFILE=my-profile PRIMARY_KUBE_CONTEXT=my-ctx ./test/simulate-aws-dr-failover.sh failback
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      --cluster)
        if [ $# -lt 3 ]; then log_error "--cluster requires two arguments: <primary-cluster-name> <secondary-cluster-name>"; exit 1; fi
        CLUSTER_ARG_PRIMARY="$2"
        CLUSTER_ARG_SECONDARY="$3"
        shift 3
        ;;
      --primary)
        if [ $# -lt 2 ]; then log_error "--primary requires a tfvars file argument"; exit 1; fi
        PRIMARY_TFVARS="$2"
        shift 2
        ;;
      --secondary)
        if [ $# -lt 2 ]; then log_error "--secondary requires a tfvars file argument"; exit 1; fi
        SECONDARY_TFVARS="$2"
        shift 2
        ;;
      --no-auto-discover)
        AUTO_DISCOVER_CLUSTERS="false"
        shift
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [ -z "$SCENARIO" ]; then
          SCENARIO="$1"
        else
          log_error "Unexpected argument: $1 (scenario already set to '$SCENARIO')"
          usage
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [ -z "$SCENARIO" ]; then
    usage
    exit 1
  fi
}

# ============================================================================
# Utility Functions
# ============================================================================

epoch_to_iso() {
  local epoch="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$epoch"
  else
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$epoch"
  fi
}

# ============================================================================
# Auto-Discovery from tfvars
# ============================================================================

read_tfvar() {
  # Read a variable value from a tfvars file.
  # Handles both quoted and unquoted values, single-line only.
  local var_name="$1"
  local tfvars_file="$2"

  [ ! -f "$tfvars_file" ] && return 1

  local value
  value=$(grep -E "^[[:space:]]*${var_name}[[:space:]]*=" "$tfvars_file" 2>/dev/null | tail -n1 | sed 's/.*=//;s/#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')
  echo "$value"
}

find_tfvars_by_cluster_name() {
  # Find a tfvars file that contains cluster_name = "<name>" in the given search directory.
  local target_name="$1"
  local search_dir="${2:-$ROOT_DIR}"

  for tfvars_file in "$search_dir"/*.tfvars; do
    [ ! -f "$tfvars_file" ] && continue
    local cname
    cname=$(read_tfvar "cluster_name" "$tfvars_file")
    if [ "$cname" = "$target_name" ]; then
      echo "$tfvars_file"
      return 0
    fi
  done
  return 1
}

discover_dr_cluster_pair() {
  # Scan *.tfvars files in the repository root for dr = "active" and dr = "standby"
  local search_dir="${1:-$ROOT_DIR}"
  local found_primary=""
  local found_secondary=""
  local multiple_active=()
  local multiple_standby=()

  log_info "Auto-discovering DR cluster pair from tfvars files..."

  for tfvars_file in "$search_dir"/*.tfvars; do
    [ ! -f "$tfvars_file" ] && continue

    local dr_mode
    dr_mode=$(read_tfvar "dr" "$tfvars_file")

    # Skip files without DR configuration
    [ -z "$dr_mode" ] && continue

    case "$dr_mode" in
      active)
        if [ -n "$found_primary" ]; then
          multiple_active+=("$tfvars_file")
        else
          found_primary="$tfvars_file"
          log_debug "Found primary (active): $tfvars_file"
        fi
        ;;
      standby)
        if [ -n "$found_secondary" ]; then
          multiple_standby+=("$tfvars_file")
        else
          found_secondary="$tfvars_file"
          log_debug "Found secondary (standby): $tfvars_file"
        fi
        ;;
    esac
  done

  # Warn about multiple active clusters
  if [ ${#multiple_active[@]} -gt 0 ]; then
    echo ""
    log_warn "Multiple clusters with dr=\"active\" found!"
    echo -e "  ${YELLOW}Using:    $found_primary${NC}"
    for extra in "${multiple_active[@]}"; do
      echo -e "  ${YELLOW}Also found: $extra${NC}"
    done
    echo -e "  ${CYAN}Use --primary <file.tfvars> --secondary <file.tfvars> to specify explicitly.${NC}"
    echo ""
  fi

  # Warn about multiple standby clusters
  if [ ${#multiple_standby[@]} -gt 0 ]; then
    echo ""
    log_warn "Multiple clusters with dr=\"standby\" found!"
    echo -e "  ${YELLOW}Using:    $found_secondary${NC}"
    for extra in "${multiple_standby[@]}"; do
      echo -e "  ${YELLOW}Also found: $extra${NC}"
    done
    echo -e "  ${CYAN}Use --primary <file.tfvars> --secondary <file.tfvars> to specify explicitly.${NC}"
    echo ""
  fi

  if [ -z "$found_primary" ]; then
    log_error "No primary cluster found (dr=\"active\" in tfvars)"
    return 1
  fi
  if [ -z "$found_secondary" ]; then
    log_error "No secondary cluster found (dr=\"standby\" in tfvars)"
    return 1
  fi

  DISCOVERED_PRIMARY_TFVARS="$found_primary"
  DISCOVERED_SECONDARY_TFVARS="$found_secondary"

  log_info "Discovered DR pair:"
  log_info "  Primary:   $(basename "$found_primary")"
  log_info "  Secondary: $(basename "$found_secondary")"

  return 0
}

find_kube_context() {
  # Find a kubeconfig context matching the given cluster name.
  # Checks both short names (dr-primary) and ARN format (arn:aws:eks:...:cluster/dr-primary).
  local cluster_name="$1"

  # First check for exact match
  if kubectl config get-contexts "$cluster_name" >/dev/null 2>&1; then
    echo "$cluster_name"
    return 0
  fi

  # Search for ARN-format context containing the cluster name
  local arn_context
  arn_context=$(kubectl config get-contexts -o name 2>/dev/null | grep -F "cluster/${cluster_name}" | head -1)
  if [ -n "$arn_context" ]; then
    echo "$arn_context"
    return 0
  fi

  # No match found
  return 1
}

resolve_cluster_configuration() {
  # Resolve all configuration values from tfvars auto-discovery + env var overrides.
  # Priority: 1) Explicit env vars, 2) --cluster names, 3) --primary/--secondary args, 4) Auto-discovery

  # Step 0: If --cluster was used, find matching tfvars files by cluster_name
  if [ -n "$CLUSTER_ARG_PRIMARY" ] && [ -n "$CLUSTER_ARG_SECONDARY" ]; then
    log_info "Looking up tfvars for clusters: $CLUSTER_ARG_PRIMARY, $CLUSTER_ARG_SECONDARY"
    local p_tfvars s_tfvars
    if p_tfvars=$(find_tfvars_by_cluster_name "$CLUSTER_ARG_PRIMARY"); then
      PRIMARY_TFVARS="$p_tfvars"
      log_info "  Primary:   $(basename "$p_tfvars")"
    else
      log_error "No tfvars file found with cluster_name=\"$CLUSTER_ARG_PRIMARY\""
      log_error "Available cluster names in tfvars:"
      for f in "$ROOT_DIR"/*.tfvars; do
        [ ! -f "$f" ] && continue
        local cn
        cn=$(read_tfvar "cluster_name" "$f")
        if [ -n "$cn" ]; then log_error "  $(basename "$f"): cluster_name = \"$cn\""; fi
      done
      exit 1
    fi
    if s_tfvars=$(find_tfvars_by_cluster_name "$CLUSTER_ARG_SECONDARY"); then
      SECONDARY_TFVARS="$s_tfvars"
      log_info "  Secondary: $(basename "$s_tfvars")"
    else
      log_error "No tfvars file found with cluster_name=\"$CLUSTER_ARG_SECONDARY\""
      log_error "Available cluster names in tfvars:"
      for f in "$ROOT_DIR"/*.tfvars; do
        [ ! -f "$f" ] && continue
        local cn
        cn=$(read_tfvar "cluster_name" "$f")
        if [ -n "$cn" ]; then log_error "  $(basename "$f"): cluster_name = \"$cn\""; fi
      done
      exit 1
    fi
  fi

  # Step 1: Determine tfvars files
  if [ -n "$PRIMARY_TFVARS" ] && [ -n "$SECONDARY_TFVARS" ]; then
    # Explicit tfvars provided via --primary/--secondary
    log_debug "Using explicitly provided tfvars files"
    # Resolve paths relative to ROOT_DIR if not absolute
    [[ "$PRIMARY_TFVARS" != /* ]] && PRIMARY_TFVARS="${ROOT_DIR}/${PRIMARY_TFVARS}" || true
    [[ "$SECONDARY_TFVARS" != /* ]] && SECONDARY_TFVARS="${ROOT_DIR}/${SECONDARY_TFVARS}" || true
  elif [ "$AUTO_DISCOVER_CLUSTERS" = "true" ]; then
    # Auto-discover from tfvars
    if discover_dr_cluster_pair; then
      if [ -z "$PRIMARY_TFVARS" ]; then PRIMARY_TFVARS="$DISCOVERED_PRIMARY_TFVARS"; fi
      if [ -z "$SECONDARY_TFVARS" ]; then SECONDARY_TFVARS="$DISCOVERED_SECONDARY_TFVARS"; fi
    else
      log_debug "Auto-discovery failed, relying on env vars"
    fi
  fi

  # Step 2: Read values from tfvars (if available) and set defaults
  if [ -n "$PRIMARY_TFVARS" ] && [ -f "$PRIMARY_TFVARS" ]; then
    log_debug "Reading primary config from: $PRIMARY_TFVARS"
    local p_hostname p_zone p_cluster p_region p_profile p_global_hostname

    p_hostname=$(read_tfvar "hostname" "$PRIMARY_TFVARS")
    p_zone=$(read_tfvar "zone_name" "$PRIMARY_TFVARS")
    p_cluster=$(read_tfvar "cluster_name" "$PRIMARY_TFVARS")
    p_region=$(read_tfvar "aws_region" "$PRIMARY_TFVARS")
    p_profile=$(read_tfvar "aws_profile" "$PRIMARY_TFVARS")
    p_global_hostname=$(read_tfvar "global_logscale_hostname" "$PRIMARY_TFVARS")

    # Set values if not already provided via env vars
    if [ -z "$PRIMARY_FQDN" ] && [ -n "$p_hostname" ] && [ -n "$p_zone" ]; then PRIMARY_FQDN="${p_hostname}.${p_zone}"; fi
    if [ -z "$PRIMARY_CLUSTER_NAME" ]; then PRIMARY_CLUSTER_NAME="${p_cluster}"; fi
    if [ -z "$PRIMARY_AWS_REGION" ]; then PRIMARY_AWS_REGION="${p_region}"; fi
    if [ -z "$AWS_PROFILE" ] && [ -n "$p_profile" ]; then AWS_PROFILE="$p_profile"; fi
    if [ -z "$GLOBAL_DR_FQDN" ] && [ -n "$p_global_hostname" ] && [ -n "$p_zone" ]; then GLOBAL_DR_FQDN="${p_global_hostname}.${p_zone}"; fi

    log_debug "Primary: FQDN=$PRIMARY_FQDN cluster=$PRIMARY_CLUSTER_NAME region=$PRIMARY_AWS_REGION"
  fi

  if [ -n "$SECONDARY_TFVARS" ] && [ -f "$SECONDARY_TFVARS" ]; then
    log_debug "Reading secondary config from: $SECONDARY_TFVARS"
    local s_hostname s_zone s_cluster s_region s_bucket

    s_hostname=$(read_tfvar "hostname" "$SECONDARY_TFVARS")
    s_zone=$(read_tfvar "zone_name" "$SECONDARY_TFVARS")
    s_cluster=$(read_tfvar "cluster_name" "$SECONDARY_TFVARS")
    s_region=$(read_tfvar "aws_region" "$SECONDARY_TFVARS")
    s_bucket=$(read_tfvar "eks_s3_bucket_name" "$SECONDARY_TFVARS")

    if [ -z "$SECONDARY_FQDN" ] && [ -n "$s_hostname" ] && [ -n "$s_zone" ]; then SECONDARY_FQDN="${s_hostname}.${s_zone}"; fi
    if [ -z "$SECONDARY_CLUSTER_NAME" ]; then SECONDARY_CLUSTER_NAME="${s_cluster}"; fi
    if [ -z "$SECONDARY_AWS_REGION" ]; then SECONDARY_AWS_REGION="${s_region}"; fi
    if [ -z "$AWS_REGION" ] && [ -n "$s_region" ]; then AWS_REGION="$s_region"; fi

    log_debug "Secondary: FQDN=$SECONDARY_FQDN cluster=$SECONDARY_CLUSTER_NAME region=$SECONDARY_AWS_REGION"
  fi

  # Step 3: Auto-detect kubeconfig files and contexts
  # Terraform generates kubeconfig-<cluster_name>.yaml in the repo root.
  # Merge them into KUBECONFIG so kubectl can find the contexts.
  if [ -z "${KUBECONFIG:-}" ]; then
    local kube_files=()
    if [ -n "$PRIMARY_CLUSTER_NAME" ] && [ -f "${ROOT_DIR}/kubeconfig-${PRIMARY_CLUSTER_NAME}.yaml" ]; then
      kube_files+=("${ROOT_DIR}/kubeconfig-${PRIMARY_CLUSTER_NAME}.yaml")
      log_debug "Found primary kubeconfig: kubeconfig-${PRIMARY_CLUSTER_NAME}.yaml"
    fi
    if [ -n "$SECONDARY_CLUSTER_NAME" ] && [ -f "${ROOT_DIR}/kubeconfig-${SECONDARY_CLUSTER_NAME}.yaml" ]; then
      kube_files+=("${ROOT_DIR}/kubeconfig-${SECONDARY_CLUSTER_NAME}.yaml")
      log_debug "Found secondary kubeconfig: kubeconfig-${SECONDARY_CLUSTER_NAME}.yaml"
    fi
    if [ ${#kube_files[@]} -gt 0 ]; then
      # Join with colons, prepend default kubeconfig if it exists
      local default_kube="${HOME}/.kube/config"
      local joined
      joined=$(IFS=:; echo "${kube_files[*]}")
      if [ -f "$default_kube" ]; then
        export KUBECONFIG="${default_kube}:${joined}"
      else
        export KUBECONFIG="${joined}"
      fi
      log_debug "KUBECONFIG=${KUBECONFIG}"
    fi
  else
    log_debug "KUBECONFIG already set: ${KUBECONFIG}"
  fi

  # Auto-detect kubeconfig contexts if not explicitly set
  if [ -z "$PRIMARY_KUBE_CONTEXT" ] && [ -n "$PRIMARY_CLUSTER_NAME" ]; then
    PRIMARY_KUBE_CONTEXT=$(find_kube_context "$PRIMARY_CLUSTER_NAME") || PRIMARY_KUBE_CONTEXT="$PRIMARY_CLUSTER_NAME"
    log_debug "Primary kube context: $PRIMARY_KUBE_CONTEXT"
  fi
  if [ -z "$PRIMARY_KUBE_CONTEXT" ]; then
    PRIMARY_KUBE_CONTEXT="dr-primary"
  fi

  if [ -z "$SECONDARY_KUBE_CONTEXT" ] && [ -n "$SECONDARY_CLUSTER_NAME" ]; then
    SECONDARY_KUBE_CONTEXT=$(find_kube_context "$SECONDARY_CLUSTER_NAME") || SECONDARY_KUBE_CONTEXT="$SECONDARY_CLUSTER_NAME"
    log_debug "Secondary kube context: $SECONDARY_KUBE_CONTEXT"
  fi
  if [ -z "$SECONDARY_KUBE_CONTEXT" ]; then
    SECONDARY_KUBE_CONTEXT="dr-secondary"
  fi

  # Step 4: Default region
  if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-east-2"
  fi
}

# ============================================================================
# Kubernetes Helper Functions
# ============================================================================

get_operator_replicas() {
  local context="$1"
  kubectl --context "$context" -n "$NAMESPACE" get deployment humio-operator \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
}

get_logscale_pods() {
  local context="$1"
  kubectl --context "$context" -n "$NAMESPACE" get pods \
    -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
    --no-headers 2>/dev/null || true
}

get_logscale_pod_name() {
  local context="$1"
  kubectl --context "$context" -n "$NAMESPACE" get pods \
    -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

scale_operator() {
  local context="$1"
  local replicas="$2"
  local cluster_name="$3"

  log_info "Scaling humio-operator to $replicas on $cluster_name..."
  kubectl --context "$context" -n "$NAMESPACE" scale deployment humio-operator --replicas="$replicas"
  echo -e "  ${GREEN}Done.${NC}"
}

check_endpoint_health() {
  local fqdn="$1"
  local status_code
  status_code=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 "https://${fqdn}/api/v1/status" 2>/dev/null || echo "000")
  echo "$status_code"
}

wait_for_pods_deleted() {
  local context="$1"
  local label="$2"
  local timeout="${3:-120}"
  local deadline=$(($(date +%s) + timeout))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local count
    count=$(kubectl --context "$context" -n "$NAMESPACE" get pods -l "$label" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${count:-0}" -eq 0 ]; then
      echo -e "  ${GREEN}All pods with label '$label' terminated.${NC}"
      return 0
    fi
    print_timed "  Waiting for $count pod(s) to terminate..."
    sleep 5
  done

  log_warn "Pods with label '$label' did not terminate within ${timeout}s"
  return 1
}

wait_for_endpoint_healthy() {
  local fqdn="$1"
  local start_epoch="$2"
  local deadline=$((start_epoch + FAILOVER_TIMEOUT_SECONDS))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local status
    status=$(check_endpoint_health "$fqdn")

    if [ "$status" = "200" ]; then
      local healthy_epoch
      healthy_epoch=$(date +%s)
      echo "$healthy_epoch"
      return 0
    fi

    print_timed "  Endpoint $fqdn returned HTTP $status, waiting..." >&2
    sleep 10
  done

  log_warn "Endpoint $fqdn did not become healthy within timeout"
  return 1
}

wait_for_primary_unhealthy() {
  local start_epoch="$1"
  local deadline=$((start_epoch + FAILOVER_TIMEOUT_SECONDS))

  echo "Waiting for primary endpoint to become unhealthy..." >&2

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local status
    status=$(check_endpoint_health "$PRIMARY_FQDN")

    if [ "$status" != "200" ]; then
      local unhealthy_epoch
      unhealthy_epoch=$(date +%s)
      local delta=$((unhealthy_epoch - start_epoch))
      echo -e "  ${GREEN}Primary endpoint unhealthy (HTTP $status) at $(epoch_to_iso "$unhealthy_epoch") (+${delta}s)${NC}" >&2
      echo "$unhealthy_epoch"
      return 0
    fi

    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))
    print_timed "  Primary endpoint: HTTP $status, waiting... (+${delta}s)" >&2
    sleep 5
  done

  log_warn "Primary did not become unhealthy within timeout"
  return 1
}

# ============================================================================
# Failover Tracking Functions
# ============================================================================

track_operator_scaling() {
  local context="$1"
  local start_epoch="$2"
  local deadline=$((start_epoch + FAILOVER_TIMEOUT_SECONDS))

  echo "Tracking humio-operator scaling from 0->1 replicas..." >&2

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local replicas
    replicas=$(get_operator_replicas "$context")

    if [ "${replicas:-0}" -ge 1 ]; then
      local operator_epoch delta
      operator_epoch=$(date +%s)
      delta=$((operator_epoch - start_epoch))
      echo -e "  ${GREEN}humio-operator scaled to $replicas at $(epoch_to_iso "$operator_epoch") (+${delta}s)${NC}" >&2
      echo "$operator_epoch"
      return 0
    fi

    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))
    print_timed "  humio-operator replicas: ${replicas:-0}, waiting... (+${delta}s)" >&2
    sleep 5
  done

  log_warn "humio-operator did not scale within timeout"
  return 1
}

track_logscale_pod_ready() {
  local context="$1"
  local start_epoch="$2"
  local deadline=$((start_epoch + FAILOVER_TIMEOUT_SECONDS))

  echo "Tracking LogScale pod readiness..." >&2

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local ready_pods total_pods
    ready_pods=$(kubectl --context "$context" -n "$NAMESPACE" get pods \
      -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" 2>/dev/null || true)
    ready_pods=$(echo "${ready_pods:-0}" | tr -d '[:space:]')

    total_pods=$(kubectl --context "$context" -n "$NAMESPACE" get pods \
      -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
      --no-headers 2>/dev/null | wc -l 2>/dev/null || true)
    total_pods=$(echo "${total_pods:-0}" | tr -d '[:space:]')

    if [ "${ready_pods:-0}" -ge 1 ] 2>/dev/null; then
      local ready_epoch delta
      ready_epoch=$(date +%s)
      delta=$((ready_epoch - start_epoch))
      echo -e "  ${GREEN}LogScale pod(s) Ready at $(epoch_to_iso "$ready_epoch") (+${delta}s)${NC}" >&2
      echo "$ready_epoch"
      return 0
    fi

    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))
    print_timed "  LogScale pods: ${ready_pods:-0}/${total_pods:-0} Ready, waiting... (+${delta}s)" >&2
    sleep 5
  done

  log_warn "LogScale pod did not become Ready within timeout"
  return 1
}

track_secondary_healthy() {
  local start_epoch="$1"
  local deadline=$((start_epoch + FAILOVER_TIMEOUT_SECONDS))

  echo "Tracking secondary endpoint health..." >&2

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local status
    status=$(check_endpoint_health "$SECONDARY_FQDN")

    if [ "$status" = "200" ]; then
      local healthy_epoch delta
      healthy_epoch=$(date +%s)
      delta=$((healthy_epoch - start_epoch))
      echo -e "  ${GREEN}Secondary endpoint healthy (HTTP 200) at $(epoch_to_iso "$healthy_epoch") (+${delta}s)${NC}" >&2
      echo "$healthy_epoch"
      return 0
    fi

    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))
    print_timed "  Secondary endpoint: HTTP $status, waiting... (+${delta}s)" >&2
    sleep 5
  done

  log_warn "Secondary did not become healthy within timeout"
  return 1
}

track_snapshot_fetch() {
    # Tracks when LogScale successfully fetches the global snapshot from the primary bucket
    # during DR recovery. Monitors the DataSnapshotLoader log messages sequence.
    #
    # Expected log sequence during DR recovery (from DataSnapshotLoader class):
    # These messages appear in the pod logs with format:
    #   <timestamp> [main] INFO c.h.e.f.DataSnapshotLoader <N> - <message>
    #
    # The grep pattern matches "DataSnapshotLoader" and "updateSnapshotForDisasterRecovery"
    # to capture both the snapshot fetch stages and the final patching/readOnly stages.
    # We pipe kubectl logs directly through grep instead of storing in a variable
    # to avoid shell argument length limits on pods with large log output.
    #
    # Key log messages to track:
    #   - "Checking bucket storage localAndHttpWereEmpty=true"
    #   - "Fetching global snapshot from bucket storage s3 found no snapshot to fetch"
    #   - "Trying to fetch a global snapshot as recovery source from bucket storage in s3"
    #   - "Fetched global snapshot from bucket storage s3 found snapshot"
    #   - "updateSnapshotForDisasterRecovery: Patching"
    #   - "updateSnapshotForDisasterRecovery: setting readOnly=true"
    #
    # See DR_OPERATIONS_GUIDE.md section "Verify DR Recovery Succeeded" for details.
    local context="$1"
    local start_time="$2"
    local timeout="${3:-300}"
    # IMPORTANT: Use current time for deadline, not $start_time which is from scenario start
    # By the time Step 6 runs, significant time may have elapsed from Steps 1-5
    local step_start=$(date +%s)
    local deadline=$((step_start + timeout))

    echo "Tracking global snapshot fetch from primary bucket..." >&2
    echo "  Monitoring DataSnapshotLoader logs for DR recovery sequence" >&2

    local pod_name=""
    local pod_start_time=""

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local now=$(date +%s)
        local delta=$((now - step_start))

        # Get LogScale pod name if not yet found
        if [ -z "$pod_name" ]; then
            pod_name=$(kubectl --context "$context" -n "$NAMESPACE" get pods \
                -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

            if [ -z "$pod_name" ]; then
                print_timed "  Waiting for LogScale pod to exist... (+${delta}s)" >&2
                sleep 5
                continue
            fi
            echo "  Found LogScale pod: $pod_name" >&2
        fi

        # Check if pod is running (container must be started to have logs)
        local pod_phase=$(kubectl --context "$context" -n "$NAMESPACE" get pod "$pod_name" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$pod_phase" != "Running" ]; then
            print_timed "  Pod phase: ${pod_phase:-Unknown}, waiting for Running... (+${delta}s)" >&2
            sleep 5
            continue
        fi

        # Get DataSnapshotLoader log lines directly via kubectl pipe to grep.
        # Piping directly avoids shell variable size limits on large log output
        # that caused silent failures when storing full logs in a variable.
        # Match both the class name and updateSnapshotForDisasterRecovery method prefix.
        local snapshot_logs
        snapshot_logs=$(kubectl --context "$context" -n "$NAMESPACE" logs "$pod_name" -c humio 2>/dev/null \
            | grep -E "DataSnapshotLoader|updateSnapshotForDisasterRecovery" 2>/dev/null || echo "")

        # Check for the final success indicator: "setting readOnly=true"
        # This confirms the global snapshot was fetched and patched successfully
        if echo "$snapshot_logs" | grep -q "setting readOnly=true"; then
            print_timed "${GREEN}  DR Recovery Complete at $(epoch_to_iso "$now") (+${delta}s)${NC}" >&2
            echo -e "${GREEN}  Global snapshot fetched and patched successfully${NC}" >&2

            # Show the key log messages found
            echo "" >&2
            echo "  DataSnapshotLoader log messages found:" >&2

            # Show bucket patching details
            local bucket_patch
            bucket_patch=$(echo "$snapshot_logs" | grep "Patching bucket using from=" | tail -1)
            if [ -n "$bucket_patch" ]; then
                echo "    - $bucket_patch" >&2
            fi

            local readonly_msg
            readonly_msg=$(echo "$snapshot_logs" | grep "setting readOnly=true" | tail -1)
            if [ -n "$readonly_msg" ]; then
                echo "    - $readonly_msg" >&2
            fi

            echo "$now"
            return 0
        fi

        # Report progress based on which log messages have been found
        local found_any=false

        # Check for each stage and report the highest stage found
        if echo "$snapshot_logs" | grep -q "updateSnapshotForDisasterRecovery: Patching"; then
            print_timed "  [7/8] Patching snapshot for DR... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Selecting snapshot from source=s3"; then
            print_timed "  [6/8] Selecting snapshot for recovery... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Fetched a global snapshot as recovery source"; then
            print_timed "  [5/8] Recovery snapshot fetched, now patching... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Fetched global snapshot from bucket storage s3 found snapshot"; then
            print_timed "  [4/8] Found snapshot in primary bucket... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Trying to fetch a global snapshot as recovery source"; then
            print_timed "  [3/8] Attempting recovery from primary bucket... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "found no snapshot to fetch"; then
            print_timed "  [2/8] Secondary bucket empty, will fetch from primary... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q -E "Checking bucket storage|Trying to fetch a global snapshot from bucket storage"; then
            print_timed "  [1/8] Checking bucket storage... (+${delta}s)" >&2
            found_any=true
        fi

        # If no DataSnapshotLoader messages found yet
        if [ "$found_any" = false ]; then
            # Check if there are any DataSnapshotLoader logs at all
            local log_count
            if [ -n "$snapshot_logs" ]; then
                log_count=$(echo "$snapshot_logs" | wc -l | tr -d '[:space:]')
            else
                log_count=0
            fi
            if [ "${log_count:-0}" -gt 0 ]; then
                print_timed "  Found $log_count DataSnapshotLoader log entries, analyzing... (+${delta}s)" >&2
            else
                print_timed "  Waiting for DataSnapshotLoader to start... (+${delta}s)" >&2
            fi
        fi

        sleep 5
    done

    echo -e "${YELLOW}  WARN: Global snapshot fetch not detected within timeout${NC}" >&2
    echo -e "${YELLOW}  This may indicate DR recovery did not complete successfully${NC}" >&2
    echo "" >&2
    echo "  Troubleshooting:" >&2
    echo "    1. Check LogScale pod logs:" >&2
    if [ -n "$pod_name" ]; then
        echo "       kubectl --context $context -n $NAMESPACE logs $pod_name -c humio | grep DataSnapshotLoader" >&2
    else
        echo "       # First find the pod name:" >&2
        echo "       kubectl --context $context -n $NAMESPACE get pods -l 'app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator'" >&2
        echo "       # Then check logs:" >&2
        echo "       kubectl --context $context -n $NAMESPACE logs <POD_NAME> -c humio | grep DataSnapshotLoader" >&2
    fi
    echo "    2. Query in LogScale UI:" >&2
    echo "       DataSnapshotLoader" >&2
    echo "    3. See DR_OPERATIONS_GUIDE.md section 'Verify DR Recovery Succeeded'" >&2
    return 1
}

track_cloudwatch_alarm() {
  # Poll CloudWatch alarm state, track transition from OK -> ALARM
  local alarm_name="$1"
  local start_epoch="$2"
  local timeout="${3:-180}"
  local deadline=$((start_epoch + timeout))

  echo "Tracking CloudWatch alarm: $alarm_name" >&2

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local alarm_state
    alarm_state=$(aws cloudwatch describe-alarms \
      --alarm-names "$alarm_name" \
      --profile "$AWS_PROFILE" --region us-east-1 --output json 2>/dev/null | \
      jq -r '.MetricAlarms[0].StateValue // "UNKNOWN"')

    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))

    if [ "$alarm_state" = "ALARM" ]; then
      echo -e "  ${GREEN}CloudWatch alarm FIRED at $(epoch_to_iso "$now") (+${delta}s)${NC}" >&2
      echo "$now"
      return 0
    fi

    print_timed "  Alarm state: $alarm_state, waiting for ALARM... (+${delta}s)" >&2
    sleep 10
  done

  log_warn "CloudWatch alarm did not fire within ${timeout}s"
  return 1
}

# ============================================================================
# AWS Helper Functions
# ============================================================================

get_sns_topic_arn() {
  if [ -n "$SNS_TOPIC_ARN" ]; then
    echo "$SNS_TOPIC_ARN"
    return 0
  fi

  local topic_arn
  topic_arn=$(aws sns list-topics --profile "$AWS_PROFILE" --region us-east-1 --output json 2>/dev/null | \
    jq -r '.Topics[].TopicArn | select(contains("dr-failover") or contains("dr-secondary"))' | head -1)

  if [ -z "$topic_arn" ]; then
    echo ""
    return 1
  fi

  echo "$topic_arn"
}

trigger_lambda_via_sns() {
  if [ "$TRIGGER_LAMBDA" != "true" ]; then
    return 0
  fi

  local sns_topic_arn
  sns_topic_arn=$(get_sns_topic_arn) || sns_topic_arn=""

  if [ -z "$sns_topic_arn" ]; then
    log_warn "Could not find DR alerts SNS topic."
    echo "        The Lambda should be triggered automatically by CloudWatch alarm."
    return 0
  fi

  log_info "Triggering Lambda via SNS topic: $sns_topic_arn"

  local payload
  payload=$(cat <<EOFPAYLOAD
{
  "AlarmName": "DR-Failover-Simulation",
  "AlarmDescription": "Simulated primary failure for DR testing",
  "NewStateValue": "ALARM",
  "NewStateReason": "Simulated failure via simulate-aws-dr-failover.sh",
  "StateChangeTime": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "Trigger": {
    "MetricName": "HealthCheckStatus",
    "Namespace": "AWS/Route53"
  }
}
EOFPAYLOAD
)

  if aws sns publish --profile "$AWS_PROFILE" --region us-east-1 \
    --topic-arn "$sns_topic_arn" \
    --message "$payload" \
    --subject "ALARM: DR-Failover-Simulation" >/dev/null 2>&1; then
    echo -e "  ${GREEN}Successfully published message to SNS topic.${NC}"
  else
    log_warn "Could not publish to SNS topic."
  fi
}

get_primary_health_check_id() {
  if [ -n "$PRIMARY_HEALTH_CHECK_ID" ]; then
    echo "$PRIMARY_HEALTH_CHECK_ID"
    return 0
  fi

  [ -z "$PRIMARY_FQDN" ] && return 1

  local health_check_id
  # First try matching on the original FQDN
  health_check_id=$(aws route53 list-health-checks --profile "$AWS_PROFILE" --region us-east-1 --output json 2>/dev/null | \
    jq -r ".HealthChecks[] | select(.HealthCheckConfig.FullyQualifiedDomainName == \"$PRIMARY_FQDN\") | .Id" | head -1)

  # If not found, the FQDN may have been locked to failover-locked.invalid by the Lambda.
  # Filter by health check type=HTTPS (primary is always HTTPS, secondary is TCP) to
  # avoid matching unrelated health checks from other DR pairs in the same account.
  if [ -z "$health_check_id" ]; then
    health_check_id=$(aws route53 list-health-checks --profile "$AWS_PROFILE" --region us-east-1 --output json 2>/dev/null | \
      jq -r ".HealthChecks[] | select(.HealthCheckConfig.FullyQualifiedDomainName == \"failover-locked.invalid\") | select(.HealthCheckConfig.Type == \"HTTPS\") | .Id" | head -1)
    if [ -n "$health_check_id" ]; then
      log_debug "Found HTTPS health check via failover-locked.invalid FQDN (Lambda has locked it)"
    fi
  fi

  if [ -z "$health_check_id" ]; then
    echo ""
    return 1
  fi

  echo "$health_check_id"
}

get_health_check_fqdn() {
  local health_check_id="$1"
  aws route53 get-health-check --profile "$AWS_PROFILE" --region us-east-1 \
    --health-check-id "$health_check_id" --output json 2>/dev/null | \
    jq -r '.HealthCheck.HealthCheckConfig.FullyQualifiedDomainName // ""'
}

get_health_check_inverted() {
  local health_check_id="$1"
  aws route53 get-health-check --profile "$AWS_PROFILE" --region us-east-1 \
    --health-check-id "$health_check_id" --output json 2>/dev/null | \
    jq -r '.HealthCheck.HealthCheckConfig.Inverted // false'
}

# Check if health check FQDN is locked (set to failover-locked.invalid by Lambda)
is_health_check_fqdn_locked() {
  local health_check_id="$1"
  local fqdn
  fqdn=$(get_health_check_fqdn "$health_check_id")
  [ "$fqdn" = "failover-locked.invalid" ]
}

set_health_check_inverted() {
  local health_check_id="$1"
  local inverted="$2"

  log_info "Updating health check $health_check_id: Inverted=$inverted"

  local inverted_flag
  if [ "$inverted" = "true" ]; then
    inverted_flag="--inverted"
  else
    inverted_flag="--no-inverted"
  fi

  if aws route53 update-health-check --profile "$AWS_PROFILE" --region us-east-1 \
    --health-check-id "$health_check_id" \
    $inverted_flag >/dev/null 2>&1; then
    echo -e "  ${GREEN}Done.${NC}"
    return 0
  else
    log_error "Failed to update health check."
    return 1
  fi
}

# Restore health check FQDN from failover-locked.invalid back to the original primary FQDN.
# Also clears inversion flag to ensure clean state.
restore_health_check_fqdn() {
  local health_check_id="$1"
  local original_fqdn="$2"

  log_info "Restoring health check $health_check_id FQDN to $original_fqdn"

  if aws route53 update-health-check --profile "$AWS_PROFILE" --region us-east-1 \
    --health-check-id "$health_check_id" \
    --fully-qualified-domain-name "$original_fqdn" \
    --no-inverted >/dev/null 2>&1; then
    echo -e "  ${GREEN}Health check FQDN restored to $original_fqdn (Inverted=false).${NC}"
    return 0
  else
    log_error "Failed to restore health check FQDN."
    return 1
  fi
}

get_route53_health_check_status() {
  local health_check_id="$1"
  aws route53 get-health-check-status --profile "$AWS_PROFILE" --region us-east-1 \
    --health-check-id "$health_check_id" --output json 2>/dev/null | \
    jq -r '.HealthCheckObservations[0].StatusReport.Status // "Unknown"'
}

get_cloudwatch_alarm_name() {
  # Construct CloudWatch alarm name from pattern: ${cluster_name}-dr-failover-primary-unhealthy
  local cluster_name="${SECONDARY_CLUSTER_NAME:-dr-secondary}"
  echo "${cluster_name}-dr-failover-primary-unhealthy"
}

check_secondary_cluster_reachable() {
  kubectl --context "$SECONDARY_KUBE_CONTEXT" cluster-info >/dev/null 2>&1
}

# ============================================================================
# Pre-flight Check
# ============================================================================

preflight_check() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}               PRE-FLIGHT CHECK${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  local errors=0

  # Check 1: Secondary cluster reachable
  echo "Checking secondary cluster connectivity..."
  if ! check_secondary_cluster_reachable; then
    log_error "Cannot reach secondary cluster ($SECONDARY_KUBE_CONTEXT)."
    echo "         Ensure kubeconfig is configured and cluster is accessible."
    errors=$((errors + 1))
  else
    echo -e "  ${GREEN}Secondary cluster ($SECONDARY_KUBE_CONTEXT) is reachable.${NC}"
  fi

  # Check 2: Primary health check status
  echo ""
  echo "Checking Route53 health check status..."
  local health_check_id
  health_check_id=$(get_primary_health_check_id) || health_check_id=""

  if [ -n "$health_check_id" ]; then
    local hc_status hc_inverted hc_fqdn
    hc_status=$(get_route53_health_check_status "$health_check_id")
    hc_inverted=$(get_health_check_inverted "$health_check_id")
    hc_fqdn=$(get_health_check_fqdn "$health_check_id")

    echo "  Primary Health Check ID: $health_check_id"
    echo "  Status: $hc_status"
    echo "  Inverted: $hc_inverted"
    echo "  FQDN: $hc_fqdn"

    if [ "$hc_fqdn" = "failover-locked.invalid" ]; then
      log_warn "Primary health check FQDN is LOCKED to failover-locked.invalid."
      echo "        This indicates the DR Lambda has executed failover."
      echo "        Run 'failback' to restore the health check FQDN before proceeding."
    elif [ "$hc_inverted" = "true" ]; then
      log_warn "Primary health check is INVERTED."
      echo "        This may indicate a previous test was not cleaned up."
      echo "        Run 'failback' to reset the health check before proceeding."
    fi
  else
    log_warn "Could not find primary health check for FQDN: $PRIMARY_FQDN"
    echo "        Set PRIMARY_HEALTH_CHECK_ID environment variable if auto-detection fails."
  fi

  # Check 3: Secondary humio-operator state
  echo ""
  echo "Checking secondary humio-operator state..."
  local secondary_replicas
  secondary_replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT")
  echo "  Secondary humio-operator replicas: $secondary_replicas"

  if [ "${secondary_replicas:-0}" -ge 1 ]; then
    log_warn "Secondary humio-operator is already scaled up ($secondary_replicas replicas)."
    echo "        This may indicate a previous DR failover is active."
    echo "        Run 'failback' to reset the secondary cluster before proceeding."
  fi

  # Check 4: Primary endpoint health
  echo ""
  echo "Checking primary endpoint health..."
  if [ -n "$PRIMARY_FQDN" ]; then
    local primary_health
    primary_health=$(check_endpoint_health "$PRIMARY_FQDN")
    echo "  Primary endpoint ($PRIMARY_FQDN): HTTP $primary_health"

    if [ "$primary_health" != "200" ]; then
      log_warn "Primary endpoint is not healthy (HTTP $primary_health)."
      echo "        DR failover simulation requires a healthy primary to start."
      errors=$((errors + 1))
    fi
  else
    echo "  Primary FQDN not set, skipping endpoint check."
  fi

  echo ""
  echo "────────────────────────────────────────────────────────────────────"

  if [ "$errors" -gt 0 ]; then
    echo ""
    log_error "Pre-flight check failed with $errors error(s)."
    echo "       Fix the issues above before running DR failover simulation."
    return 1
  fi

  echo ""
  echo -e "${GREEN}Pre-flight check PASSED. Ready to proceed.${NC}"
  echo ""
  return 0
}

# ============================================================================
# Timing Summary
# ============================================================================

print_timing_summary() {
  local start_epoch="$1"
  local primary_down_epoch="${2:-}"
  local alarm_epoch="${3:-}"
  local operator_epoch="${4:-}"
  local pod_ready_epoch="${5:-}"
  local snapshot_epoch="${6:-}"
  local secondary_healthy_epoch="${7:-}"

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}               DR FAILOVER TIMING SUMMARY${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  printf "%-50s %s\n" "Event" "Timestamp (+delta)"
  echo "────────────────────────────────────────────────────────────────────"
  printf "%-50s %s\n" "1. Simulation started" "$(epoch_to_iso "$start_epoch") (+0s)"

  if [ -n "$primary_down_epoch" ]; then
    local delta=$((primary_down_epoch - start_epoch))
    printf "%-50s %s\n" "2. Primary endpoint unhealthy" "$(epoch_to_iso "$primary_down_epoch") (+${delta}s)"
  fi

  if [ -n "$alarm_epoch" ]; then
    local delta=$((alarm_epoch - start_epoch))
    printf "%-50s %s\n" "3. CloudWatch alarm fired" "$(epoch_to_iso "$alarm_epoch") (+${delta}s)"
  fi

  if [ -n "$operator_epoch" ]; then
    local delta=$((operator_epoch - start_epoch))
    printf "%-50s %s\n" "4. Secondary humio-operator scaled 0->1" "$(epoch_to_iso "$operator_epoch") (+${delta}s)"
  fi

  if [ -n "$pod_ready_epoch" ]; then
    local delta=$((pod_ready_epoch - start_epoch))
    printf "%-50s %s\n" "5. Secondary LogScale pod Ready" "$(epoch_to_iso "$pod_ready_epoch") (+${delta}s)"
  fi

  if [ -n "$snapshot_epoch" ]; then
    local delta=$((snapshot_epoch - start_epoch))
    printf "%-50s %s\n" "6. DR snapshot recovery complete" "$(epoch_to_iso "$snapshot_epoch") (+${delta}s)"
  fi

  if [ -n "$secondary_healthy_epoch" ]; then
    local delta=$((secondary_healthy_epoch - start_epoch))
    printf "%-50s %s\n" "7. Secondary endpoint healthy (DR complete)" "$(epoch_to_iso "$secondary_healthy_epoch") (+${delta}s)"
  fi

  echo "────────────────────────────────────────────────────────────────────"

  local total_time=0
  if [ -n "$secondary_healthy_epoch" ]; then
    total_time=$((secondary_healthy_epoch - start_epoch))
  elif [ -n "$pod_ready_epoch" ]; then
    total_time=$((pod_ready_epoch - start_epoch))
  fi

  if [ "$total_time" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}TOTAL FAILOVER TIME: ${total_time}s (~$((total_time/60))m $((total_time%60))s)${NC}"
  fi

  # Additional breakdowns
  if [ -n "$primary_down_epoch" ] && [ -n "$alarm_epoch" ]; then
    local alarm_latency=$((alarm_epoch - primary_down_epoch))
    echo "  Health check -> Alarm latency: ${alarm_latency}s"
  fi
  if [ -n "$operator_epoch" ] && [ -n "$pod_ready_epoch" ]; then
    local pod_startup=$((pod_ready_epoch - operator_epoch))
    echo "  Operator scale -> Pod ready: ${pod_startup}s"
  fi
  if [ -n "$pod_ready_epoch" ] && [ -n "$snapshot_epoch" ]; then
    local snapshot_time=$((snapshot_epoch - pod_ready_epoch))
    echo "  Pod ready -> Snapshot recovery: ${snapshot_time}s"
  fi

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# Status Display
# ============================================================================

show_status() {
  echo ""
  echo -e "${CYAN}=== Cluster Status ===${NC}"
  echo ""

  # Show configuration source
  if [ -n "$PRIMARY_TFVARS" ] || [ -n "$SECONDARY_TFVARS" ]; then
    echo "Configuration:"
    if [ -n "$PRIMARY_TFVARS" ]; then echo "  Primary tfvars:   $(basename "$PRIMARY_TFVARS")"; fi
    if [ -n "$SECONDARY_TFVARS" ]; then echo "  Secondary tfvars: $(basename "$SECONDARY_TFVARS")"; fi
    echo ""
  fi

  echo -e "${BLUE}PRIMARY ($PRIMARY_KUBE_CONTEXT):${NC}"
  echo "  humio-operator replicas: $(get_operator_replicas "$PRIMARY_KUBE_CONTEXT" 2>/dev/null || echo 'N/A')"
  echo "  LogScale pods:"
  local primary_pods
  primary_pods=$(get_logscale_pods "$PRIMARY_KUBE_CONTEXT")
  if [ -n "$primary_pods" ]; then
    echo "$primary_pods" | sed 's/^/    /'
  else
    echo "    (none)"
  fi
  if [ -n "$PRIMARY_FQDN" ]; then
    local primary_health
    primary_health=$(check_endpoint_health "$PRIMARY_FQDN")
    echo "  Endpoint health ($PRIMARY_FQDN): HTTP $primary_health"
  fi
  echo ""

  echo -e "${BLUE}SECONDARY ($SECONDARY_KUBE_CONTEXT):${NC}"
  echo "  humio-operator replicas: $(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo 'N/A')"
  echo "  LogScale pods:"
  local secondary_pods
  secondary_pods=$(get_logscale_pods "$SECONDARY_KUBE_CONTEXT")
  if [ -n "$secondary_pods" ]; then
    echo "$secondary_pods" | sed 's/^/    /'
  else
    echo "    (none)"
  fi
  if [ -n "$SECONDARY_FQDN" ]; then
    local secondary_health
    secondary_health=$(check_endpoint_health "$SECONDARY_FQDN")
    echo "  Endpoint health ($SECONDARY_FQDN): HTTP $secondary_health"
  fi
  echo ""

  # Route53 Health Check
  local health_check_id
  health_check_id=$(get_primary_health_check_id) || health_check_id=""
  if [ -n "$health_check_id" ]; then
    echo -e "${BLUE}Route53 Health Check:${NC}"
    local hc_status hc_inverted hc_fqdn
    hc_status=$(get_route53_health_check_status "$health_check_id" 2>/dev/null || echo "Unknown")
    hc_inverted=$(get_health_check_inverted "$health_check_id" 2>/dev/null || echo "Unknown")
    hc_fqdn=$(get_health_check_fqdn "$health_check_id" 2>/dev/null || echo "Unknown")
    echo "  Primary health check ID: $health_check_id"
    echo "  Status: $hc_status"
    echo "  FQDN: $hc_fqdn"
    echo "  Inverted: $hc_inverted"
    if [ "$hc_fqdn" = "failover-locked.invalid" ]; then
      echo -e "  ${YELLOW}WARNING: Health check FQDN is locked (failover active). Run 'failback' to restore.${NC}"
    fi
    echo ""
  fi

  # CloudWatch Alarm
  local alarm_name
  alarm_name=$(get_cloudwatch_alarm_name)
  local alarm_state
  alarm_state=$(aws cloudwatch describe-alarms \
    --alarm-names "$alarm_name" \
    --profile "$AWS_PROFILE" --region us-east-1 --output json 2>/dev/null | \
    jq -r '.MetricAlarms[0].StateValue // "NOT_FOUND"' 2>/dev/null || echo "N/A")
  if [ "$alarm_state" != "NOT_FOUND" ] && [ "$alarm_state" != "N/A" ]; then
    echo -e "${BLUE}CloudWatch Alarm:${NC}"
    echo "  Alarm name: $alarm_name"
    echo "  State: $alarm_state"
    echo ""
  fi

  # Lambda last invocation
  local lambda_name="${SECONDARY_CLUSTER_NAME:-dr-secondary}-dr-failover-handler"
  local last_modified
  last_modified=$(aws lambda get-function --function-name "$lambda_name" \
    --profile "$AWS_PROFILE" --region "${SECONDARY_AWS_REGION:-$AWS_REGION}" --output json 2>/dev/null | \
    jq -r '.Configuration.LastModified // "N/A"' 2>/dev/null || echo "N/A")
  if [ "$last_modified" != "N/A" ]; then
    echo -e "${BLUE}Lambda Function:${NC}"
    echo "  Function: $lambda_name"
    echo "  Last modified: $last_modified"
    echo ""
  fi

  # DNS Resolution
  if [ -n "$GLOBAL_DR_FQDN" ]; then
    echo -e "${BLUE}DNS Resolution:${NC}"
    echo "  Global DR FQDN ($GLOBAL_DR_FQDN):"
    if command -v dig >/dev/null 2>&1; then
      dig +short "$GLOBAL_DR_FQDN" 2>/dev/null | sed 's/^/    /' || echo "    (no records)"
    else
      nslookup "$GLOBAL_DR_FQDN" 2>/dev/null | grep -A5 "Name:" | sed 's/^/    /' || echo "    (no records)"
    fi
    echo ""
  fi
}

# ============================================================================
# DNS Failover Check
# ============================================================================

show_dns_failover_check() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}               DNS FAILOVER CHECK${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  local has_dig=false
  command -v dig >/dev/null 2>&1 && has_dig=true

  if [ -n "$PRIMARY_FQDN" ]; then
    echo -e "${BLUE}Primary FQDN:${NC} $PRIMARY_FQDN"
    echo "  DNS:"
    if [ "$has_dig" = true ]; then
      dig +short "$PRIMARY_FQDN" 2>/dev/null | sed 's/^/    /' || echo "    (no records)"
    fi
    local status
    status=$(check_endpoint_health "$PRIMARY_FQDN")
    echo "  HTTP Status: $status"
    echo ""
  fi

  if [ -n "$SECONDARY_FQDN" ]; then
    echo -e "${BLUE}Secondary FQDN:${NC} $SECONDARY_FQDN"
    echo "  DNS:"
    if [ "$has_dig" = true ]; then
      dig +short "$SECONDARY_FQDN" 2>/dev/null | sed 's/^/    /' || echo "    (no records)"
    fi
    local status
    status=$(check_endpoint_health "$SECONDARY_FQDN")
    echo "  HTTP Status: $status"
    echo ""
  fi

  if [ -n "$GLOBAL_DR_FQDN" ]; then
    echo -e "${BLUE}Global DR FQDN:${NC} $GLOBAL_DR_FQDN"
    echo "  DNS:"
    if [ "$has_dig" = true ]; then
      local global_ips
      global_ips=$(dig +short "$GLOBAL_DR_FQDN" 2>/dev/null || echo "")
      echo "$global_ips" | sed 's/^/    /' || echo "    (no records)"

      # Determine which cluster the global FQDN currently resolves to
      if [ -n "$global_ips" ]; then
        local primary_ips secondary_ips
        primary_ips=$(dig +short "$PRIMARY_FQDN" 2>/dev/null | sort || echo "")
        secondary_ips=$(dig +short "$SECONDARY_FQDN" 2>/dev/null | sort || echo "")
        local global_sorted
        global_sorted=$(echo "$global_ips" | sort)

        echo ""
        if [ "$global_sorted" = "$primary_ips" ]; then
          echo -e "  ${GREEN}Currently routing to: PRIMARY${NC}"
        elif [ "$global_sorted" = "$secondary_ips" ]; then
          echo -e "  ${YELLOW}Currently routing to: SECONDARY${NC}"
        else
          echo -e "  ${YELLOW}Could not determine routing target (IPs don't match either cluster)${NC}"
        fi
      fi
    fi
    local status
    status=$(check_endpoint_health "$GLOBAL_DR_FQDN")
    echo "  HTTP Status: $status"
    echo ""
  fi

  # Health check status
  local health_check_id
  health_check_id=$(get_primary_health_check_id) || health_check_id=""
  if [ -n "$health_check_id" ]; then
    echo -e "${BLUE}Route53 Health Check:${NC}"
    local hc_status hc_inverted hc_fqdn_dns
    hc_status=$(get_route53_health_check_status "$health_check_id")
    hc_inverted=$(get_health_check_inverted "$health_check_id")
    hc_fqdn_dns=$(get_health_check_fqdn "$health_check_id" 2>/dev/null || echo "Unknown")
    echo "  ID: $health_check_id"
    echo "  Status: $hc_status"
    echo "  FQDN: $hc_fqdn_dns"
    echo "  Inverted: $hc_inverted"
    if [ "$hc_fqdn_dns" = "failover-locked.invalid" ]; then
      echo -e "  ${YELLOW}FQDN is locked (failover active)${NC}"
    fi
    echo ""
  fi
}

# ============================================================================
# Scenario: primary-down
# ============================================================================

simulate_primary_down() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  SCENARIO: PRIMARY-DOWN (Scale operator to 0, delete pods)${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "This will:"
  echo "  1. Scale PRIMARY humio-operator to 0"
  echo "  1b. Delete PRIMARY LogScale pods (force, to trigger ALB health check failure)"
  echo "  2. Route53 health check fails -> CloudWatch alarm triggers"
  echo "  3. SNS -> Lambda scales SECONDARY humio-operator 0->1"
  echo "  4. Lambda locks the primary health check FQDN"
  echo "  5. Secondary LogScale recovers from primary S3 bucket"
  echo ""
  echo -e "${YELLOW}WARNING: This modifies the PRIMARY cluster! Use 'failback' to restore.${NC}"
  echo ""

  if ! preflight_check; then
    return 1
  fi

  show_status

  local current_primary_replicas
  current_primary_replicas=$(get_operator_replicas "$PRIMARY_KUBE_CONTEXT")

  if [ "${current_primary_replicas:-0}" -eq 0 ]; then
    log_warn "Primary humio-operator is already at 0 replicas."
    echo ""
  fi

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  INITIATING PRIMARY-DOWN SIMULATION${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  local start_epoch
  start_epoch=$(date +%s)
  local logscale_label="app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator"

  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 1: Scaling PRIMARY humio-operator to 0..."
  echo "────────────────────────────────────────────────────────────────────"
  scale_operator "$PRIMARY_KUBE_CONTEXT" 0 "PRIMARY"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 1b: Deleting PRIMARY LogScale pods to trigger endpoint failure..."
  echo "────────────────────────────────────────────────────────────────────"
  echo "  Note: Scaling operator to 0 does NOT delete managed pods."
  echo "  Deleting pods to trigger actual ALB health check failure."
  kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
    -l "$logscale_label" --force --grace-period=0 2>/dev/null || \
  kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
    -l "$logscale_label" --ignore-not-found=true 2>/dev/null || true
  echo -e "  ${GREEN}LogScale pods deleted.${NC}"

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}               TRACKING DR FAILOVER MILESTONES${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
  echo ""

  local primary_down_epoch="" alarm_epoch="" operator_epoch="" pod_ready_epoch="" snapshot_epoch="" secondary_healthy_epoch=""

  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 2: Waiting for PRIMARY endpoint to become unhealthy..."
  echo "────────────────────────────────────────────────────────────────────"
  primary_down_epoch=$(wait_for_primary_unhealthy "$start_epoch") || primary_down_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 3: Tracking CloudWatch alarm..."
  echo "────────────────────────────────────────────────────────────────────"
  echo "  Route53 health check interval: 10s, failure threshold: 3"
  echo "  CloudWatch alarm evaluation period: 60s"
  echo ""

  local alarm_name
  alarm_name=$(get_cloudwatch_alarm_name)
  alarm_epoch=$(track_cloudwatch_alarm "$alarm_name" "$start_epoch" 180) || alarm_epoch=""

  # Also trigger manually as fallback
  echo ""
  echo "  Triggering Lambda via SNS as fallback..."
  trigger_lambda_via_sns

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 4: Waiting for SECONDARY humio-operator to scale 0->1..."
  echo "────────────────────────────────────────────────────────────────────"
  operator_epoch=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || operator_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 5: Waiting for SECONDARY LogScale pod to become Ready..."
  echo "────────────────────────────────────────────────────────────────────"
  pod_ready_epoch=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || pod_ready_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 6: Tracking global snapshot fetch from primary bucket..."
  echo "────────────────────────────────────────────────────────────────────"
  snapshot_epoch=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || snapshot_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 7: Waiting for SECONDARY endpoint to become healthy..."
  echo "────────────────────────────────────────────────────────────────────"
  secondary_healthy_epoch=$(track_secondary_healthy "$start_epoch") || secondary_healthy_epoch=""

  print_timing_summary "$start_epoch" "$primary_down_epoch" "$alarm_epoch" "$operator_epoch" "$pod_ready_epoch" "$snapshot_epoch" "$secondary_healthy_epoch"

  echo ""
  echo -e "${YELLOW}IMPORTANT: Run 'failback' to restore both clusters to normal operation.${NC}"
  echo ""
  show_status
}

# ============================================================================
# Scenario: region-down / az-down / eks-down
# ============================================================================

simulate_region_down() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  SCENARIO: REGION-DOWN (Health Check FQDN Lock)${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "This will:"
  echo "  1. Lock the primary Route53 health check FQDN (healthy -> unhealthy)"
  echo "  2. Route53 failover DNS routes traffic to secondary"
  echo "  3. CloudWatch alarm triggers SNS -> Lambda"
  echo "  4. Lambda scales secondary humio-operator 0->1"
  echo "  5. Lambda locks the primary health check FQDN (already done by step 1)"
  echo "  6. Track DR failover pipeline activation"
  echo ""
  echo -e "${GREEN}NOTE: Primary LogScale pods are NOT affected - this simulates network isolation.${NC}"
  echo ""

  if ! preflight_check; then
    return 1
  fi

  show_status

  local health_check_id
  health_check_id=$(get_primary_health_check_id) || health_check_id=""

  if [ -z "$health_check_id" ]; then
    log_error "Could not find primary health check ID."
    echo "       Set PRIMARY_HEALTH_CHECK_ID or ensure health check exists for FQDN: $PRIMARY_FQDN"
    return 1
  fi

  echo "Primary Health Check ID: $health_check_id"
  local current_fqdn
  current_fqdn=$(get_health_check_fqdn "$health_check_id")
  echo "Current FQDN: $current_fqdn"
  echo ""

  if [ "$current_fqdn" = "failover-locked.invalid" ]; then
    log_warn "Health check FQDN is already locked to failover-locked.invalid. Skipping lock step."
    echo ""
  fi

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  INITIATING REGION-DOWN SIMULATION${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  local start_epoch
  start_epoch=$(date +%s)

  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 1: Locking PRIMARY health check FQDN..."
  echo "────────────────────────────────────────────────────────────────────"
  echo "  Action: Swapping health check FQDN to failover-locked.invalid"
  echo "  Effect: Health check will always fail (NXDOMAIN) regardless of primary state"
  echo "  Result: Route53 failover DNS will route traffic to secondary"
  echo ""
  if ! is_health_check_fqdn_locked "$health_check_id"; then
    log_info "Locking health check $health_check_id FQDN to failover-locked.invalid"
    aws route53 update-health-check --profile "$AWS_PROFILE" --region us-east-1 \
      --health-check-id "$health_check_id" \
      --fully-qualified-domain-name "failover-locked.invalid" \
      --no-inverted >/dev/null 2>&1 && \
      echo -e "  ${GREEN}Health check FQDN locked to failover-locked.invalid.${NC}" || \
      log_error "Failed to lock health check FQDN."
  else
    echo "  Health check FQDN already locked. Skipping."
  fi

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 2: Waiting for Route53 to detect health check failure..."
  echo "────────────────────────────────────────────────────────────────────"
  echo "  Route53 health check interval: 10s, failure threshold: 3"
  echo "  Expected time to UNHEALTHY: ~30 seconds"
  echo ""

  local unhealthy_epoch=""
  local deadline=$((start_epoch + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local hc_status
    hc_status=$(aws route53 get-health-check-status --profile "$AWS_PROFILE" --region us-east-1 \
      --health-check-id "$health_check_id" --output json 2>/dev/null | \
      jq -r '.HealthCheckObservations[0].StatusReport.Status // "Unknown"')

    if echo "$hc_status" | grep -qi "failure"; then
      unhealthy_epoch=$(date +%s)
      local delta=$((unhealthy_epoch - start_epoch))
      echo -e "  ${GREEN}Health check now UNHEALTHY at $(epoch_to_iso "$unhealthy_epoch") (+${delta}s)${NC}"
      break
    fi

    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))
    print_timed "  Health check status: $hc_status (waiting... +${delta}s)"
    sleep 5
  done

  if [ -z "$unhealthy_epoch" ]; then log_warn "Health check did not become unhealthy within 120s"; fi

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}               TRACKING DR FAILOVER MILESTONES${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
  echo ""

  local alarm_epoch="" operator_epoch="" pod_ready_epoch="" snapshot_epoch="" secondary_healthy_epoch=""

  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 3: Tracking CloudWatch alarm..."
  echo "────────────────────────────────────────────────────────────────────"
  local alarm_name
  alarm_name=$(get_cloudwatch_alarm_name)
  alarm_epoch=$(track_cloudwatch_alarm "$alarm_name" "$start_epoch" 180) || alarm_epoch=""

  echo ""
  echo "  Triggering Lambda via SNS as fallback..."
  trigger_lambda_via_sns

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 4: Waiting for SECONDARY humio-operator to scale 0->1..."
  echo "────────────────────────────────────────────────────────────────────"
  operator_epoch=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || operator_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 5: Waiting for SECONDARY LogScale pod to become Ready..."
  echo "────────────────────────────────────────────────────────────────────"
  pod_ready_epoch=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || pod_ready_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 6: Tracking global snapshot fetch from primary bucket..."
  echo "────────────────────────────────────────────────────────────────────"
  snapshot_epoch=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || snapshot_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 7: Waiting for SECONDARY endpoint to become healthy..."
  echo "────────────────────────────────────────────────────────────────────"
  secondary_healthy_epoch=$(track_secondary_healthy "$start_epoch") || secondary_healthy_epoch=""

  print_timing_summary "$start_epoch" "$unhealthy_epoch" "$alarm_epoch" "$operator_epoch" "$pod_ready_epoch" "$snapshot_epoch" "$secondary_healthy_epoch"

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}               IMPORTANT: RESTORE HEALTH CHECK FQDN${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "The health check FQDN is still locked to failover-locked.invalid. To restore normal operation:"
  echo ""
  echo "  aws route53 update-health-check --health-check-id $health_check_id --fully-qualified-domain-name \"$PRIMARY_FQDN\" --no-inverted --profile $AWS_PROFILE"
  echo ""
  echo "Or run: $0 failback"
  echo ""

  show_status
}

# ============================================================================
# Scenario: transient-outage
# ============================================================================

simulate_transient_outage() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  SCENARIO: TRANSIENT-OUTAGE (Anti-Flap Test)${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "This will:"
  echo "  1. Verify SECONDARY humio-operator is at 0 replicas"
  echo "  2. Lock PRIMARY health check FQDN for ${TRANSIENT_OUTAGE_DURATION_SECONDS}s"
  echo "  3. Restore PRIMARY health check FQDN"
  echo "  4. Observe SECONDARY humio-operator for ${TRANSIENT_OBSERVATION_SECONDS}s"
  echo "  5. Confirm SECONDARY did NOT scale to 1 (anti-flap gating test)"
  echo ""
  echo -e "${CYAN}NOTE: This tests PRE_FAILOVER_FAILURE_SECONDS anti-flap protection.${NC}"
  echo -e "${CYAN}      If PRE_FAILOVER_FAILURE_SECONDS=0 (test mode), this WILL trigger failover.${NC}"
  echo ""

  local health_check_id
  health_check_id=$(get_primary_health_check_id) || health_check_id=""

  if [ -z "$health_check_id" ]; then
    log_error "Could not find primary health check ID."
    return 1
  fi

  # Check secondary is at 0
  local secondary_replicas
  secondary_replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
  if [ "${secondary_replicas:-0}" -ne 0 ]; then
    log_warn "SECONDARY humio-operator is currently at ${secondary_replicas} replicas."
    echo "      Run 'failback' to reset secondary to 0 before running transient-outage."
    return 1
  fi

  echo "Configuration:"
  echo "  Health check ID:     $health_check_id"
  echo "  Outage duration:     ${TRANSIENT_OUTAGE_DURATION_SECONDS}s"
  echo "  Observation window:  ${TRANSIENT_OBSERVATION_SECONDS}s"
  echo ""

  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 1: Locking PRIMARY health check FQDN..."
  echo "────────────────────────────────────────────────────────────────────"
  log_info "Locking health check $health_check_id FQDN to failover-locked.invalid"
  aws route53 update-health-check --profile "$AWS_PROFILE" --region us-east-1 \
    --health-check-id "$health_check_id" \
    --fully-qualified-domain-name "failover-locked.invalid" \
    --no-inverted >/dev/null 2>&1 && \
    echo -e "  ${GREEN}Health check FQDN locked.${NC}" || \
    log_error "Failed to lock health check FQDN."

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 2: Waiting ${TRANSIENT_OUTAGE_DURATION_SECONDS}s (simulating brief outage)..."
  echo "────────────────────────────────────────────────────────────────────"
  local countdown=$TRANSIENT_OUTAGE_DURATION_SECONDS
  while [ "$countdown" -gt 0 ]; do
    echo "  Outage active: ${countdown}s remaining..."
    local sleep_time=$((countdown < 10 ? countdown : 10))
    sleep "$sleep_time"
    countdown=$((countdown - sleep_time))
  done

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 3: Restoring PRIMARY health check FQDN..."
  echo "────────────────────────────────────────────────────────────────────"
  restore_health_check_fqdn "$health_check_id" "$PRIMARY_FQDN"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 4: Observing SECONDARY humio-operator for ${TRANSIENT_OBSERVATION_SECONDS}s..."
  echo "────────────────────────────────────────────────────────────────────"
  local start_epoch
  start_epoch=$(date +%s)
  local deadline=$((start_epoch + TRANSIENT_OBSERVATION_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local replicas
    replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
    if [ "${replicas:-0}" -ne 0 ]; then
      echo ""
      echo -e "${RED}FAIL: SECONDARY humio-operator scaled to ${replicas} during transient outage window.${NC}"
      echo "      This suggests anti-flap gating (PRE_FAILOVER_FAILURE_SECONDS) is not working."
      return 1
    fi
    local now delta
    now=$(date +%s)
    delta=$((now - start_epoch))
    echo "  OK: secondary still at 0 replicas (+${delta}s)"
    sleep 10
  done

  echo ""
  echo -e "${GREEN}PASS: Secondary did not scale during transient outage.${NC}"
  echo -e "${GREEN}      Anti-flap gating is working correctly.${NC}"
  show_status
}

# ============================================================================
# Scenario: logscale-crash
# ============================================================================

simulate_logscale_crash() {
  local crash_mode="${CRASH_MODE:-kill-process}"

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  SCENARIO: LOGSCALE-CRASH (mode: $crash_mode)${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "Crash modes:"
  echo "  kill-process  : Send SIGKILL (kill -9) to PID 1 inside LogScale container"
  echo "  block-health  : Block health endpoint port 8080 via iptables inside container"
  echo ""
  echo -e "Active mode: ${YELLOW}$crash_mode${NC}"
  echo ""

  local pod_name
  pod_name=$(get_logscale_pod_name "$PRIMARY_KUBE_CONTEXT")

  if [ -z "$pod_name" ]; then
    log_error "No LogScale pod found on primary cluster."
    return 1
  fi

  echo "Target pod: $pod_name"
  echo ""

  local start_epoch
  start_epoch=$(date +%s)

  case "$crash_mode" in
    kill-process)
      echo "────────────────────────────────────────────────────────────────────"
      echo "Step 1: Killing LogScale process (PID 1) in pod $pod_name..."
      echo "────────────────────────────────────────────────────────────────────"
      kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" exec "$pod_name" -c humio -- \
        kill -9 1 2>/dev/null || true
      echo -e "  ${GREEN}SIGKILL sent to PID 1.${NC}"
      echo "  Pod should restart (CrashLoopBackOff) or be recreated by operator."
      ;;

    block-health)
      echo "────────────────────────────────────────────────────────────────────"
      echo "Step 1: Blocking health endpoint (port 8080) in pod $pod_name..."
      echo "────────────────────────────────────────────────────────────────────"
      kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" exec "$pod_name" -c humio -- \
        sh -c 'iptables -A INPUT -p tcp --dport 8080 -j DROP 2>/dev/null || echo "iptables not available"' 2>/dev/null || true
      echo -e "  ${GREEN}Health endpoint port 8080 blocked via iptables.${NC}"
      echo "  ALB health checks will fail, triggering Route53 failover."
      echo ""
      echo -e "  ${YELLOW}NOTE: To restore, run failback or manually:${NC}"
      echo "  kubectl --context $PRIMARY_KUBE_CONTEXT -n $NAMESPACE exec $pod_name -c humio -- iptables -D INPUT -p tcp --dport 8080 -j DROP"
      ;;

    *)
      log_error "Unknown crash mode: $crash_mode"
      echo "  Valid modes: kill-process, block-health"
      return 1
      ;;
  esac

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}               TRACKING DR FAILOVER MILESTONES${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
  echo ""

  local primary_down_epoch="" alarm_epoch="" operator_epoch="" pod_ready_epoch="" snapshot_epoch="" secondary_healthy_epoch=""

  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 2: Waiting for PRIMARY endpoint to become unhealthy..."
  echo "────────────────────────────────────────────────────────────────────"
  primary_down_epoch=$(wait_for_primary_unhealthy "$start_epoch") || primary_down_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 3: Tracking CloudWatch alarm..."
  echo "────────────────────────────────────────────────────────────────────"
  local alarm_name
  alarm_name=$(get_cloudwatch_alarm_name)
  alarm_epoch=$(track_cloudwatch_alarm "$alarm_name" "$start_epoch" 180) || alarm_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 4: Waiting for SECONDARY humio-operator to scale 0->1..."
  echo "────────────────────────────────────────────────────────────────────"
  operator_epoch=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || operator_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 5: Waiting for SECONDARY LogScale pod to become Ready..."
  echo "────────────────────────────────────────────────────────────────────"
  pod_ready_epoch=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || pod_ready_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 6: Tracking global snapshot fetch from primary bucket..."
  echo "────────────────────────────────────────────────────────────────────"
  snapshot_epoch=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start_epoch") || snapshot_epoch=""

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 7: Waiting for SECONDARY endpoint to become healthy..."
  echo "────────────────────────────────────────────────────────────────────"
  secondary_healthy_epoch=$(track_secondary_healthy "$start_epoch") || secondary_healthy_epoch=""

  print_timing_summary "$start_epoch" "$primary_down_epoch" "$alarm_epoch" "$operator_epoch" "$pod_ready_epoch" "$snapshot_epoch" "$secondary_healthy_epoch"

  echo ""
  echo -e "${YELLOW}IMPORTANT: Run 'failback' to restore both clusters.${NC}"
  echo ""
  show_status
}

# ============================================================================
# Scenario: failback
# ============================================================================

simulate_failback() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  SCENARIO: FAILBACK to PRIMARY${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "This will:"
  echo "  0. Clean up test artifacts (logscale-crash iptables rules)"
  echo "  1. Disable CloudWatch alarm actions (prevent re-triggering during restoration)"
  echo "  2. Restore PRIMARY health check FQDN (from failover-locked.invalid)"
  echo "  3. Scale PRIMARY humio-operator to 1 (if needed)"
  echo "  4. Wait for PRIMARY endpoint to become healthy"
  echo "  4b. Wait for Global DR FQDN to route to primary (DNS failback)"
  echo "  5. Scale SECONDARY humio-operator to 0"
  echo "  6. Delete SECONDARY LogScale pods"
  echo "  7. Wait for SECONDARY LogScale pods to terminate"
  echo "  8. Scale SECONDARY strimzi-cluster-operator to 0"
  echo "  9. Delete SECONDARY Strimzi Kafka pods (force)"
  echo "  10. Wait for SECONDARY Kafka pods to terminate"
  echo "  11. Delete SECONDARY Strimzi Kafka PVCs"
  echo "  12. Delete SECONDARY StrimziPodSet"
  echo "  13. Scale SECONDARY strimzi-cluster-operator back to 1"
  echo "  14. Delete SECONDARY S3 bucket contents"
  echo "  15. Re-enable CloudWatch alarm actions"
  echo ""

  show_status

  local start_epoch
  start_epoch=$(date +%s)
  local kafka_pod_label="strimzi.io/kind=Kafka,strimzi.io/component-type=kafka"
  local kafka_pvc_label="strimzi.io/kind=Kafka,strimzi.io/component-type=kafka"
  local logscale_label="app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator"

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  TEST ARTIFACT CLEANUP${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 0: Cleaning up test artifacts (logscale-crash)..."
  echo "────────────────────────────────────────────────────────────────────"
  # Restore health endpoint if blocked (from logscale-crash block-health mode)
  local primary_pod
  primary_pod=$(get_logscale_pod_name "$PRIMARY_KUBE_CONTEXT")
  if [ -n "$primary_pod" ]; then
    echo "  Checking for iptables rules on pod: $primary_pod"
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" exec "$primary_pod" -c humio -- \
      sh -c 'iptables -D INPUT -p tcp --dport 8080 -j DROP 2>/dev/null' 2>/dev/null || true
    echo -e "  ${GREEN}iptables cleanup done (no-op if rule didn't exist).${NC}"

    # Check primary pod health
    local pod_ready
    pod_ready=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get pod "$primary_pod" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    local pod_phase
    pod_phase=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get pod "$primary_pod" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  PRIMARY LogScale pod: $primary_pod (phase: $pod_phase, ready: $pod_ready)"

    if [ "$pod_ready" != "True" ] || [ "$pod_phase" != "Running" ]; then
      log_warn "Pod is not healthy. Forcing restart..."
      kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pod "$primary_pod" \
        --force --grace-period=0 2>/dev/null || \
      kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pod "$primary_pod" 2>/dev/null || true
      echo "  Pod deletion initiated. Operator will recreate it."
    fi
  else
    echo "  No PRIMARY LogScale pod found. Skipping."
  fi

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  ALARM MANAGEMENT${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 1: Disabling CloudWatch alarm actions (prevent re-triggering)..."
  echo "────────────────────────────────────────────────────────────────────"
  local alarm_name
  alarm_name=$(get_cloudwatch_alarm_name)
  if [ -n "$alarm_name" ]; then
    log_debug "Disabling alarm actions for: $alarm_name"
    if aws cloudwatch disable-alarm-actions --alarm-names "$alarm_name" \
      --profile "$AWS_PROFILE" --region us-east-1 2>/dev/null; then
      echo -e "  ${GREEN}Alarm actions disabled. Lambda will not be triggered during restoration.${NC}"
    else
      log_warn "Could not disable alarm actions. Continuing anyway."
    fi
  else
    echo "  Could not determine alarm name. Skipping."
  fi

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  PRIMARY CLUSTER RESTORATION${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 2: Restoring PRIMARY health check FQDN..."
  echo "────────────────────────────────────────────────────────────────────"
  local health_check_id
  health_check_id=$(get_primary_health_check_id) || health_check_id=""

  if [ -n "$health_check_id" ]; then
    # Check if FQDN is locked to failover-locked.invalid (new Lambda approach)
    if is_health_check_fqdn_locked "$health_check_id"; then
      echo "  Health check FQDN is locked to failover-locked.invalid."
      echo "  Restoring FQDN to $PRIMARY_FQDN..."
      restore_health_check_fqdn "$health_check_id" "$PRIMARY_FQDN"
    else
      local current_fqdn
      current_fqdn=$(get_health_check_fqdn "$health_check_id")
      echo "  Health check FQDN: $current_fqdn"
      # Also clear inversion flag if set (legacy or manual override)
      local current_inverted
      current_inverted=$(get_health_check_inverted "$health_check_id")
      if [ "$current_inverted" = "true" ]; then
        echo "  Health check is INVERTED (legacy). Reverting to normal..."
        set_health_check_inverted "$health_check_id" "false"
      else
        echo "  Health check FQDN is correct and not inverted. No action needed."
      fi
    fi
  else
    echo "  Could not find health check ID. Skipping health check restoration."
  fi

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 3: Scaling PRIMARY humio-operator to 1 (if needed)..."
  echo "────────────────────────────────────────────────────────────────────"
  local primary_replicas
  primary_replicas=$(get_operator_replicas "$PRIMARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
  if [ "${primary_replicas:-0}" -eq 0 ]; then
    echo "  Primary humio-operator is at 0 replicas. Scaling to 1..."
    scale_operator "$PRIMARY_KUBE_CONTEXT" 1 "PRIMARY"
    echo -e "  ${GREEN}Primary humio-operator scaled to 1.${NC}"
  else
    echo "  Primary humio-operator already at ${primary_replicas} replica(s). No action needed."
  fi

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 4: Waiting for PRIMARY endpoint to become healthy..."
  echo "────────────────────────────────────────────────────────────────────"
  local primary_healthy_epoch
  primary_healthy_epoch=$(wait_for_endpoint_healthy "$PRIMARY_FQDN" "$start_epoch") || primary_healthy_epoch=""
  if [ -n "$primary_healthy_epoch" ]; then
    local delta=$((primary_healthy_epoch - start_epoch))
    echo -e "  ${GREEN}Primary endpoint healthy after ${delta}s.${NC}"
  else
    log_warn "Primary endpoint did not become healthy within timeout."
    echo "        Continuing with secondary cleanup..."
  fi

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 4b: Waiting for Global DR FQDN to route to primary..."
  echo "────────────────────────────────────────────────────────────────────"
  if [ -n "$GLOBAL_DR_FQDN" ]; then
    echo "  After restoring the health check, Route53 needs time to recognize the"
    echo "  primary is healthy and switch the failover DNS record back."
    echo "  Monitoring: $GLOBAL_DR_FQDN"
    echo ""
    local global_healthy_epoch
    global_healthy_epoch=$(wait_for_endpoint_healthy "$GLOBAL_DR_FQDN" "$start_epoch") || global_healthy_epoch=""
    if [ -n "$global_healthy_epoch" ]; then
      local delta=$((global_healthy_epoch - start_epoch))
      echo -e "  ${GREEN}Global DR FQDN healthy (HTTP 200) after ${delta}s.${NC}"
      echo "  DNS has failed back to primary. Safe to tear down secondary."
    else
      log_warn "Global DR FQDN did not become healthy within timeout."
      echo "        The secondary may still be serving traffic via the global FQDN."
      echo "        Continuing with secondary cleanup (may cause brief 503 on global FQDN)..."
    fi
  else
    echo "  No GLOBAL_DR_FQDN configured. Skipping."
  fi

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  SECONDARY CLUSTER RESET${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 5: Scaling SECONDARY humio-operator to 0..."
  echo "────────────────────────────────────────────────────────────────────"
  scale_operator "$SECONDARY_KUBE_CONTEXT" 0 "SECONDARY"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 6: Deleting SECONDARY LogScale pods..."
  echo "────────────────────────────────────────────────────────────────────"
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
    -l "$logscale_label" --ignore-not-found=true 2>/dev/null || true
  echo "  Delete command issued."

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 7: Waiting for SECONDARY LogScale pods to terminate..."
  echo "────────────────────────────────────────────────────────────────────"
  wait_for_pods_deleted "$SECONDARY_KUBE_CONTEXT" "$logscale_label" 120 || true

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 8: Scaling SECONDARY strimzi-cluster-operator to 0..."
  echo "────────────────────────────────────────────────────────────────────"
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" scale deployment strimzi-cluster-operator --replicas=0 2>/dev/null && echo -e "  ${GREEN}Done.${NC}" || log_warn "Could not scale strimzi-cluster-operator"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 9: Deleting SECONDARY Strimzi Kafka pods..."
  echo "────────────────────────────────────────────────────────────────────"
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
    -l "$kafka_pod_label" --ignore-not-found=true --force --grace-period=0 2>/dev/null || \
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
    -l "$kafka_pod_label" --ignore-not-found=true 2>/dev/null || true
  echo "  Delete command issued."

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 10: Waiting for SECONDARY Kafka pods to terminate..."
  echo "────────────────────────────────────────────────────────────────────"
  wait_for_pods_deleted "$SECONDARY_KUBE_CONTEXT" "$kafka_pod_label" 120 || true

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 11: Deleting SECONDARY Strimzi Kafka PVCs..."
  echo "────────────────────────────────────────────────────────────────────"
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pvc \
    -l "$kafka_pvc_label" --ignore-not-found=true 2>/dev/null || true

  echo "  Waiting for PVCs to be deleted..."
  local pvc_deadline=$(($(date +%s) + 60))
  while [ "$(date +%s)" -lt "$pvc_deadline" ]; do
    local pvc_count
    pvc_count=$(kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" get pvc -l "$kafka_pvc_label" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${pvc_count:-0}" -eq 0 ]; then
      echo -e "  ${GREEN}Kafka PVCs deleted.${NC}"
      break
    fi
    echo "  Waiting for $pvc_count PVC(s) to terminate..."
    sleep 5
  done

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 12: Deleting SECONDARY StrimziPodSet (reset Kafka state)..."
  echo "────────────────────────────────────────────────────────────────────"
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete strimzipodset \
    --all --ignore-not-found=true 2>/dev/null || true
  echo -e "  ${GREEN}StrimziPodSet deleted.${NC}"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 13: Scaling SECONDARY strimzi-cluster-operator back to 1..."
  echo "────────────────────────────────────────────────────────────────────"
  kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" scale deployment strimzi-cluster-operator --replicas=1 2>/dev/null && echo -e "  ${GREEN}Done.${NC}" || log_warn "Could not scale strimzi-cluster-operator"

  echo ""
  echo "  Waiting for Strimzi to recreate Kafka pods (30s)..."
  sleep 30

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 14: Deleting SECONDARY S3 bucket contents (reset storage state)..."
  echo "────────────────────────────────────────────────────────────────────"
  local secondary_bucket
  secondary_bucket=$(kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" get humiocluster -o jsonpath='{.items[0].spec.commonEnvironmentVariables[?(@.name=="S3_STORAGE_BUCKET")].value}' 2>/dev/null || echo "")
  if [ -n "$secondary_bucket" ]; then
    echo "  Deleting all objects in s3://${secondary_bucket}/..."
    echo "  (This may take a few minutes depending on bucket size)"
    if aws s3 rm "s3://${secondary_bucket}/" --recursive --only-show-errors --profile "$AWS_PROFILE" 2>&1; then
      echo -e "  ${GREEN}S3 bucket contents deleted successfully.${NC}"
    else
      echo "  Bucket empty or deletion completed with warnings."
    fi
    # Verify
    local remaining_objects
    remaining_objects=$(aws s3 ls "s3://${secondary_bucket}/" --profile "$AWS_PROFILE" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${remaining_objects:-0}" -eq 0 ]; then
      echo -e "  ${GREEN}Verified: S3 bucket is now empty.${NC}"
    else
      log_warn "$remaining_objects object(s) may still remain. Manual verification recommended."
    fi
  else
    log_warn "Could not determine secondary bucket name. Manual cleanup may be required."
  fi

  echo ""
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  ALARM RESTORATION${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "Step 15: Re-enabling CloudWatch alarm actions..."
  echo "────────────────────────────────────────────────────────────────────"
  if [ -n "$alarm_name" ]; then
    if aws cloudwatch enable-alarm-actions --alarm-names "$alarm_name" \
      --profile "$AWS_PROFILE" --region us-east-1 2>/dev/null; then
      echo -e "  ${GREEN}Alarm actions re-enabled. DR failover automation is active.${NC}"
    else
      log_warn "Could not re-enable alarm actions. Manual re-enable may be required:"
      echo "    aws cloudwatch enable-alarm-actions --alarm-names \"$alarm_name\" --profile \"$AWS_PROFILE\" --region us-east-1"
    fi
  else
    echo "  Could not determine alarm name. Skipping."
    echo "  Manually re-enable with:"
    echo "    aws cloudwatch enable-alarm-actions --alarm-names \"<alarm-name>\" --profile \"$AWS_PROFILE\" --region us-east-1"
  fi

  echo ""
  local end_epoch
  end_epoch=$(date +%s)
  local duration=$((end_epoch - start_epoch))

  echo -e "${GREEN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}               FAILBACK COMPLETE${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "Failback completed in ${duration}s (~$((duration/60))m $((duration%60))s)."
  echo ""

  show_status
}

# ============================================================================
# Main
# ============================================================================

parse_args "$@"

# Resolve all configuration from tfvars + env vars
resolve_cluster_configuration

# Validate required configuration
if [ -z "$AWS_PROFILE" ]; then
  log_error "AWS_PROFILE must be set (via environment or tfvars aws_profile)."
  exit 1
fi

# Validate FQDNs for scenarios that need them
case "$SCENARIO" in
  status|dns-failover-check)
    # These scenarios work with partial config
    ;;
  *)
    if [ -z "$PRIMARY_FQDN" ] || [ -z "$SECONDARY_FQDN" ]; then
      log_error "PRIMARY_FQDN and SECONDARY_FQDN must be set."
      echo "  Auto-discovery failed or no tfvars files found." >&2
      echo "  Set them via environment variables or use --primary/--secondary flags." >&2
      exit 1
    fi
    ;;
esac

# Print banner
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}               AWS DR FAILOVER SIMULATION${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Scenario:          $SCENARIO"
echo "AWS Profile:       $AWS_PROFILE"
echo "AWS Region:        $AWS_REGION"
echo "Primary Context:   $PRIMARY_KUBE_CONTEXT"
echo "Secondary Context: $SECONDARY_KUBE_CONTEXT"
echo "Namespace:         $NAMESPACE"
if [ -n "$PRIMARY_FQDN" ]; then echo "Primary FQDN:      $PRIMARY_FQDN"; fi
if [ -n "$SECONDARY_FQDN" ]; then echo "Secondary FQDN:    $SECONDARY_FQDN"; fi
if [ -n "$GLOBAL_DR_FQDN" ]; then echo "Global DR FQDN:    $GLOBAL_DR_FQDN"; fi
echo ""

# Dispatch scenario
case "$SCENARIO" in
  primary-down)
    simulate_primary_down
    ;;
  az-down|eks-down)
    # AZ-down and EKS-down use region-down (health check FQDN lock)
    simulate_region_down
    ;;
  region-down)
    simulate_region_down
    ;;
  transient-outage)
    simulate_transient_outage
    ;;
  logscale-crash)
    simulate_logscale_crash
    ;;
  dns-failover-check)
    show_dns_failover_check
    ;;
  failback)
    simulate_failback
    ;;
  status)
    show_status
    ;;
  *)
    log_error "Unknown scenario '$SCENARIO'"
    usage
    exit 1
    ;;
esac

echo ""
echo "Done."
