# LogScale DR Failover Simulation HOWTO (AWS)

This HOWTO explains how to simulate DR scenarios using the global DNS + Lambda failover scaler implementation, without deleting or shutting down any AWS resources:

1. Primary LogScale failure (`primary-down`) — scales primary humio-operator to 0 and deletes pods
2. Primary region becomes unreachable (`region-down`) — locks Route53 health check FQDN
3. Primary AZ capacity becomes unreachable (`az-down`) — same as region-down
4. Primary EKS cluster becomes unreachable (`eks-down`) — same as region-down
5. Transient outage anti-flap test (`transient-outage`) — brief health check FQDN lock
6. LogScale process crash (`logscale-crash`) — kill process or block health endpoint
7. DNS failover check (`dns-failover-check`) — show DNS resolution and endpoint health

All scenarios trigger the same event-driven failover chain (Route53 health check → CloudWatch alarm → SNS → Lambda) which:
1. Scales the `humio-operator` deployment replicas from `0 → 1`
2. The operator reconciles and scales the `HumioCluster.spec.nodeCount` from `0 → 1`
3. Locks the primary health check FQDN to `failover-locked.invalid` to prevent automatic DNS failback
4. On failback, the health check FQDN must be restored to the original primary FQDN and the secondary cluster reset

---

## 1. Prerequisites

- Primary and secondary clusters deployed with:
  - `dr = "active"` on primary workspace.
  - `dr = "standby"` on secondary workspace.
  - `manage_global_dns = true` and `global_logscale_hostname` set.
  - DR failover Lambda enabled on secondary:
    - `dr_failover_lambda_enabled = true`
    - `dr_failover_lambda_target_node_count = 1`
- Route53 global failover configured via Terraform module `modules/aws/global-dns`:
  - Primary health check: `aws_route53_health_check.logscale_global_primary` (HTTPS `/api/v1/status`)
  - Secondary health check: `aws_route53_health_check.logscale_global_secondary` (TCP port 443 - ALB infrastructure check)
- Script present and executable:
  ```bash
  chmod +x test/simulate-aws-dr-failover.sh
  ```
- Tools installed:
  - `aws` CLI (configured with the right account/region/profile)
  - `kubectl`
  - `dig` (optional, for DNS checks)
  - `jq` (optional, for parsing JSON output in verification commands)
- Do **not** modify or shut down the primary cluster during `region-down`/`az-down`/`eks-down` simulations; traffic cutover is driven solely by Route53 DNS failover and the Lambda scaler.

---

## 2. Auto-Discovery (New Feature)

The script now supports **automatic cluster pair discovery** from tfvars files. It scans `*.tfvars` in the repository root for `dr = "active"` (primary) and `dr = "standby"` (secondary), then extracts all necessary configuration:

- `hostname` + `zone_name` → constructs FQDNs
- `cluster_name` → auto-detects kubeconfig contexts
- `aws_region`, `aws_profile` → configures AWS CLI
- `global_logscale_hostname` → constructs global DR FQDN
- `eks_s3_bucket_name` → used for failback cleanup

### Simplest invocation (uses auto-discovery):
```bash
./test/simulate-aws-dr-failover.sh status
./test/simulate-aws-dr-failover.sh primary-down
./test/simulate-aws-dr-failover.sh failback
```

### Specify by EKS cluster name (recommended):
```bash
./test/simulate-aws-dr-failover.sh --cluster dr-primary dr-secondary primary-down
./test/simulate-aws-dr-failover.sh --cluster dr-primary dr-secondary status
```

The `--cluster` option looks up the matching tfvars files by scanning for `cluster_name = "<name>"` in `*.tfvars`, avoiding ambiguity when multiple files have the same `dr` mode (e.g., `example.tfvars` and `primary-us-west-2.tfvars` both with `dr = "active"`).

### Explicit tfvars files:
```bash
./test/simulate-aws-dr-failover.sh --primary primary-us-west-2.tfvars --secondary secondary-us-east-2.tfvars region-down
```

### With debug output:
```bash
./test/simulate-aws-dr-failover.sh --debug primary-down
```

### Override specific values:
```bash
PRIMARY_KUBE_CONTEXT=my-context ./test/simulate-aws-dr-failover.sh status
```

### Kubeconfig Context Auto-Detection

The script automatically detects kubeconfig contexts by checking both:
- Short names: `dr-primary`, `dr-secondary`
- ARN format: `arn:aws:eks:us-west-2:471112840547:cluster/dr-primary`

If your kubeconfig uses ARN-format context names, the script will find them automatically.

---

