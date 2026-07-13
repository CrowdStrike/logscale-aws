"""
DR Failover Lambda Handler

This Lambda function handles automatic DR failover for LogScale clusters.
When the primary cluster's Route53 health check fails, this function:
1. Validates the health check status
2. Cleans up stale TLS secrets to prevent CA mismatch
3. Scales the humio-operator deployment to start LogScale pods
4. Locks DNS to secondary by pointing the primary health check FQDN to an
   unresolvable host, ensuring it always fails regardless of primary state

Failback requires manual operator action: restore the primary health check FQDN
after verifying primary readiness (data sync complete, LogScale caught up,
Kafka partitions reassigned, etc.).

Features:
- Exponential backoff retry logic for transient Kubernetes API failures
- Jitter to prevent thundering herd problem
- Configurable retry parameters via environment variables
- Detailed logging and retry statistics for observability
"""

import base64
import json
import logging
import os
import random
import tempfile
import time
from dataclasses import dataclass, field
from functools import wraps
from typing import Callable, Optional

import boto3
import botocore.session
from botocore.signers import RequestSigner
from kubernetes import client as k8s_client
from kubernetes.client.rest import ApiException

# Configure logging
LOG = logging.getLogger(__name__)
LOG.setLevel(os.getenv("LOG_LEVEL", "INFO"))

# =============================================================================
# Configuration from Environment Variables
# =============================================================================

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
CLUSTER_REGION = os.environ["CLUSTER_REGION"]
NAMESPACE = os.environ.get("CLUSTER_NAMESPACE", "logging")
TARGET_OPERATOR_REPLICAS = int(os.environ.get("TARGET_OPERATOR_REPLICAS", "1"))
PRIMARY_HEALTH_CHECK_ID = os.environ["PRIMARY_HEALTH_CHECK_ID"]
SECONDARY_HEALTH_CHECK_ID = os.environ.get("SECONDARY_HEALTH_CHECK_ID", "")
SKIP_SECONDARY_HEALTH_CHECK = os.environ.get("SKIP_SECONDARY_HEALTH_CHECK", "false").lower() == "true"
PRIMARY_HEALTH_CHECK_FQDN = os.environ.get("PRIMARY_HEALTH_CHECK_FQDN", "")
# Unresolvable FQDN used to lock the primary health check to permanent failure.
# The .invalid TLD is reserved by RFC 2606 and guaranteed to never resolve.
FAILOVER_LOCK_FQDN = "failover-locked.invalid"
HUMIOCLUSTER_NAME = os.environ.get("HUMIOCLUSTER_NAME", "")

# Pre-failover validation configuration
PRE_FAILOVER_FAILURE_SECONDS = int(os.environ.get("PRE_FAILOVER_FAILURE_SECONDS", "180"))
FAILOVER_COOLDOWN_SECONDS = int(os.environ.get("FAILOVER_COOLDOWN_SECONDS", "300"))

# SSM parameter name for persisting the last failover timestamp.
# When set, the cooldown survives Lambda cold starts.
COOLDOWN_SSM_PARAMETER = os.environ.get("COOLDOWN_SSM_PARAMETER", "")

# Retry configuration (with sensible defaults)
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
BASE_DELAY_SECONDS = float(os.environ.get("BASE_DELAY_SECONDS", "1.0"))
MAX_DELAY_SECONDS = float(os.environ.get("MAX_DELAY_SECONDS", "30.0"))

# AWS clients
session = boto3.session.Session()
route53 = session.client("route53")
eks = session.client("eks", region_name=CLUSTER_REGION)
cloudwatch = session.client("cloudwatch", region_name="us-east-1")  # Route53 metrics are in us-east-1
ssm = session.client("ssm", region_name=CLUSTER_REGION) if COOLDOWN_SSM_PARAMETER else None

# HTTP status codes that indicate transient failures and should trigger retry
RETRYABLE_STATUS_CODES = frozenset([429, 500, 502, 503, 504])

# Track last failover time for cooldown.
# When COOLDOWN_SSM_PARAMETER is configured, the timestamp is persisted to
# SSM Parameter Store so the cooldown survives Lambda cold starts, scaling
# events, and redeployments.  The in-memory variable serves as a fast-path
# cache: if the Lambda container is still warm the SSM read is skipped.
# When the SSM parameter is NOT configured, cooldown falls back to the
# in-memory variable (best-effort, resets on cold start).  In either case
# the pre-failover validation and health check FQDN lock remain the primary
# safety gates against repeated failovers.
_last_failover_time = 0


