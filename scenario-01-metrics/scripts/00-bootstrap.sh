#!/usr/bin/env bash
#
# Bring up minikube and install kube-prometheus-stack.
# Idempotent: safe to re-run.
#
# Usage: ./scripts/00-bootstrap.sh [--cpus N] [--memory MB] [--driver NAME]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

PROFILE="${MINIKUBE_PROFILE:-obs-lab}"
# Sized for a cpx42 host (8 vCPU / 16 GB), leaving the host ~3 GB.
#
# These are the numbers that actually bind, and they are easy to miss: with
# the docker driver, --memory is a cgroup limit on the node container, but the
# kubelet reports /proc/meminfo, which is NOT namespaced. So Kubernetes
# advertises the host's full RAM while the container is capped here, the
# scheduler places pods against a ceiling that does not exist, and the runtime
# OOM-kills whatever crosses the real one.
#
# Growing the server does not change this on its own - the cap travels with
# the minikube profile. An existing cluster needs:
#   minikube stop -p obs-lab
#   minikube config set -p obs-lab memory 13312
#   minikube config set -p obs-lab cpus 8
#   minikube start -p obs-lab
CPUS="${CPUS:-8}"
MEMORY="${MEMORY:-13312}"
DRIVER="${DRIVER:-docker}"
K8S_VERSION="${K8S_VERSION:-stable}"
RELEASE="kube-prom-stack"
MON_NS="monitoring"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus)   CPUS="$2";   shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --driver) DRIVER="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in minikube kubectl helm docker; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found in PATH"
done

# --- minikube -----------------------------------------------------------
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  log "minikube profile '$PROFILE' already running"
else
  log "starting minikube profile '$PROFILE' (${CPUS} cpu, ${MEMORY}MB, driver=${DRIVER})"
  minikube start \
    -p "$PROFILE" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --driver="$DRIVER" \
    --kubernetes-version="$K8S_VERSION" \
    --addons=metrics-server
fi

kubectl config use-context "$PROFILE"

# --- helm repo ----------------------------------------------------------
log "adding/updating the prometheus-community helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null

# --- kube-prometheus-stack ----------------------------------------------
# Pin the chart version for reproducibility once you know which one you want:
#   helm search repo prometheus-community/kube-prometheus-stack --versions | head
# then add: --version <x.y.z>
log "installing/upgrading ${RELEASE} into namespace ${MON_NS}"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$MON_NS" \
  --create-namespace \
  --values "${ROOT_DIR}/helm/kube-prometheus-stack.values.yaml" \
  --wait \
  --timeout 15m

log "waiting for Prometheus and Grafana to be ready"
kubectl -n "$MON_NS" rollout status deploy/"${RELEASE}-grafana" --timeout=5m
kubectl -n "$MON_NS" wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus --timeout=5m

cat <<EOF

$(log "bootstrap complete")

  Namespace:  ${MON_NS}
  Grafana:    admin / obslab (anonymous viewer access is also enabled)

Next:
  ./scripts/10-deploy-app.sh
  ./scripts/port-forward.sh
EOF
