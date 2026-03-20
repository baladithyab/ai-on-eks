#!/usr/bin/env bash
# =============================================================================
# NVIDIA Dynamo Stack Cleanup
# =============================================================================
#
# Wraps the base Terraform cleanup template (terraform/_LOCAL/cleanup.sh) with
# Dynamo-specific pre-destroy steps and strict _LOCAL preservation logic.
#
# FLOW
#   1.  Delete Dynamo operator CRs (DGD, DGDR, DynamoModel) so the operator
#       doesn't block namespace/CRD teardown during terraform destroy.
#   1b. Unblock stuck namespace deletion: remove stale APIServices, patch
#       stuck ArgoCD finalizers, and force-finalize the dynamo namespace if
#       it is stuck in Terminating.  Also PRE-EMPTIVELY delete aggregated
#       APIServices (metrics-server, etc.) that will lose backing pods when
#       terraform destroys node groups (prevents timing-gap race condition).
#   2.  Delegate to the base cleanup template in terraform/_LOCAL/ for:
#      - kubectl_manifest targeted destroy
#      - full terraform destroy
#      - EBS volume cleanup
#   2b. If Phase 2 fails: re-check for stale APIServices that appeared
#       DURING destroy, force-remove namespace finalizers, patch stuck
#       ArgoCD apps, then retry terraform destroy.
#   3. Gate success/failure on the base template's exit code AND output
#      analysis (Terraform error markers).
#   4. Delete terraform/_LOCAL by default on conclusive success (exit 0 +
#      empty state + no Terraform error markers in output).
#      Use --keep-local to preserve _LOCAL on success for debugging.
#
# CONTRACT
#   - Any non-zero exit from the base template → exit non-zero, preserve
#     _LOCAL, NO success banner.
#   - Terraform error markers in output (even with exit 0) → treated as
#     failure: exit non-zero, preserve _LOCAL, NO success banner.
#   - _LOCAL is deleted by default when conclusive success is confirmed.
#   - --keep-local preserves _LOCAL even on success (debugging escape hatch).
#   - --force/--yes only skips the confirmation prompt.
#
# FLAGS
#   --force | --yes   Skip interactive confirmation
#   --keep-local      Preserve _LOCAL even on success (debugging)
#   -h | --help       Show usage
#
# See: docs/cleanup-guardrails.md
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

readonly TERRAFORM_DIR="terraform/_LOCAL"

# Defaults — may be overridden by tfvars via base template
CLUSTER_NAME="dynamo-on-eks"
REGION="us-west-2"

# Flags
OPT_FORCE=false
OPT_KEEP_LOCAL=false

# Colour (disabled when stdout is not a tty)
if [[ -t 1 ]]; then
    _G='\033[0;32m' _Y='\033[0;33m' _R='\033[0;31m' _N='\033[0m'
else
    _G='' _Y='' _R='' _N=''
fi
info()  { printf '%b[INFO]%b %s\n'  "$_G" "$_N" "$*"; }
warn()  { printf '%b[WARN]%b %s\n'  "$_Y" "$_N" "$*"; }
error() { printf '%b[ERROR]%b %s\n' "$_R" "$_N" "$*" >&2; }

# =============================================================================
# Recovery message — printed when the base cleanup template fails
# =============================================================================
print_recovery() {
    local rc="$1"
    cat >&2 <<EOF

$(error "==============================================================================")
$(error " CLEANUP FAILED  (exit code: ${rc})")
$(error "==============================================================================")

terraform/_LOCAL has been PRESERVED so you can retry or inspect state.

  1. Inspect state:   cd ${SCRIPT_DIR}/${TERRAFORM_DIR} && terraform state list
  2. Show details:    terraform show
  3. Retry:           cd ${SCRIPT_DIR} && ./cleanup.sh
  4. Remove orphans:  cd ${SCRIPT_DIR}/${TERRAFORM_DIR} && terraform state rm <addr>
  5. Manual removal:  rm -rf ${SCRIPT_DIR}/${TERRAFORM_DIR}  # only when verified clean

$(error "==============================================================================")
EOF
}

