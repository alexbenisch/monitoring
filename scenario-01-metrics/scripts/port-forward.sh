#!/usr/bin/env bash
#
# Port-forward Grafana, Prometheus and Alertmanager. Ctrl-C stops all three.
#
#   ./scripts/port-forward.sh              # localhost only (use an SSH tunnel)
#   ./scripts/port-forward.sh --bind-all   # 0.0.0.0 - see the warning below
#
# On a vserver, prefer the SSH tunnel from your workstation:
#   ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 user@vserver
# and leave this script on its localhost default. --bind-all exposes Grafana
# and an unauthenticated Prometheus to the whole internet unless your firewall
# says otherwise.

set -euo pipefail

NS="monitoring"
ADDRESS="127.0.0.1"

[[ "${1:-}" == "--bind-all" ]] && ADDRESS="0.0.0.0"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# kube-prometheus-stack labels its Services two different ways: the Grafana
# sub-chart uses the modern app.kubernetes.io/name, while the Prometheus and
# Alertmanager Services the chart renders itself still carry the legacy `app`
# label. Try both.
#
# The trailing `|| true` matters: kubectl exits non-zero when the jsonpath
# index finds nothing, and under `set -e` a bare assignment from a command
# substitution propagates that status and kills the script - silently, before
# forward() can report which service was missing.
svc_for() {
  local sel name
  for sel in "app.kubernetes.io/name=$1" "app=kube-prometheus-stack-$1"; do
    name="$(kubectl -n "$NS" get svc -l "$sel" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$name" ]]; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 0
}

GRAFANA="$(svc_for grafana)"
PROM="$(svc_for prometheus)"
ALERT="$(svc_for alertmanager)"

PIDS=()
cleanup() {
  log "stopping port-forwards"
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

forward() {
  local svc="$1" local_port="$2" remote_port="$3" name="$4"
  if [[ -z "$svc" ]]; then
    log "skipping ${name}: service not found"
    return
  fi
  kubectl -n "$NS" port-forward --address "$ADDRESS" \
    "svc/${svc}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  PIDS+=("$!")
  log "${name}  http://${ADDRESS}:${local_port}  (svc/${svc})"
}

forward "$GRAFANA" 3000 80   "Grafana     "
forward "$PROM"    9090 9090 "Prometheus  "
forward "$ALERT"   9093 9093 "Alertmanager"

echo
log "Grafana login: admin / obslab. Ctrl-C to stop."
wait
