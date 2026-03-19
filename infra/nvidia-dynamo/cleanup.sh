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
#       it is stuck in Terminating.
#   2.  Delegate to the base cleanup template in terraform/_LOCAL/ for:
#      - kubectl_manifest targeted destroy
#      - full terraform destroy
#      - EBS volume cleanup
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

    tf_rc=0
    ( cd "$TERRAFORM_DIR" && bash ./cleanup.sh ) > >(tee "$CLEANUP_LOG") 2>&1 || tf_rc=$?

    if (( tf_rc != 0 )); then
        error "Base cleanup template exited with code ${tf_rc}"
        print_recovery "$tf_rc"
        exit "$tf_rc"
    fi

    # -------------------------------------------------------------------------
    # Scan captured output for Terraform error markers.
    # Terraform sometimes exits 0 despite emitting error blocks.  We detect
    # lines matching the standard Terraform error box format:
    #   │ Error: <message>
    # or bare error lines:
    #   Error: <message>
    # -------------------------------------------------------------------------
    if grep -qE '^(│ Error:|Error:)' "$CLEANUP_LOG" 2>/dev/null; then
        error "Terraform error markers detected in cleanup output (despite exit code 0)"
        error "See log: ${CLEANUP_LOG}"
        print_recovery 1
        exit 1
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