## 3. Baseline checks (before simulations)

Run on the **secondary** (standby) cluster:

```bash
# Get the HumioCluster name
export HUMIOCLUSTER_NAME=$(kubectl get humiocluster -n logging --context dr-secondary -o jsonpath='{.items[0].metadata.name}')
echo "HumioCluster: ${HUMIOCLUSTER_NAME}"

# humio-operator should be scaled to 0 replicas on standby
kubectl get deployment humio-operator -n logging --context dr-secondary

# HumioCluster nodeCount should be 1 on standby (but no pods running because operator is at 0)
kubectl get humiocluster ${HUMIOCLUSTER_NAME} -n logging --context dr-secondary \
  -o jsonpath='{.spec.nodeCount}'; echo

# Lambda access entry present (optional sanity check)
aws eks list-access-entries --region us-east-2 --cluster-name dr-secondary --profile aws-ref-arch-mi --output text | grep failover

# CloudWatch alarm for Lambda should exist
aws cloudwatch describe-alarms --alarm-names "dr-secondary-dr-failover-primary-unhealthy" --profile aws-ref-arch-mi --region us-east-1

# CloudWatch log group for Lambda should exist
aws logs describe-log-groups --profile "aws-ref-arch-mi" --region us-east-2 --log-group-name-prefix /aws/lambda/dr-secondary-dr-failover-handler
```

You should see:
- humio-operator replicas: 0/0
- HumioCluster nodeCount: 1 (declared in spec, but no pods running because operator is at 0 replicas)
- No Humio pods running
- CloudWatch alarm exists in us-east-1 (Route53 metrics are global)
- Lambda log group exists in us-east-2 (secondary cluster region)

Or simply run the status command:
```bash
./test/simulate-aws-dr-failover.sh status
```

---

## 4. Scenario 1 – Primary LogScale failure (`primary-down`)

This simulates a real primary cluster failure by:
1. Scaling the primary humio-operator to 0 replicas
2. **Deleting LogScale pods** (force) to trigger ALB health check failure
3. Tracking the full failover pipeline including snapshot recovery

```bash
./test/simulate-aws-dr-failover.sh primary-down
```

What happens:
1. Script scales primary humio-operator to 0 replicas.
2. Script **deletes LogScale pods** (force, grace-period=0) — this is critical because scaling operator to 0 alone does NOT delete managed pods.
3. ALB health checks fail (no pods to serve traffic).
4. Route53 health check fails (3 failures x 10s interval = ~30s).
5. CloudWatch alarm triggers after ~60s evaluation period.
6. SNS topic receives alarm notification and triggers Lambda function (in us-east-2).
7. Lambda validates primary is unhealthy, then scales secondary `humio-operator` replicas `0 → 1`.
8. Lambda locks the primary health check FQDN to `failover-locked.invalid` to prevent automatic DNS failback.
9. The humio-operator reconciles and ensures `HumioCluster.spec.nodeCount: 1` is satisfied.
10. LogScale digest pod starts and performs DR recovery (reads global snapshot from primary S3 bucket).
11. Route53 failover points global DR FQDN to the secondary ALB.

The script tracks and displays:
- Primary endpoint becoming unhealthy
- CloudWatch alarm firing
- Secondary humio-operator scaling
- LogScale pod readiness
- **Snapshot fetch progress** (8-stage DataSnapshotLoader tracking via `kubectl logs | grep DataSnapshotLoader`)
- Secondary endpoint becoming healthy
- Full timing summary with latency breakdowns

**Note:** After this scenario, run `failback` to restore both clusters. The failback process automatically scales the primary humio-operator back to 1.

---

## 5. Scenario 2 – Region becomes unreachable (`region-down`)

This simulates a full **primary region** outage. Instead of actually affecting primary workloads, the primary Route53 health check FQDN is swapped to `failover-locked.invalid` (an unresolvable host), causing the health check to always fail and triggering the same failover chain.

```bash
./test/simulate-aws-dr-failover.sh region-down
```

What happens:
- Script locks the primary health check FQDN to `failover-locked.invalid` (always fails with NXDOMAIN).
- After ~30-90 seconds:
  - Primary health check metrics show unhealthy status (value < 1.0).
  - CloudWatch alarm (in us-east-1) detects unhealthy status and transitions to ALARM state.
  - SNS topic receives alarm notification and triggers Lambda function (in us-east-2).
  - Lambda scales `humio-operator` deployment replicas `0 → 1`.
  - The humio-operator reconciles and ensures `HumioCluster.spec.nodeCount: 1` is satisfied.
  - LogScale digest pod starts and performs DR recovery (reads global snapshot from primary S3 bucket).
  - Route53 failover points global DR FQDN to the secondary ALB.
  - Secondary health check (TCP port 443) remains healthy since it validates ALB infrastructure, not application.
  - Primary workloads remain untouched; we are only simulating via DNS.