# =============================================================================
# Retry Statistics Tracking
# =============================================================================

@dataclass
class RetryStats:
    """Track retry statistics for observability and debugging."""
    total_attempts: int = 0
    successful_retries: int = 0
    failed_operations: int = 0
    total_delay_seconds: float = 0.0
    errors_by_status: dict = field(default_factory=dict)
    errors_by_type: dict = field(default_factory=dict)


# Global retry stats for the current Lambda invocation
retry_stats = RetryStats()


def _reset_retry_stats():
    """Reset retry statistics for a new invocation."""
    global retry_stats
    retry_stats = RetryStats()


def _get_retry_stats_dict() -> dict:
    """Convert retry stats to a dictionary for logging/response."""
    return {
        "total_attempts": retry_stats.total_attempts,
        "successful_retries": retry_stats.successful_retries,
        "failed_operations": retry_stats.failed_operations,
        "total_delay_seconds": round(retry_stats.total_delay_seconds, 2),
        "errors_by_status": retry_stats.errors_by_status,
        "errors_by_type": retry_stats.errors_by_type,
    }


# =============================================================================
# Retry Logic Implementation
# =============================================================================

def _calculate_delay(attempt: int, base_delay: float, max_delay: float, exponential_base: float = 2.0) -> float:
    """
    Calculate delay with exponential backoff and jitter.

    Args:
        attempt: Current attempt number (0-indexed)
        base_delay: Base delay in seconds
        max_delay: Maximum delay cap in seconds
        exponential_base: Base for exponential calculation (default 2.0)

    Returns:
        Delay in seconds with jitter applied

    Example delays (base=1.0, max=30.0):
        attempt 0: ~1.0s (±0.25s jitter)
        attempt 1: ~2.0s (±0.5s jitter)
        attempt 2: ~4.0s (±1.0s jitter)
        attempt 3: ~8.0s (±2.0s jitter)
    """
    # Calculate exponential backoff
    delay = min(base_delay * (exponential_base ** attempt), max_delay)

    # Add jitter (±25%) to prevent thundering herd problem
    # This is important when multiple Lambdas might retry simultaneously
    jitter = delay * 0.25 * (2 * random.random() - 1)

    return max(0.1, delay + jitter)