# Trap: preserve _LOCAL on interrupt
trap 'echo ""; error "INTERRUPTED — terraform/_LOCAL PRESERVED."; exit 130' INT TERM

# =============================================================================
# Argument parsing
# =============================================================================
while (( $# > 0 )); do
    case "$1" in
        --force|--yes)  OPT_FORCE=true;       shift ;;
        --keep-local)   OPT_KEEP_LOCAL=true;   shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: cleanup.sh [OPTIONS]

  --force, --yes     Skip confirmation prompt
  --keep-local       Preserve terraform/_LOCAL even on success (debugging)
  -h, --help         Show this message

By default, terraform/_LOCAL is deleted automatically on conclusive success
(base cleanup exits 0, state is empty, no Terraform error markers in output).
Pass --keep-local to preserve it for debugging.

See: docs/cleanup-guardrails.md
USAGE
            exit 0
            ;;
        *) warn "Unknown option: $1 (ignored)"; shift ;;
    esac
done

# =============================================================================
# Banner + confirmation
# =============================================================================
info "NVIDIA Dynamo Stack Cleanup"
info "  Cluster:       ${CLUSTER_NAME}"
info "  Region:        ${REGION}"
info "  --force/--yes: ${OPT_FORCE}"
info "  --keep-local:  ${OPT_KEEP_LOCAL}"

if [[ "$OPT_FORCE" != "true" ]]; then
    echo ""
    warn "This will DESTROY all NVIDIA Dynamo infrastructure in ${CLUSTER_NAME} / ${REGION}."
    read -rp "Proceed? (yes/no): "
    if [[ ! ${REPLY} =~ ^[Yy][Ee][Ss]$ ]]; then
        info "Cancelled."
        exit 0
    fi
fi

# =============================================================================
# Phase 1 — Delete Dynamo operator custom resources (best-effort)
# =============================================================================
# These are the CRs that users create and the Dynamo operator watches.
# Removing them (with finalizer patches) prevents the operator from blocking
# namespace deletion during terraform destroy.
#
# The Dynamo CRDs themselves and the platform components are managed by
# ArgoCD / Terraform and will be torn down by the base cleanup template.
# =============================================================================
info "=== Phase 1: Dynamo CR pre-cleanup ==="

CLUSTER_ACCESSIBLE=false
if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" 2>/dev/null \
        && kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    CLUSTER_ACCESSIBLE=true
    info "Cluster is accessible"
else
    warn "Cluster not reachable — skipping Dynamo CR cleanup"
fi

if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
    for kind in dynamographdeployment dynamographdeploymentrequest dynamomodel; do
        if ! kubectl get "$kind" -A --no-headers 2>/dev/null | grep -q .; then
            info "  No ${kind}(s) found"
            continue
        fi
        info "  Cleaning up ${kind}(s)…"
        kubectl get "$kind" -A --no-headers \
            -o custom-columns=":metadata.name,:metadata.namespace" 2>/dev/null \
        | while IFS= read -r line; do
            read -r name ns <<<"$line"
            [[ -z "$name" || -z "$ns" ]] && continue
            kubectl patch "$kind" "$name" -n "$ns" \
                --type='merge' -p='{"metadata":{"finalizers":null}}' 2>/dev/null || true
            kubectl delete "$kind" "$name" -n "$ns" \
                --ignore-not-found=true --timeout=30s 2>/dev/null || true
        done
        # Brief wait for deletion
        for _ in $(seq 1 12); do
            kubectl get "$kind" -A --no-headers 2>/dev/null | grep -q . || break
            sleep 5
        done
    done

    # -----------------------------------------------------------------
    # Safety net: remove blueprint-managed Karpenter NodePools to prevent
    # orphaned expensive GPU nodes from lingering after infra teardown.
    # -----------------------------------------------------------------
    info "  Checking for blueprint-managed Karpenter NodePools..."
    _bp_pools=$(kubectl get nodepool -l app.kubernetes.io/managed-by=dynamo-blueprints \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || echo "")
    if [[ -n "$_bp_pools" ]]; then
        info "  Found blueprint-managed NodePools — removing to prevent orphaned nodes"
        while IFS= read -r np; do
            [[ -z "$np" ]] && continue
            info "    Deleting NodePool: ${np}"
            kubectl delete nodepool "$np" --ignore-not-found --timeout=30s 2>/dev/null || true
            kubectl delete ec2nodeclass "$np" --ignore-not-found --timeout=30s 2>/dev/null || true
        done <<< "$_bp_pools"
        info "  Blueprint-managed NodePools cleaned up"
    else
        info "  No blueprint-managed NodePools found"
    fi