---

## 6. Scenario 3 – AZ becomes unreachable (`az-down`)

This simulates a **single AZ** outage affecting the primary cluster. Behavior identical to `region-down`.

```bash
./test/simulate-aws-dr-failover.sh az-down
```

---

## 7. Scenario 4 – EKS becomes unreachable (`eks-down`)

This simulates the **primary EKS cluster/control plane** becoming unreachable. Behavior identical to `region-down`.

```bash
./test/simulate-aws-dr-failover.sh eks-down
```

---

## 8. Scenario 5 – Transient outage anti-flap test (`transient-outage`)

This tests the anti-flap gating mechanism (`PRE_FAILOVER_FAILURE_SECONDS`) to verify that a brief outage does NOT trigger failover.

```bash
./test/simulate-aws-dr-failover.sh transient-outage
```

What happens:
1. Verifies secondary humio-operator is at 0 replicas
2. Locks primary health check FQDN to `failover-locked.invalid` for `TRANSIENT_OUTAGE_DURATION_SECONDS` (default: 30s)
3. Restores the health check FQDN to the original primary FQDN
4. Observes secondary humio-operator for `TRANSIENT_OBSERVATION_SECONDS` (default: 180s)
5. Reports PASS if secondary did NOT scale up, FAIL if it did

**Important:** This test requires `PRE_FAILOVER_FAILURE_SECONDS > 0` on the Lambda configuration. If set to 0 (test mode), the transient outage WILL trigger failover.

Configure via environment variables:
```bash
TRANSIENT_OUTAGE_DURATION_SECONDS=30 TRANSIENT_OBSERVATION_SECONDS=180 \
  ./test/simulate-aws-dr-failover.sh transient-outage
```

---

## 9. Scenario 6 – LogScale crash (`logscale-crash`)

This simulates an application-level crash on the primary cluster. Two crash modes are available:

### kill-process mode (default)
Sends SIGKILL to PID 1 inside the LogScale container:
```bash
CRASH_MODE=kill-process ./test/simulate-aws-dr-failover.sh logscale-crash
```

The pod will enter CrashLoopBackOff. If the operator is running, it will attempt to restart the pod. The ALB health checks may fail during the crash loop, potentially triggering failover.

### block-health mode
Blocks the health check port (8080) via iptables inside the container:
```bash
CRASH_MODE=block-health ./test/simulate-aws-dr-failover.sh logscale-crash
```

This makes the ALB think the pod is unhealthy while the process is still running. Route53 health checks will fail, triggering the full failover chain.

**Note:** The `block-health` mode requires cleanup during failback (iptables rule removal). The failback scenario handles this automatically.

---

## 10. Scenario 7 – DNS failover check (`dns-failover-check`)

Non-destructive check showing current DNS resolution and endpoint health for all FQDNs.

```bash
./test/simulate-aws-dr-failover.sh dns-failover-check
```

Shows:
- Primary FQDN DNS resolution and HTTP status
- Secondary FQDN DNS resolution and HTTP status
- Global DR FQDN DNS resolution and HTTP status
- Which cluster the global FQDN currently routes to (PRIMARY or SECONDARY)
- Route53 health check status, FQDN, and inversion flag

---

## 11. Failback – Restore primary and return secondary to standby

After any simulation scenario, run the `failback` command to restore the primary cluster and fully reset the secondary back to standby mode. The failback is a single automated script that handles all cleanup in the correct order.

### When to run failback

Run failback after **any** scenario that triggered failover:
- `primary-down` — always requires failback
- `region-down`, `az-down`, `eks-down` — always requires failback
- `logscale-crash` — requires failback if failover was triggered
- `transient-outage` — only requires failback if the anti-flap test **failed** (i.e., secondary scaled up)

### How to run

```bash
./test/simulate-aws-dr-failover.sh failback
```

Or with explicit cluster specification:
```bash
./test/simulate-aws-dr-failover.sh --cluster dr-primary dr-secondary failback
```

With debug output (recommended for troubleshooting):
```bash
./test/simulate-aws-dr-failover.sh --debug failback
```

> **Note:** No manual steps are required before running failback. The script handles everything including restoring the primary humio-operator if it was scaled to 0.

### What the failback process does

The script executes four phases automatically. Each phase completes before the next begins.

