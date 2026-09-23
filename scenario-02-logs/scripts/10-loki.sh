#!/usr/bin/env bash
#
# Install Loki (single binary, filesystem) and Alloy (daemonset) into the
# `logging` namespace. Idempotent - `helm upgrade --install` either way.
#
# Run this on the lab host, not your workstation: it needs helm pointed at the
# minikube cluster.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

NS="logging"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.3.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.12.1}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v helm >/dev/null || die "helm not found"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster"

# Scenario 01 has to be up first: this scenario reuses its Grafana (for the
# datasource) and its Prometheus (for the ServiceMonitors).
if ! kubectl get ns monitoring >/dev/null 2>&1; then
  die "namespace 'monitoring' not found - run scenario 01 first"
fi

log "adding the grafana helm repo"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null

log "creating namespace ${NS}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "installing loki (chart ${LOKI_CHART_VERSION})"
helm upgrade --install loki grafana/loki \
  --namespace "$NS" \
  --version "$LOKI_CHART_VERSION" \
  --values "${ROOT_DIR}/helm/loki.values.yaml" \
  --wait --timeout 10m

log "installing alloy (chart ${ALLOY_CHART_VERSION})"
helm upgrade --install alloy grafana/alloy \
  --namespace "$NS" \
  --version "$ALLOY_CHART_VERSION" \
  --values "${ROOT_DIR}/helm/alloy.values.yaml" \
  --wait --timeout 5m

log "waiting for loki to report ready"
kubectl -n "$NS" rollout status statefulset/loki --timeout=5m

# The readiness probe passing is not the same as the ingester accepting
# writes. Ask Loki directly.
#
# Through the API server's service proxy, NOT `kubectl exec`: the Loki image
# is distroless. It has no shell and no wget, so anything exec'd into it fails
# with "executable file not found" - and piping that to grep hides the error,
# leaving a loop that can only ever time out silently.
log "checking /ready"
ready=no
for _ in $(seq 1 30); do
  if kubectl get --raw \
      "/api/v1/namespaces/${NS}/services/loki:3100/proxy/ready" 2>/dev/null \
      | grep -q "ready"; then
    log "loki is ready"
    ready=yes
    break
  fi
  sleep 5
done
[[ "$ready" == "yes" ]] || warn "loki did not report ready within 150s - check: kubectl -n ${NS} logs statefulset/loki"

cat <<EOF

Loki and Alloy are installed.

Next:
  ./scripts/20-deploy-logapps.sh     build and deploy batch-worker

Then, from your workstation (both go over the tailnet):
  logcli --addr=http://loki:3100 labels
  curl -s 'http://loki:3100/loki/api/v1/labels' | jq

If 'logcli labels' returns nothing, Alloy has not shipped anything yet. Give
it 30s, then check:
  kubectl -n ${NS} logs daemonset/alloy --tail=50

EOF
