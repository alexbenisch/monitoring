#!/usr/bin/env bash
#
# Fault injection for the lab. Each subcommand changes one thing so you can
# watch exactly one signal move.
#
#   ./scripts/chaos.sh status
#   ./scripts/chaos.sh level 0|1|2|3      raise error rate + latency on /api/checkout
#   ./scripts/chaos.sh cardinality on|off enable the label explosion on /api/report
#   ./scripts/chaos.sh break-scrape       remove the ServiceMonitor release label
#   ./scripts/chaos.sh fix-scrape         put it back
#   ./scripts/chaos.sh scale N            scale demoapp replicas
#   ./scripts/chaos.sh reset              everything back to the healthy baseline

set -euo pipefail

NS="demo"
DEPLOY="demoapp"
SM="demoapp"
RELEASE_LABEL="kube-prom-stack"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,14p' "$0"; }

cmd_status() {
  log "demoapp environment"
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}' \
    2>/dev/null || true
  echo
  log "replicas"
  kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready{"\n"}'
  echo
  log "ServiceMonitor labels"
  kubectl -n "$NS" get servicemonitor "$SM" -o jsonpath='{.metadata.labels}{"\n"}'
}

cmd_level() {
  local lvl="${1:-}"
  [[ "$lvl" =~ ^[0-3]$ ]] || die "level must be 0, 1, 2 or 3"
  log "setting CHAOS_LEVEL=${lvl}"
  kubectl -n "$NS" set env "deploy/${DEPLOY}" "CHAOS_LEVEL=${lvl}"
  kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=2m
  case "$lvl" in
    0) echo "baseline: ~8% errors on /api/checkout" ;;
    1) echo "~20% errors, +200ms" ;;
    2) echo "~32% errors, +400ms - this crosses the DemoAppHighErrorRate threshold" ;;
    3) echo "~44% errors, +600ms" ;;
  esac
}

cmd_cardinality() {
  local state="${1:-}"
  case "$state" in
    on)  val=1 ;;
    off) val=0 ;;
    *) die "cardinality takes 'on' or 'off'" ;;
  esac
  log "setting CARDINALITY=${val}"
  kubectl -n "$NS" set env "deploy/${DEPLOY}" "CARDINALITY=${val}"
  kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=2m
  if [[ "$val" == "1" ]]; then
    warn "demoapp_report_requests_total now grows one series per request."
    warn "Watch: count(demoapp_report_requests_total) and prometheus_tsdb_head_series"
  else
    warn "New series stop appearing, but the OLD ones stay in the head block"
    warn "until they age out of retention. Deleting the bad label is not a"
    warn "retroactive fix - that is the real lesson."
  fi
}

cmd_break_scrape() {
  log "removing the 'release' label from ServiceMonitor/${SM}"
  kubectl -n "$NS" label servicemonitor "$SM" release- --overwrite
  warn "Prometheus will drop the target within ~30s. Note that NOTHING logs an"
  warn "error about this - the target simply stops existing. Check /targets."
}

cmd_fix_scrape() {
  log "restoring release=${RELEASE_LABEL}"
  kubectl -n "$NS" label servicemonitor "$SM" "release=${RELEASE_LABEL}" --overwrite
}

cmd_scale() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "scale needs a number"
  log "scaling ${DEPLOY} to ${n}"
  kubectl -n "$NS" scale "deploy/${DEPLOY}" --replicas="$n"
}

cmd_reset() {
  log "resetting to the healthy baseline"
  kubectl -n "$NS" set env "deploy/${DEPLOY}" CHAOS_LEVEL=0 CARDINALITY=0
  kubectl -n "$NS" label servicemonitor "$SM" "release=${RELEASE_LABEL}" --overwrite
  kubectl -n "$NS" scale "deploy/${DEPLOY}" --replicas=2
  kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=2m
}

case "${1:-}" in
  status)       shift; cmd_status "$@" ;;
  level)        shift; cmd_level "$@" ;;
  cardinality)  shift; cmd_cardinality "$@" ;;
  break-scrape) shift; cmd_break_scrape "$@" ;;
  fix-scrape)   shift; cmd_fix_scrape "$@" ;;
  scale)        shift; cmd_scale "$@" ;;
  reset)        shift; cmd_reset "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown subcommand: $1" ;;
esac