#### Phase 1: Test artifact cleanup (Step 0)

| Step | Action | Purpose |
|------|--------|---------|
| 0 | Clean up test artifacts | Remove iptables rules from `logscale-crash` block-health mode. Restart primary pod if unhealthy (CrashLoopBackOff). |

#### Phase 2: Alarm management (Step 1)

| Step | Action | Purpose |
|------|--------|---------|
| 1 | Disable CloudWatch alarm actions | Prevent the Lambda from re-triggering during restoration. The alarm remains visible but cannot invoke SNS. |

#### Phase 3: Primary cluster restoration (Steps 2–4)

| Step | Action | Purpose |
|------|--------|---------|
| 2 | Restore primary Route53 health check FQDN | Swap FQDN from `failover-locked.invalid` back to the original primary FQDN (e.g., `<hostname>.<zone_name>`). Also clears legacy inversion flag if present. |
| 3 | Scale PRIMARY humio-operator to 1 | Restore the primary operator so it can reconcile LogScale pods. Skipped if already running. |
| 4 | Wait for PRIMARY endpoint healthy | Polls `https://<primary-fqdn>/api/v1/status` until HTTP 200. Continues to secondary cleanup even if this times out. |

#### Phase 4: Secondary cluster reset (Steps 5–15)

This phase fully resets the secondary cluster to a clean standby state. The order is critical — LogScale must stop before Kafka, and Kafka must be fully removed before the operator recreates it.

| Step | Action | Purpose |
|------|--------|---------|
| 5 | Scale SECONDARY humio-operator to 0 | Stop the operator from managing LogScale pods. |
| 6 | Delete SECONDARY LogScale pods | Remove all LogScale digest/ingest/UI pods. |
| 7 | Wait for LogScale pods to terminate | Ensure clean shutdown before Kafka cleanup. |
| 8 | Scale SECONDARY strimzi-cluster-operator to 0 | Prevent Kafka pod recreation during cleanup. |
| 9 | Delete SECONDARY Kafka pods (force) | Force-remove Strimzi-managed Kafka broker pods. |
| 10 | Wait for Kafka pods to terminate | Ensure Kafka pods are fully deleted. |
| 11 | Delete SECONDARY Kafka PVCs | Remove persistent volume claims to reset Kafka state and cluster ID. |
| 12 | Delete SECONDARY StrimziPodSet | Reset Strimzi's internal state so Kafka starts fresh on next failover. |
| 13 | Scale SECONDARY strimzi-cluster-operator to 1 | Restore Strimzi operator to recreate Kafka with a clean state. Waits 30s for pods to stabilize. |
| 14 | Delete SECONDARY S3 bucket contents | Clear the secondary S3 bucket so the next failover starts with a fresh snapshot recovery. |
| 15 | Re-enable CloudWatch alarm actions | Restore DR failover automation so the next primary failure triggers Lambda. |

### Timing

Failback typically takes 3–8 minutes depending on:
- How long the primary takes to become healthy (Step 4 — up to 5 minutes)
- Secondary S3 bucket size (Step 14 — larger buckets take longer to empty)
- Kafka pod recreation time (Step 13 — typically 30–60 seconds)

The script reports total elapsed time on completion.

### Verify failback completion

After the script completes, run `status` to confirm both clusters are in the expected state:

```bash
./test/simulate-aws-dr-failover.sh status
```

Expected status output:
- **Primary**: humio-operator at 1 replica, LogScale pods Running, endpoint healthy (HTTP 200)
- **Secondary**: humio-operator at 0 replicas, no LogScale pods, Kafka pods recreating
- **Health check**: FQDN pointing to the real primary hostname (NOT `failover-locked.invalid`)
- **CloudWatch alarm**: OK state, actions enabled
- **Global DNS**: Resolving to primary ALB IP addresses

For detailed manual verification:
```bash
# Health check FQDN should be the real primary hostname
aws route53 get-health-check --health-check-id "<HEALTH_CHECK_ID>" \
  --profile aws-ref-arch-mi | jq '.HealthCheck.HealthCheckConfig.FullyQualifiedDomainName'
# Expected: "<primary_hostname>.<zone_name>" (NOT "failover-locked.invalid")

# Secondary humio-operator should be at 0 replicas
kubectl get deployment humio-operator -n logging --context dr-secondary
# Expected: 0/0

# No LogScale pods on secondary
kubectl get pods -n logging --context dr-secondary -l app.kubernetes.io/name=humio
# Expected: No resources found

# Kafka pods recreating on secondary
kubectl get pods -n logging --context dr-secondary -l strimzi.io/cluster
# Expected: Kafka pods in Running or ContainerCreating state

# CloudWatch alarm should return to OK
aws cloudwatch describe-alarms \
  --alarm-names "dr-secondary-dr-failover-primary-unhealthy" \
  --profile aws-ref-arch-mi --region us-east-1 \
  | jq '.MetricAlarms[0].StateValue'
# Expected: "OK"
```