def retry_with_backoff(
    max_retries: int = MAX_RETRIES,
    base_delay: float = BASE_DELAY_SECONDS,
    max_delay: float = MAX_DELAY_SECONDS,
    operation_name: str = "operation",
):
    """
    Decorator that retries a function with exponential backoff and jitter.

    Retries are triggered for:
    - HTTP 429 (Too Many Requests) - Kubernetes API rate limiting
    - HTTP 500 (Internal Server Error) - Transient server errors
    - HTTP 502 (Bad Gateway) - Load balancer/proxy issues
    - HTTP 503 (Service Unavailable) - API server overloaded
    - HTTP 504 (Gateway Timeout) - Request timeout
    - Connection errors (ConnectionError, ConnectionResetError, TimeoutError, OSError)

    Non-retryable errors (fail immediately):
    - HTTP 400 (Bad Request) - Invalid request
    - HTTP 401 (Unauthorized) - Authentication failed
    - HTTP 403 (Forbidden) - Permission denied
    - HTTP 404 (Not Found) - Resource doesn't exist
    - HTTP 409 (Conflict) - Resource version conflict
    - HTTP 422 (Unprocessable Entity) - Validation error

    Args:
        max_retries: Maximum number of retry attempts (default from MAX_RETRIES env var)
        base_delay: Initial delay in seconds before first retry
        max_delay: Maximum delay cap between retries
        operation_name: Human-readable name for logging

    Example:
        @retry_with_backoff(operation_name="patch_deployment")
        def patch_deployment(apps_v1, name, body):
            apps_v1.patch_namespaced_deployment(name=name, namespace=NS, body=body)
    """
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(*args, **kwargs):
            global retry_stats
            last_exception = None

            for attempt in range(max_retries + 1):
                retry_stats.total_attempts += 1

                try:
                    result = func(*args, **kwargs)

                    # Log successful retry
                    if attempt > 0:
                        retry_stats.successful_retries += 1
                        LOG.info(
                            "[%s] Succeeded after %d retry attempt(s)",
                            operation_name, attempt
                        )

                    return result

                except ApiException as e:
                    last_exception = e
                    status_key = f"http_{e.status}"
                    retry_stats.errors_by_status[status_key] = retry_stats.errors_by_status.get(status_key, 0) + 1

                    # Check if this is a retryable status code
                    if e.status not in RETRYABLE_STATUS_CODES:
                        LOG.error(
                            "[%s] Non-retryable API error (HTTP %s): %s",
                            operation_name, e.status, e.reason
                        )
                        retry_stats.failed_operations += 1
                        raise

                    # Check if we have retries remaining
                    if attempt >= max_retries:
                        LOG.error(
                            "[%s] Max retries (%d) exhausted. Last error (HTTP %s): %s",
                            operation_name, max_retries, e.status, e.reason
                        )
                        retry_stats.failed_operations += 1
                        raise

                    # Calculate and apply delay
                    delay = _calculate_delay(attempt, base_delay, max_delay)
                    retry_stats.total_delay_seconds += delay

                    LOG.warning(
                        "[%s] Retryable API error (HTTP %s): %s. "
                        "Attempt %d/%d, retrying in %.2fs...",
                        operation_name, e.status, e.reason,
                        attempt + 1, max_retries + 1, delay
                    )
                    time.sleep(delay)

                except (ConnectionError, ConnectionResetError, TimeoutError, OSError) as e:
                    last_exception = e
                    error_type = type(e).__name__
                    retry_stats.errors_by_type[error_type] = retry_stats.errors_by_type.get(error_type, 0) + 1

                    # Check if we have retries remaining
                    if attempt >= max_retries:
                        LOG.error(
                            "[%s] Max retries (%d) exhausted. Last connection error: %s",
                            operation_name, max_retries, e
                        )
                        retry_stats.failed_operations += 1
                        raise

                    # Calculate and apply delay
                    delay = _calculate_delay(attempt, base_delay, max_delay)
                    retry_stats.total_delay_seconds += delay

                    LOG.warning(
                        "[%s] Connection error: %s. Attempt %d/%d, retrying in %.2fs...",
                        operation_name, e, attempt + 1, max_retries + 1, delay
                    )
                    time.sleep(delay)

            # Should not reach here, but handle edge case
            if last_exception:
                raise last_exception

        return wrapper
    return decorator


# =============================================================================
# Pre-Failover Validation Functions
# =============================================================================

def _read_last_failover_time() -> float:
    """
    Read the last failover timestamp, preferring SSM when configured.

    Priority:
    1. In-memory cache (fast path for warm containers)
    2. SSM Parameter Store (survives cold starts)
    3. 0 (no previous failover recorded)
    """
    global _last_failover_time

    # Fast path: warm container already has the value
    if _last_failover_time > 0:
        return _last_failover_time

    # Read from SSM if configured
    if COOLDOWN_SSM_PARAMETER and ssm:
        try:
            resp = ssm.get_parameter(Name=COOLDOWN_SSM_PARAMETER)
            stored = float(resp["Parameter"]["Value"])
            _last_failover_time = stored
            LOG.debug("Read last failover time from SSM: %s", stored)
            return stored
        except ssm.exceptions.ParameterNotFound:
            LOG.debug("SSM parameter %s not found; no previous failover recorded", COOLDOWN_SSM_PARAMETER)
        except Exception as e:
            LOG.warning("Failed to read cooldown from SSM (%s): %s", COOLDOWN_SSM_PARAMETER, e)

    return 0


def _write_last_failover_time(ts: float):
    """
    Persist the failover timestamp to the in-memory cache and SSM.
    """
    global _last_failover_time
    _last_failover_time = ts

    if COOLDOWN_SSM_PARAMETER and ssm:
        try:
            ssm.put_parameter(
                Name=COOLDOWN_SSM_PARAMETER,
                Value=str(ts),
                Type="String",
                Overwrite=True,
            )
            LOG.info("Persisted last failover time to SSM: %s", ts)
        except Exception as e:
            # Best-effort: failing to persist doesn't block the failover
            LOG.warning("Failed to persist cooldown to SSM (%s): %s", COOLDOWN_SSM_PARAMETER, e)


