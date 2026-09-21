#!/usr/bin/env bash
#
# Build batch-worker into the minikube node and apply scenario 02's manifests.
# Also rebuilds demoapp at 1.1.0 if that image is missing, since scenario 02
# needs the version that emits structured logs.
#
# Run this on the lab host - it needs docker and minikube.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
REPO_DIR="$(dirname "${ROOT_DIR}")"

PROFILE="${MINIKUBE_PROFILE:-obs-lab}"
WORKER_IMAGE="obs-lab/batch-worker"
WORKER_TAG="${WORKER_TAG:-1.0.0}"
DEMOAPP_IMAGE="obs-lab/demoapp"
DEMOAPP_TAG="${DEMOAPP_TAG:-1.1.0}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null    || die "docker not found"
command -v minikube >/dev/null  || die "minikube not found"

# --- demoapp 1.1.0: the logging build ----------------------------------
# Scenario 01 ships 1.0.0, which emits metrics and no application logs. 1.1.0
# adds structured JSON logging and changes nothing else, so scenario 01's
# exercises still behave identically.
if ! minikube image ls -p "$PROFILE" 2>/dev/null | grep -q "${DEMOAPP_IMAGE}:${DEMOAPP_TAG}"; then
  log "building ${DEMOAPP_IMAGE}:${DEMOAPP_TAG}"
  docker build -t "${DEMOAPP_IMAGE}:${DEMOAPP_TAG}" "${REPO_DIR}/scenario-01-metrics/app"
  log "loading it into minikube profile '${PROFILE}'"
  minikube image load "${DEMOAPP_IMAGE}:${DEMOAPP_TAG}" -p "$PROFILE"
else
  log "${DEMOAPP_IMAGE}:${DEMOAPP_TAG} already present"
fi

log "pointing the demoapp deployment at ${DEMOAPP_TAG}"
kubectl -n demo set image deploy/demoapp "demoapp=${DEMOAPP_IMAGE}:${DEMOAPP_TAG}"

# --- batch-worker ------------------------------------------------------
log "building ${WORKER_IMAGE}:${WORKER_TAG}"
docker build -t "${WORKER_IMAGE}:${WORKER_TAG}" "${ROOT_DIR}/app"

log "loading it into minikube profile '${PROFILE}'"
minikube image load "${WORKER_IMAGE}:${WORKER_TAG}" -p "$PROFILE"

log "applying manifests"
kubectl apply -k "${ROOT_DIR}/k8s"

log "waiting for the rollouts"
kubectl -n demo rollout status deploy/demoapp --timeout=3m
kubectl -n demo rollout status deploy/batch-worker --timeout=3m

cat <<'EOF'

Deployed. Alloy needs ~30s to discover the new pods and ship the first lines.

Check that logs are arriving, from your workstation:

  logcli --addr=http://loki:3100 labels
  logcli --addr=http://loki:3100 labels app
  logcli --addr=http://loki:3100 query --limit=5 '{app="batch-worker"}'

If `labels app` does not list both demoapp and batch-worker, start at
exercise 1 - finding out why is the exercise.

EOF