### Troubleshooting failback

| Symptom | Cause | Fix |
|---------|-------|-----|
| Step 6 stuck on "Waiting for DataSnapshotLoader to start" | Log output too large for shell variable, or grep pattern mismatch | Fixed: script now pipes `kubectl logs` directly through `grep -E "DataSnapshotLoader\|updateSnapshotForDisasterRecovery"` to avoid shell `ARG_MAX` limits. Update to latest script. |
| Step 2 hangs or fails with invalid health check ID | Log functions writing to stdout (fixed in `de6461c`) | Update to latest script version |
| Step 4 times out (primary not healthy) | Primary operator or pod not recovering | Check `kubectl get pods -n logging --context dr-primary`. Failback continues with secondary cleanup regardless. |
| Step 14 takes very long | Large secondary S3 bucket | Wait for completion. Use `aws s3 ls s3://<bucket>/ --profile <profile> \| wc -l` to check remaining objects. |
| Alarm stays in ALARM after failback | Health check still recovering | Wait 2–3 minutes for Route53 health check to detect the restored primary. Check with `./test/simulate-aws-dr-failover.sh dns-failover-check`. |
| Secondary pods still running after failback | Operator not fully scaled down | Run `kubectl --context dr-secondary -n logging scale deployment humio-operator --replicas=0` then delete remaining pods manually. |

### Ready for next DR simulation

After failback completes, the secondary cluster is in a clean standby state:
- humio-operator: 0 replicas (waiting for Lambda to scale up on next failover)
- LogScale pods: deleted (will be recreated when operator scales up)
- Kafka: recreated with clean state (ready for new cluster ID)
- S3 bucket: cleared (ready for new snapshots)
- CloudWatch alarm: active and monitoring (ready to trigger Lambda)

You can now re-run any DR simulation scenario.

> **Warning:** Do not run `terraform apply` on the primary workspace while the health check FQDN is locked to `failover-locked.invalid`. Always run failback first to restore the health check, then apply Terraform changes.

---

## 12. Check Cluster Status (`status`)

Use the `status` scenario to quickly check the current state of both clusters without making any changes.

```bash
./test/simulate-aws-dr-failover.sh status
```

The status output includes:

| Section | Information |
|---------|-------------|
| Configuration | tfvars files used for auto-discovery |
| PRIMARY cluster | humio-operator replicas, LogScale pods, endpoint health (HTTP status) |
| SECONDARY cluster | humio-operator replicas, LogScale pods, endpoint health (HTTP status) |
| Route53 Health Check | Health check ID, current status, FQDN, inverted flag |
| CloudWatch Alarm | Alarm name, current state (OK/ALARM/INSUFFICIENT_DATA) |
| Lambda Function | Function name, last modified time |
| DNS Resolution | Current resolution of the global DR FQDN |

---

## 13. Command Reference

| Command | Description |
|---------|-------------|
| `./test/simulate-aws-dr-failover.sh --help` | Show help and all options |
| `./test/simulate-aws-dr-failover.sh status` | Check cluster status |
| `./test/simulate-aws-dr-failover.sh dns-failover-check` | DNS resolution and endpoint health |
| `./test/simulate-aws-dr-failover.sh primary-down` | Simulate primary failure |
| `./test/simulate-aws-dr-failover.sh region-down` | Simulate region outage |
| `./test/simulate-aws-dr-failover.sh az-down` | Simulate AZ outage |
| `./test/simulate-aws-dr-failover.sh eks-down` | Simulate EKS unreachable |
| `./test/simulate-aws-dr-failover.sh transient-outage` | Test anti-flap gating |
| `./test/simulate-aws-dr-failover.sh logscale-crash` | Crash LogScale process |
| `./test/simulate-aws-dr-failover.sh failback` | Restore to normal state |
| `./test/simulate-aws-dr-failover.sh --debug <scenario>` | Run with debug output |
| `./test/simulate-aws-dr-failover.sh --cluster <pri> <sec> <scenario>` | Specify by EKS cluster name |
| `./test/simulate-aws-dr-failover.sh --primary <f> --secondary <f> <scenario>` | Specify tfvars explicitly |