def _check_cooldown_period() -> bool:
    """
    Check if we're still within the cooldown period from a previous failover.

    Returns:
        True if cooldown has passed (OK to proceed), False if still in cooldown
    """
    if FAILOVER_COOLDOWN_SECONDS <= 0:
        return True

    last_failover = _read_last_failover_time()
    current_time = time.time()
    time_since_last = current_time - last_failover

    if last_failover > 0 and time_since_last < FAILOVER_COOLDOWN_SECONDS:
        LOG.warning(
            "Failover cooldown active: %ds since last failover, cooldown is %ds. Skipping.",
            int(time_since_last), FAILOVER_COOLDOWN_SECONDS
        )
        return False

    return True


def _get_consecutive_failure_seconds(health_check_id: str) -> int:
    """
    Query CloudWatch for consecutive Route53 health check failure duration.

    Route53 health check metrics are always in us-east-1 region.

    Args:
        health_check_id: The Route53 health check ID

    Returns:
        Number of consecutive seconds the health check has been failing
    """
    from datetime import datetime, timedelta, timezone

    try:
        # Use a lookback window that's longer than the required failure duration
        lookback_seconds = max(PRE_FAILOVER_FAILURE_SECONDS * 2, 300)
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(seconds=lookback_seconds)

        response = cloudwatch.get_metric_statistics(
            Namespace="AWS/Route53",
            MetricName="HealthCheckStatus",
            Dimensions=[
                {"Name": "HealthCheckId", "Value": health_check_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=60,  # 1 minute granularity
            Statistics=["Minimum"],
        )

        datapoints = response.get("Datapoints", [])
        if not datapoints:
            LOG.warning("No CloudWatch datapoints found for health check %s", health_check_id)
            return 0

        # Sort by timestamp descending (most recent first)
        datapoints.sort(key=lambda x: x["Timestamp"], reverse=True)

        # Calculate consecutive failure duration from most recent datapoint
        most_recent_time = datapoints[0]["Timestamp"]
        failure_start_time = most_recent_time

        for dp in datapoints:
            status = dp.get("Minimum", 1)
            if status == 1:  # Healthy - stop counting
                break
            failure_start_time = dp["Timestamp"]

        # Check if most recent datapoint is a failure
        if datapoints[0].get("Minimum", 1) == 1:  # Most recent is healthy
            LOG.info(
                "Health check %s: most recent check is healthy",
                health_check_id
            )
            return 0

        # Calculate consecutive failure seconds
        consecutive_failure_seconds = int((most_recent_time - failure_start_time).total_seconds())

        LOG.info(
            "Health check %s: failing for %d consecutive seconds",
            health_check_id, consecutive_failure_seconds
        )
        return consecutive_failure_seconds

    except Exception as e:
        LOG.warning("Error querying CloudWatch for health check metrics: %s", e)
        return 0


def _health_check_healthy(health_check_id: str) -> bool:
    """
    Check if a Route53 health check is healthy.

    Note: This function does not use retry logic because Route53 API is highly
    reliable and health check status is critical for failover decisions.
    """
    try:
        resp = route53.get_health_check_status(HealthCheckId=health_check_id)
        observations = resp.get("HealthCheckObservations", [])
        healthy = any(
            obs.get("StatusReport", {}).get("Status") == "Success"
            for obs in observations
        )
        LOG.info(
            "Health check %s status: %s",
            health_check_id,
            "healthy" if healthy else "unhealthy",
        )
        return healthy
    except route53.exceptions.InvalidInput as exc:
        if "always healthy" in str(exc).lower():
            LOG.warning(
                "Health check %s is disabled (always healthy); treating as unhealthy for failover",
                health_check_id,
            )
            return False
        raise


def _validate_primary_unhealthy() -> bool:
    """
    Comprehensive pre-failover validation for primary health.

    This function ALWAYS performs pre-failover validation to prevent the Lambda
    from scaling the secondary operator when the primary is healthy (e.g., during failback).

    Validation steps:
    1. Queries Route53 for current health status
    2. Queries CloudWatch for consecutive failure duration
    3. Verifies failures have persisted for the required duration

    Returns:
        True if primary is confirmed unhealthy (proceed with failover)
        False if primary appears healthy (skip failover)
    """
    LOG.info(
        "Pre-failover validation (failure_seconds=%d, cooldown=%ds)",
        PRE_FAILOVER_FAILURE_SECONDS, FAILOVER_COOLDOWN_SECONDS
    )

    # Step 1: Check current health status via Route53
    if _health_check_healthy(PRIMARY_HEALTH_CHECK_ID):
        LOG.info("Primary health check is currently healthy; may be recovering. Skipping failover.")
        return False

    # Step 2: Query CloudWatch for consecutive failure duration
    consecutive_failure_seconds = _get_consecutive_failure_seconds(PRIMARY_HEALTH_CHECK_ID)

    if consecutive_failure_seconds < PRE_FAILOVER_FAILURE_SECONDS:
        LOG.info(
            "Primary has been failing for %ds (need %ds); waiting for more confirmation",
            consecutive_failure_seconds, PRE_FAILOVER_FAILURE_SECONDS
        )
        return False

    # Primary is confirmed unhealthy
    LOG.info(
        "Primary confirmed unhealthy: failing for %ds >= %ds required. Proceeding with failover.",
        consecutive_failure_seconds, PRE_FAILOVER_FAILURE_SECONDS
    )
    return True


def _lock_primary_health_check():
    """
    Lock the primary Route53 health check to permanent failure by pointing its
    FQDN to an unresolvable host (failover-locked.invalid).

    This prevents automatic DNS failback to the primary even after it recovers.
    Route53 will see NXDOMAIN for every health check probe, keeping traffic on
    the secondary.

    To fail back manually, restore the original FQDN:
        aws route53 update-health-check \\
            --health-check-id <ID> \\
            --fully-qualified-domain-name <original-primary-fqdn>
    """
    try:
        route53.update_health_check(
            HealthCheckId=PRIMARY_HEALTH_CHECK_ID,
            FullyQualifiedDomainName=FAILOVER_LOCK_FQDN,
            Inverted=False,
        )
        LOG.info(
            "Locked primary health check %s to FQDN '%s' to prevent automatic failback. "
            "To fail back, restore FQDN to '%s'.",
            PRIMARY_HEALTH_CHECK_ID,
            FAILOVER_LOCK_FQDN,
            PRIMARY_HEALTH_CHECK_FQDN,
        )
    except Exception:
        # Best-effort - failover still succeeds even if locking fails.
        LOG.warning(
            "Failed to lock primary health check %s; automatic failback may occur",
            PRIMARY_HEALTH_CHECK_ID,
            exc_info=True,
        )


# =============================================================================
# Kubernetes Client Functions
# =============================================================================

def _get_bearer_token(cluster_name: str, region: str) -> str:
    """
    Generate an EKS authentication token using STS presigned URL.

    This creates a short-lived token (60 seconds) for Kubernetes API authentication.
    """
    sess = botocore.session.Session()
    credentials = sess.get_credentials()
    service_model = sess.get_service_model('sts')

    signer = RequestSigner(
        service_id=service_model.service_id,
        region_name=region,
        signing_name="sts",
        signature_version="v4",
        credentials=credentials,
        event_emitter=sess._events,
    )

    params = {
        "method": "GET",
        "url": f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        "body": "",
        "headers": {"x-k8s-aws-id": cluster_name},
        "context": {},
    }

    presigned_url = signer.generate_presigned_url(
        params,
        region_name=region,
        expires_in=60,
        operation_name="",
    )

    token = "k8s-aws-v1." + base64.urlsafe_b64encode(
        presigned_url.encode("utf-8")
    ).decode("utf-8").rstrip("=")
    LOG.debug("Generated EKS auth token")
    return token


@retry_with_backoff(operation_name="build_kube_client")
def _build_kube_client():
    """
    Build Kubernetes API client with EKS authentication.

    This function is decorated with retry logic because:
    - eks.describe_cluster() can fail with throttling or transient errors
    - Network issues between Lambda and EKS endpoint can cause connection errors
    """
    cluster = eks.describe_cluster(name=CLUSTER_NAME)["cluster"]
    endpoint = cluster["endpoint"]
    ca_data = cluster["certificateAuthority"]["data"]

    with tempfile.NamedTemporaryFile(delete=False, mode="wb", suffix=".crt") as ca_file:
        ca_file.write(base64.b64decode(ca_data))
        ca_path = ca_file.name

    token = _get_bearer_token(CLUSTER_NAME, CLUSTER_REGION)

    configuration = k8s_client.Configuration()
    configuration.host = endpoint
    configuration.api_key = {"authorization": f"Bearer {token}"}
    configuration.ssl_ca_cert = ca_path
    configuration.verify_ssl = True

    api_client = k8s_client.ApiClient(configuration)
    LOG.info("Configured Kubernetes client for cluster %s", CLUSTER_NAME)

    return api_client


@retry_with_backoff(operation_name="get_operator_replicas")
def _get_current_operator_replicas(apps_v1) -> int:
    """
    Get current humio-operator deployment replica count.

    Retryable errors: 429, 500, 502, 503, 504, connection errors
    Non-retryable: 404 (deployment not found) - raises RuntimeError
    """
    try:
        deployment = apps_v1.read_namespaced_deployment(
            name="humio-operator",
            namespace=NAMESPACE
        )
        replicas = deployment.spec.replicas or 0
        LOG.info("Current humio-operator replicas: %s", replicas)
        return replicas
    except ApiException as e:
        if e.status == 404:
            LOG.error("humio-operator deployment not found in namespace %s", NAMESPACE)
            raise RuntimeError(f"Deployment humio-operator not found in namespace {NAMESPACE}")
        raise


@retry_with_backoff(operation_name="patch_operator_replicas")
def _patch_operator_replicas(apps_v1, target_replicas: int) -> bool:
    """
    Patch humio-operator deployment to target replica count.

    This is the most critical operation - it triggers the DR failover.
    Retryable errors: 429, 500, 502, 503, 504, connection errors
    """
    patch_body = {"spec": {"replicas": target_replicas}}

    LOG.info("Patching humio-operator deployment to %s replica(s)", target_replicas)

    apps_v1.patch_namespaced_deployment(
        name="humio-operator",
        namespace=NAMESPACE,
        body=patch_body
    )
    LOG.info("Successfully patched humio-operator replicas to %s", target_replicas)
    return True


@retry_with_backoff(operation_name="update_kafka_reset_timestamp")
def _update_kafka_reset_timestamp(custom_objects_api, namespace: str, humiocluster_name: str) -> bool:
    """
    Update ALLOW_KAFKA_RESET_UNTIL_TIMESTAMP_MS in HumioCluster to current time + 2 hours.
    
    This ensures the secondary cluster can start successfully during DR failover by setting
    the Kafka reset timestamp to be within the required 6-hour window from current time.
    LogScale requires this timestamp to be no more than 6 hours in the future.
    
    Args:
        custom_objects_api: Kubernetes custom objects API client
        namespace: Kubernetes namespace containing the HumioCluster
        humiocluster_name: Name of the HumioCluster custom resource
    
    Returns:
        True if update succeeded, False if HumioCluster not found
    """
    if not humiocluster_name:
        LOG.info("HUMIOCLUSTER_NAME not set; skipping Kafka reset timestamp update")
        return True
    
    # Calculate timestamp: current time + 2 hours (in milliseconds)
    future_timestamp_ms = int((time.time() + 7200) * 1000)
    
    try:
        # Read current HumioCluster
        humiocluster = custom_objects_api.get_namespaced_custom_object(
            group="core.humio.com",
            version="v1alpha1", 
            namespace=namespace,
            plural="humioclusters",
            name=humiocluster_name
        )
        
        LOG.info("Found HumioCluster '%s' in namespace '%s'", humiocluster_name, namespace)
        
        # Prepare patch to update environment variables
        common_env_vars = humiocluster.get("spec", {}).get("commonEnvironmentVariables", [])
        
        # Find existing ALLOW_KAFKA_RESET_UNTIL_TIMESTAMP_MS or create new one
        kafka_reset_var = None
        for i, var in enumerate(common_env_vars):
            if var.get("name") == "ALLOW_KAFKA_RESET_UNTIL_TIMESTAMP_MS":
                kafka_reset_var = var
                kafka_reset_var["value"] = str(future_timestamp_ms)
                break
        
        if kafka_reset_var is None:
            # Add new environment variable
            common_env_vars.append({
                "name": "ALLOW_KAFKA_RESET_UNTIL_TIMESTAMP_MS",
                "value": str(future_timestamp_ms)
            })
        
        # Patch the HumioCluster
        patch_body = {
            "spec": {
                "commonEnvironmentVariables": common_env_vars
            }
        }
        
        custom_objects_api.patch_namespaced_custom_object(
            group="core.humio.com",
            version="v1alpha1",
            namespace=namespace,
            plural="humioclusters", 
            name=humiocluster_name,
            body=patch_body
        )
        
        LOG.info(
            "Updated ALLOW_KAFKA_RESET_UNTIL_TIMESTAMP_MS to %s (+2h from now) in HumioCluster '%s'",
            future_timestamp_ms, humiocluster_name
        )
        return True
        
    except ApiException as e:
        if e.status == 404:
            LOG.warning("HumioCluster '%s' not found in namespace '%s'", humiocluster_name, namespace)
            return False
        # Re-raise for retry logic to handle
        raise


@retry_with_backoff(operation_name="cleanup_tls_secret")
def _cleanup_stale_tls_secret(core_v1, namespace: str, humiocluster_name: str) -> bool:
    """
    Delete stale TLS secret before scaling operator to prevent CA certificate mismatch.

    In DR standby deployments, when the operator is scaled to 0 and later scaled back up,
    the CA keypair may be regenerated but the cluster TLS secret ({humiocluster_name})
    retains the old CA. This causes TLS verification failures when the operator tries
    to communicate with LogScale pods.

    Deleting the TLS secret allows cert-manager to recreate it with the correct CA
    from the current CA keypair.

    See: humio-operator/internal/helpers/clusterinterface.go line 213

    Retryable errors: 429, 500, 502, 503, 504, connection errors
    Non-retryable: 404 is handled gracefully (secret doesn't exist)
    """
    if not humiocluster_name:
        LOG.info("HUMIOCLUSTER_NAME not set; skipping TLS secret cleanup")
        return True

    try:
        core_v1.read_namespaced_secret(name=humiocluster_name, namespace=namespace)
        LOG.info("Found TLS secret '%s' in namespace '%s'", humiocluster_name, namespace)

        core_v1.delete_namespaced_secret(name=humiocluster_name, namespace=namespace)
        LOG.info("Deleted stale TLS secret '%s' to prevent CA mismatch", humiocluster_name)
        LOG.info("  cert-manager will recreate the secret with the current CA")
        return True

    except ApiException as e:
        if e.status == 404:
            LOG.info("TLS secret '%s' not found; nothing to cleanup", humiocluster_name)
            return True
        # Re-raise for retry logic to handle
        raise


# =============================================================================
# Main Alarm Handler
# =============================================================================

def _handle_alarm() -> dict:
    """
    Main alarm handling logic with retry-enabled Kubernetes operations.

    Flow:
    0. Check cooldown period
    1. Validate primary health check is unhealthy (with pre-failover validation)
    2. Optionally validate secondary health check is healthy
    3. Build Kubernetes client (with retry)
    4. Get current operator replicas (with retry)
    5. Update Kafka reset timestamp in HumioCluster (with retry)
    6. Clean up stale TLS secret (with retry)
    7. Patch operator replicas (with retry)
    8. Lock primary health check to prevent automatic DNS failback

    Returns:
        dict with action taken and retry statistics
    """
    global _last_failover_time
    _reset_retry_stats()

    # Step 0: Check cooldown period
    if not _check_cooldown_period():
        return {
            "action": "skipped",
            "reason": "cooldown_active",
            "retry_stats": _get_retry_stats_dict()
        }

    # Step 1: Validate primary health check with pre-failover validation
    if not _validate_primary_unhealthy():
        LOG.info("Primary health check recovered or insufficient failures; skipping operator scale-up.")
        return {
            "action": "skipped",
            "reason": "primary_healthy",
            "retry_stats": _get_retry_stats_dict()
        }

    # Step 2: Optionally validate secondary health check
    if SKIP_SECONDARY_HEALTH_CHECK:
        LOG.info("Skipping secondary health check gating due to configuration.")
    elif SECONDARY_HEALTH_CHECK_ID:
        secondary_ok = _health_check_healthy(SECONDARY_HEALTH_CHECK_ID)
        if not secondary_ok:
            LOG.warning("Secondary health check not healthy; not scaling operator.")
            return {
                "action": "skipped",
                "reason": "secondary_unhealthy",
                "retry_stats": _get_retry_stats_dict()
            }
    else:
        LOG.info("No secondary health check configured; proceeding without gate.")

    # Step 3: Build Kubernetes client (with retry)
    api_client = _build_kube_client()
    apps_v1 = k8s_client.AppsV1Api(api_client)
    core_v1 = k8s_client.CoreV1Api(api_client)
    custom_objects_v1 = k8s_client.CustomObjectsApi(api_client)

    # Step 4: Get current replicas (with retry)
    current = _get_current_operator_replicas(apps_v1)

    if current >= TARGET_OPERATOR_REPLICAS:
        LOG.info("humio-operator replicas already >= target (%s); no-op.", current)
        return {
            "action": "noop",
            "current": current,
            "target": TARGET_OPERATOR_REPLICAS,
            "retry_stats": _get_retry_stats_dict()
        }

    # Step 5: Update Kafka reset timestamp in HumioCluster (with retry)
    _update_kafka_reset_timestamp(custom_objects_v1, NAMESPACE, HUMIOCLUSTER_NAME)

    # Step 6: Clean up stale TLS secret (with retry)
    _cleanup_stale_tls_secret(core_v1, NAMESPACE, HUMIOCLUSTER_NAME)

    # Step 7: Patch operator replicas (with retry)
    _patch_operator_replicas(apps_v1, TARGET_OPERATOR_REPLICAS)

    # Step 8: Lock primary health check to prevent automatic DNS failback
    _lock_primary_health_check()

    # Update last failover time for cooldown tracking
    _write_last_failover_time(time.time())

    return {
        "action": "patched",
        "from": current,
        "to": TARGET_OPERATOR_REPLICAS,
        "retry_stats": _get_retry_stats_dict()
    }


# =============================================================================
# Lambda Entry Point
# =============================================================================

def lambda_handler(event, _context):
    """
    Lambda entry point for DR failover handling.

    Triggered by SNS notification from CloudWatch alarm when primary
    Route53 health check transitions to ALARM state.
    """
    LOG.debug("Received event: %s", json.dumps(event))
    LOG.info(
        "DR Failover Lambda starting. Retry config: max_retries=%d, base_delay=%.1fs, max_delay=%.1fs",
        MAX_RETRIES, BASE_DELAY_SECONDS, MAX_DELAY_SECONDS
    )

    records = event.get("Records", [])
    if not records:
        LOG.info("No records to process.")
        return {"status": "ignored"}

    for record in records:
        if record.get("EventSource") != "aws:sns":
            LOG.info("Ignoring non-SNS record.")
            continue

        message_str = record.get("Sns", {}).get("Message", "{}")
        try:
            message = json.loads(message_str)
        except json.JSONDecodeError:
            LOG.warning("SNS message is not JSON; processing anyway.")
            message = {"raw": message_str}

        if message.get("NewStateValue") != "ALARM":
            LOG.info("SNS message not in ALARM state; skipping.")
            continue

        dims = message.get("Trigger", {}).get("Dimensions", [])
        hc_from_alarm = next(
            (d.get("value") for d in dims if d.get("name") == "HealthCheckId"), None
        )

        if hc_from_alarm and hc_from_alarm != PRIMARY_HEALTH_CHECK_ID:
            LOG.info(
                "Alarm HealthCheckId %s does not match primary %s; skipping.",
                hc_from_alarm,
                PRIMARY_HEALTH_CHECK_ID,
            )
            continue

        try:
            result = _handle_alarm()
            LOG.info("Failover handler result: %s", json.dumps(result))
        except Exception as exc:
            LOG.exception("Failed to process failover alarm: %s", exc)
            # Log retry stats even on failure for debugging
            LOG.error("Retry stats at failure: %s", json.dumps(_get_retry_stats_dict()))
            raise

    return {"status": "processed", "retry_stats": _get_retry_stats_dict()}