fi

# =============================================================================
# Phase 1b — Unblock stuck namespace deletion (best-effort)
# =============================================================================
# During teardown, the dynamo namespace can get stuck in Terminating when:
#   a) Aggregated APIServices (e.g. metrics-server) become stale because their
#      backing pods are gone (no nodes).  The namespace controller can't
#      complete API discovery, so the built-in "kubernetes" spec.finalizer
#      never clears.
#   b) ArgoCD Application finalizers can't reconcile because the ArgoCD
#      controller pods are gone (no nodes).
#
# This phase proactively clears these blockers BEFORE terraform destroy runs,
# preventing the "context deadline exceeded" timeout.
# =============================================================================
if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
    info "=== Phase 1b: Unblock stuck namespace deletion ==="

    # --- (a) Delete stale aggregated APIServices ---
    # When metrics-server (or other aggregated APIs) pods are gone, the
    # APIService stays registered but returns MissingEndpoints / False.
    # This prevents namespace GC from completing its discovery sweep.
    _stale_apis=$(kubectl get apiservices -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$_stale_apis" ]]; then
        info "  Found stale APIServices — removing to unblock namespace GC"
        while IFS= read -r api; do
            [[ -z "$api" ]] && continue
            info "    Deleting stale APIService: ${api}"
            kubectl delete apiservice "$api" --ignore-not-found 2>/dev/null || true
        done <<< "$_stale_apis"
    else
        info "  No stale APIServices found"
    fi

    # --- Pre-emptive APIService deletion ---
    # TIMING GAP FIX: The stale-APIService check above only catches services
    # that are ALREADY unhealthy.  But during terraform destroy (Phase 2),
    # node groups are removed which kills addon pods (metrics-server, etc.)
    # AFTER this check runs.  Their APIService registrations stay behind with
    # Available=False/MissingEndpoints, blocking the namespace controller's
    # discovery sweep and causing namespace deletion to hang indefinitely.
    #
    # Solution: pre-emptively delete known aggregated APIServices that will
    # lose their backing pods during terraform destroy.  These are all about
    # to be destroyed anyway, so removing them early prevents the race.
    echo ""
    info "  --- Pre-emptive: removing aggregated APIServices before terraform destroy ---"

    # Well-known aggregated APIServices backed by addon pods on worker nodes
    PREEMPTIVE_APISERVICES=(
        "v1beta1.metrics.k8s.io"                   # metrics-server addon
        "v1beta3.flowcontrol.apiserver.k8s.io"      # sometimes stale after node loss
    )
    for api_svc in "${PREEMPTIVE_APISERVICES[@]}"; do
        if kubectl get apiservice "$api_svc" &>/dev/null; then
            info "    Deleting APIService: $api_svc (pre-emptive, will be destroyed by terraform)"
            kubectl delete apiservice "$api_svc" --timeout=30s 2>/dev/null || true
        fi
    done

    # Also delete any OTHER aggregated (non-local) APIServices that are backed
    # by in-cluster pods about to lose their nodes.  Aggregated APIServices
    # have a non-null .spec.service field; local ones (backed by the API
    # server itself) have spec.service == null and are safe to skip.
    info "    Checking for additional aggregated APIServices..."
    _agg_apis=$(kubectl get apiservice -o json 2>/dev/null | jq -r '
        .items[] |
        select(.spec.service != null and .spec.service.name != null) |
        .metadata.name
    ' 2>/dev/null || echo "")
    if [[ -n "$_agg_apis" ]]; then
        while IFS= read -r api_svc; do
            [[ -z "$api_svc" ]] && continue
            info "    Deleting aggregated APIService: $api_svc"
            kubectl delete apiservice "$api_svc" --timeout=30s 2>/dev/null || true
        done <<< "$_agg_apis"
    else
        info "    No additional aggregated APIServices found"
    fi
    info "  --- Pre-emptive APIService cleanup complete ---"

    # --- (b) Remove finalizers from stuck ArgoCD Applications ---
    # During teardown, ArgoCD apps may have deletionTimestamp set but their
    # finalizers can't reconcile (controller pods gone).  Patch them out.
    _stuck_apps=$(kubectl get applications -n argocd -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$_stuck_apps" ]]; then
        info "  Found stuck ArgoCD Applications — removing finalizers"
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            info "    Patching Application: ${app}"
            kubectl patch application "$app" -n argocd \
                --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        done <<< "$_stuck_apps"
    else
        info "  No stuck ArgoCD Applications found"
    fi

    # --- (c) Force-finalize dynamo namespace if still stuck ---
    _ns_phase=$(kubectl get ns dynamo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$_ns_phase" == "Terminating" ]]; then
        info "  dynamo namespace is Terminating — waiting 15s for GC to catch up..."
        sleep 15
        _ns_phase=$(kubectl get ns dynamo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$_ns_phase" == "Terminating" ]]; then
            warn "  dynamo namespace still stuck — force-removing spec.finalizers"
            kubectl get ns dynamo -o json 2>/dev/null \
                | jq '.spec.finalizers = []' \
                | kubectl replace --raw "/api/v1/namespaces/dynamo/finalize" -f - 2>/dev/null || true
            info "  Waiting 10s for namespace to terminate..."
            sleep 10
            if kubectl get ns dynamo >/dev/null 2>&1; then
                warn "  dynamo namespace persists — terraform destroy may need manual state cleanup"
            else
                info "  dynamo namespace successfully removed"
            fi
        else
            info "  dynamo namespace resolved on its own"
        fi
    elif [[ -z "$_ns_phase" ]]; then
        info "  dynamo namespace does not exist (already clean)"
    else
        info "  dynamo namespace is in phase: ${_ns_phase}"
    fi
fi

# =============================================================================
# Phase 2 — Terraform destroy (delegate to base cleanup template)
# =============================================================================
# The base template (staged into _LOCAL by install.sh) handles:
#   - kubectl_manifest targeted destroy
#   - full terraform destroy (-auto-approve, -var-file, region)
#   - EBS volume cleanup
#
# We capture stdout/stderr to a log file so we can scan for Terraform error
# markers even if the base template exits 0 (which can happen when Terraform
# returns 0 despite outputting errors).  Output is also tee'd to the terminal
# so the operator sees real-time progress.
# =============================================================================
info "=== Phase 2: Terraform destroy (via base template) ==="

if [[ ! -d "$TERRAFORM_DIR" ]]; then
    warn "terraform/_LOCAL not found — nothing to destroy"
    info "If infrastructure was previously destroyed, this is expected."
else
    if [[ ! -f "${TERRAFORM_DIR}/cleanup.sh" ]]; then
        error "Base cleanup template not found at ${TERRAFORM_DIR}/cleanup.sh"
        error "Re-stage it:  cp -r ../base/terraform/* ${TERRAFORM_DIR}/"
        exit 1
    fi

    CLEANUP_LOG="${TERRAFORM_DIR}/cleanup-wrapper.log"

    # --- Helper: check for Terraform error markers in log output ---
    # Terraform sometimes exits 0 despite emitting error blocks.  We detect
    # lines matching the standard Terraform error box format:
    #   │ Error: <message>
    # or bare error lines:
    #   Error: <message>
    _has_tf_errors() {
        grep -qE '^(│ Error:|Error:)' "$CLEANUP_LOG" 2>/dev/null
    }

    # --- First attempt ---
    tf_rc=0
    ( cd "$TERRAFORM_DIR" && bash ./cleanup.sh ) > >(tee "$CLEANUP_LOG") 2>&1 || tf_rc=$?

    _first_failed=false
    if (( tf_rc != 0 )); then
        warn "Base cleanup template exited with code ${tf_rc} — will attempt recovery"
        _first_failed=true
    elif _has_tf_errors; then
        warn "Terraform error markers detected in cleanup output (exit 0) — will attempt recovery"
        _first_failed=true
    fi

    # =========================================================================
    # Phase 2b — Post-destroy recovery and retry
    # =========================================================================
    # If the first terraform destroy failed, it's often because namespace
    # deletion hung due to stale APIServices that appeared DURING the destroy
    # (the timing gap: nodes died → metrics-server died → APIService went
    # stale → namespace controller blocked).
    #
    # Recovery steps:
    #   1. Re-check for stale APIServices (may have appeared during destroy)
    #   2. Force-remove namespace finalizers for any stuck namespaces
    #   3. Retry terraform destroy
    # =========================================================================
    if [[ "$_first_failed" == "true" ]]; then
        echo ""
        info "=== Phase 2b: Post-destroy recovery ==="

        # Check if the cluster API is still reachable for remediation
        _p2b_cluster_ok=false
        if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
            _p2b_cluster_ok=true
        fi

        if [[ "$_p2b_cluster_ok" == "true" ]]; then
            # --- (2b-a) Re-check and remove stale APIServices ---
            info "  Re-checking for stale APIServices after failed destroy..."
            _stale_apis_p2b=$(kubectl get apiservices -o json 2>/dev/null \
                | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null || echo "")
            if [[ -n "$_stale_apis_p2b" ]]; then
                info "  Found stale APIServices — removing"
                while IFS= read -r api; do
                    [[ -z "$api" ]] && continue
                    info "    Deleting stale APIService: ${api}"
                    kubectl delete apiservice "$api" --ignore-not-found --timeout=30s 2>/dev/null || true
                done <<< "$_stale_apis_p2b"
            else
                info "  No stale APIServices found"
            fi

            # Also sweep any remaining aggregated (non-local) APIServices
            _agg_apis_p2b=$(kubectl get apiservice -o json 2>/dev/null | jq -r '
                .items[] |
                select(.spec.service != null and .spec.service.name != null) |
                .metadata.name
            ' 2>/dev/null || echo "")
            if [[ -n "$_agg_apis_p2b" ]]; then
                info "  Removing remaining aggregated APIServices..."
                while IFS= read -r api_svc; do
                    [[ -z "$api_svc" ]] && continue
                    info "    Deleting aggregated APIService: $api_svc"
                    kubectl delete apiservice "$api_svc" --timeout=30s 2>/dev/null || true
                done <<< "$_agg_apis_p2b"
            fi

            # --- (2b-b) Force-remove finalizers from stuck namespaces ---
            info "  Checking for stuck namespaces..."
            _stuck_ns=$(kubectl get ns -o json 2>/dev/null \
                | jq -r '.items[] | select(.status.phase == "Terminating") | .metadata.name' 2>/dev/null || echo "")
            if [[ -n "$_stuck_ns" ]]; then
                info "  Found stuck namespaces — force-removing finalizers"
                while IFS= read -r ns; do
                    [[ -z "$ns" ]] && continue
                    warn "    Force-removing finalizers from namespace: ${ns}"
                    kubectl get ns "$ns" -o json 2>/dev/null \
                        | jq '.spec.finalizers = []' \
                        | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
                done <<< "$_stuck_ns"
                info "  Waiting 15s for namespaces to terminate..."
                sleep 15
            else
                info "  No stuck namespaces found"
            fi

            # --- (2b-c) Remove stuck ArgoCD Application finalizers ---
            _stuck_apps_p2b=$(kubectl get applications -n argocd -o json 2>/dev/null \
                | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null || echo "")
            if [[ -n "$_stuck_apps_p2b" ]]; then
                info "  Found stuck ArgoCD Applications — removing finalizers"
                while IFS= read -r app; do
                    [[ -z "$app" ]] && continue
                    info "    Patching Application: ${app}"
                    kubectl patch application "$app" -n argocd \
                        --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
                done <<< "$_stuck_apps_p2b"
            fi
        else
            warn "  Cluster API not reachable — skipping Kubernetes-level recovery"
        fi

        # --- Retry terraform destroy ---
        echo ""
        info "  Retrying terraform destroy..."
        CLEANUP_LOG_RETRY="${TERRAFORM_DIR}/cleanup-wrapper-retry.log"
        tf_rc_retry=0
        ( cd "$TERRAFORM_DIR" && bash ./cleanup.sh ) > >(tee "$CLEANUP_LOG_RETRY") 2>&1 || tf_rc_retry=$?

        if (( tf_rc_retry != 0 )); then
            error "Retry: base cleanup template exited with code ${tf_rc_retry}"
            print_recovery "$tf_rc_retry"
            exit "$tf_rc_retry"
        fi

        if grep -qE '^(│ Error:|Error:)' "$CLEANUP_LOG_RETRY" 2>/dev/null; then
            error "Retry: Terraform error markers detected in cleanup output"
            error "See log: ${CLEANUP_LOG_RETRY}"
            print_recovery 1
            exit 1
        fi

        info "  Retry succeeded"
    fi

    info "Base cleanup template completed successfully"
fi

# =============================================================================
# Phase 3 — _LOCAL disposition
# =============================================================================
# Conclusive success requires ALL of:
#   1. Base cleanup template ran and exited 0
#   2. No Terraform error markers in captured output
#   3. terraform state list is empty
#
# Default: delete _LOCAL on conclusive success.
# --keep-local: preserve _LOCAL even on success (debugging escape hatch).
# =============================================================================
info "=== Phase 3: _LOCAL disposition ==="

if [[ -d "$TERRAFORM_DIR" ]]; then
    # Check state emptiness — a non-empty state means resources may still exist
    state_list=""
    state_list=$(cd "$TERRAFORM_DIR" && terraform state list 2>/dev/null) || state_list=""

    if [[ -n "$state_list" ]]; then
        # State not empty — refuse to delete regardless of flags
        warn "State is NOT empty — preserving ${TERRAFORM_DIR}"
        warn "Remaining:"
        echo "$state_list"
    elif [[ "$OPT_KEEP_LOCAL" == "true" ]]; then
        # Explicitly asked to keep
        info "${TERRAFORM_DIR} preserved (--keep-local was set)."
    else
        # Conclusive success: delete _LOCAL
        info "State empty + no error markers → removing ${TERRAFORM_DIR}"
        rm -rf "$TERRAFORM_DIR"
        info "${TERRAFORM_DIR} removed"
    fi
else
    info "${TERRAFORM_DIR} already absent"
fi

# =============================================================================
# Success
# =============================================================================
echo ""
info "=============================================================================="
info " NVIDIA Dynamo cleanup completed successfully"
info "=============================================================================="
