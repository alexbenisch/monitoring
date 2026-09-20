#!/usr/bin/env bash
#
# Tear down. By default only the app; --all removes the whole minikube profile.
#
#   ./scripts/99-teardown.sh          # delete the demo namespace
#   ./scripts/99-teardown.sh --stack  # also uninstall kube-prometheus-stack
#   ./scripts/99-teardown.sh --all    # delete the minikube profile entirely

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
PROFILE="${MINIKUBE_PROFILE:-obs-lab}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

MODE="${1:-app}"

case "$MODE" in
  app)
    log "deleting the demo namespace"
    kubectl delete -k "${ROOT_DIR}/k8s" --ignore-not-found
    ;;
  --stack)
    log "deleting the demo namespace"
    kubectl delete -k "${ROOT_DIR}/k8s" --ignore-not-found
    log "uninstalling kube-prom-stack"
    helm uninstall kube-prom-stack -n monitoring || true
    # Helm does not remove CRDs it installed. Left behind, they break a later
    # reinstall of a different chart version.
    log "removing the Prometheus Operator CRDs"
    kubectl get crd -o name | grep -E 'monitoring\.coreos\.com$' \
      | xargs -r kubectl delete
    kubectl delete namespace monitoring --ignore-not-found
    ;;
  --all)
    log "deleting minikube profile '${PROFILE}'"
    minikube delete -p "$PROFILE"
    ;;
  *)
    echo "usage: $0 [app|--stack|--all]" >&2
    exit 64
    ;;
esac

log "done"
