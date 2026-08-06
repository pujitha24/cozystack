# shellcheck shell=bash
# Shared helper: point tenant Kubernetes e2e worker nodes at the in-sandbox
# ghcr.io pull-through registry (hack/e2e-ghcr-mirror.yaml) when it is up, via the
# chart's `talos.registryMirrors` knob, otherwise emit nothing so workers fall back
# to pulling ghcr.io directly (the mirror can only help, never make CI worse).
#
# Why: tenant worker Talos nodes pull `ghcr.io/siderolabs/kubelet` directly; that
# egress is flaky/rate-limited from the CI runner and the pull times out with a TLS
# handshake timeout, so the kubelet service never starts and no tenant node joins.
# Diagnosed in cozystack/cozystack#3548 (in-guest Talos dmesg), tracked by #3513.
# Same flaky-public-egress class the talos-image-cache (#3231) fixed for the OS image.
#
# NOTE: this half cannot be validated without a CI run. It is intentionally simpler
# than talos-image-cache.sh (rollout-status gate + egress-allow, no tenant-scoped
# reachability probe yet); a byte-level reachability probe from a virt-launcher-labelled
# Pod is a hardening follow-up once CI confirms the base path.

GHCR_MIRROR_SVC_URL="${GHCR_MIRROR_SVC_URL:-http://ghcr-mirror.kube-system.svc}"
_GHCR_MIRROR_DECISION_FILE="${_GHCR_MIRROR_DECISION_FILE:-/tmp/e2e-ghcr-mirror-endpoint}"
GHCR_MIRROR_MANIFEST="${GHCR_MIRROR_MANIFEST:-hack/e2e-ghcr-mirror.yaml}"

# ghcr_registry_mirrors_block: pure string builder. Given a mirror endpoint URL
# ($1, may be empty), print the `registryMirrors:` sub-block for a tenant Kubernetes
# CR `spec.talos` (4-space indented, i.e. nested under `  talos:`), or nothing when
# the endpoint is empty. Kept separate so it can be unit-tested: an indentation or
# quoting slip here would emit an invalid CR and every kubernetes-* test would fail.
ghcr_registry_mirrors_block() {
  local endpoint="$1"
  [ -n "$endpoint" ] || return 0
  printf '    registryMirrors:\n      ghcr.io:\n        endpoints:\n          - %s\n' "$endpoint"
}

# _apply_ghcr_mirror_egress_policy: install the CiliumClusterwideNetworkPolicy that
# lets tenant worker VM (virt-launcher) Pods egress to the mirror. It ships in the
# manifest but is applied here, after Cilium's CRDs exist. Idempotent, best-effort.
_apply_ghcr_mirror_egress_policy() {
  command -v yq >/dev/null 2>&1 || return 1
  yq 'select(.kind == "CiliumClusterwideNetworkPolicy")' "$GHCR_MIRROR_MANIFEST" 2>/dev/null \
    | kubectl apply -f - >/dev/null 2>&1
}

# resolve_ghcr_mirror_endpoint: print the mirror endpoint URL to use, or an empty
# string to signal "pull ghcr.io directly". Resolved once and cached in a /tmp file
# that persists across bats files (same sandbox container), so only the first tenant
# test pays the readiness wait.
resolve_ghcr_mirror_endpoint() {
  if [ -f "$_GHCR_MIRROR_DECISION_FILE" ]; then
    cat "$_GHCR_MIRROR_DECISION_FILE"
    return 0
  fi
  local endpoint=""
  if kubectl -n kube-system get deploy ghcr-mirror >/dev/null 2>&1; then
    if kubectl -n kube-system rollout status deploy/ghcr-mirror --timeout=5m >/dev/null 2>&1; then
      _apply_ghcr_mirror_egress_policy || true
      endpoint="$GHCR_MIRROR_SVC_URL"
      echo "ghcr-mirror pull-through registry ready -- tenant workers mirror ghcr.io via ${endpoint}" >&2
    else
      echo "WARNING: ghcr-mirror not Available in time -- tenant workers pull ghcr.io directly" >&2
    fi
  else
    echo "ghcr-mirror not deployed -- tenant workers pull ghcr.io directly" >&2
  fi
  printf '%s' "$endpoint" > "$_GHCR_MIRROR_DECISION_FILE"
  printf '%s' "$endpoint"
}
