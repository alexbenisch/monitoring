#!/usr/bin/env bash
#
# Remove scenario 02 and leave scenario 01 running.
#
#   ./scripts/99-teardown.sh          apps + Loki + Alloy, keep the PVC
#   ./scripts/99-teardown.sh --all    also delete the PVC and the namespace

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="logging"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "deleting scenario 02 manifests"
kubectl delete -k "${ROOT_DIR}/k8s" --ignore-not-found

log "uninstalling alloy"
helm uninstall alloy -n "$NS" 2>/dev/null || true

log "uninstalling loki"
helm uninstall loki -n "$NS" 2>/dev/null || true

if [[ "${1:-}" == "--all" ]]; then
  # helm does NOT delete StatefulSet PVCs. Every ingested log line is still
  # on that disk until you do this yourself.
  log "deleting the loki PVC (all ingested logs)"
  kubectl -n "$NS" delete pvc -l app.kubernetes.io/name=loki --ignore-not-found
  log "deleting namespace ${NS}"
  kubectl delete namespace "$NS" --ignore-not-found
else
  log "keeping the PVC - re-running 10-loki.sh will find your old logs"
fi

# Put demoapp back on the scenario 01 image, so scenario 01 stands alone again.
if kubectl -n demo get deploy demoapp >/dev/null 2>&1; then
  log "reverting demoapp to 1.0.0"
  kubectl -n demo set image deploy/demoapp demoapp=obs-lab/demoapp:1.0.0 || true
fi

log "done"
