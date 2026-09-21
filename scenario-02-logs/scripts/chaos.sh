#!/usr/bin/env bash
#
# Log-flavoured fault injection. Each subcommand changes one thing, so you can
# watch one query move.
#
#   ./scripts/chaos.sh status                 what is set right now
#   ./scripts/chaos.sh level 0|1|2|3          batch-worker failure + retry pressure
#   ./scripts/chaos.sh rate N                 log lines per second, per pod
#   ./scripts/chaos.sh noise 0.0..1.0         share of lines that are debug drizzle
#   ./scripts/chaos.sh malformed 0.0..1.0     share of JSON lines that are truncated
#   ./scripts/chaos.sh flood                  10x the rate for 3 minutes, then back
#   ./scripts/chaos.sh break-labels           make Alloy label by trace_id (exercise 7)
#   ./scripts/chaos.sh fix-labels             undo it
#   ./scripts/chaos.sh reset                  back to the healthy baseline

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

NS="demo"
LOG_NS="logging"
DEPLOY="batch-worker"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,13p' "$0"; }

_set_env() {
  kubectl -n "$NS" set env "deploy/${DEPLOY}" "$@"
  kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=2m
}

cmd_status() {
  log "batch-worker environment"
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}' \
    2>/dev/null || true
  echo
  log "pods"
  kubectl -n "$NS" get pods -l app.kubernetes.io/name="$DEPLOY" --no-headers 2>/dev/null || true
  echo
  log "alloy config: is trace_id a label?"
  # Match the stage.labels line specifically. `trace_id = "trace_id"` on its
  # own also appears in stage.structured_metadata, which is there in the
  # HEALTHY config too - matching that would report ARMED permanently.
  if kubectl -n "$LOG_NS" get cm alloy -o jsonpath='{.data.config\.alloy}' 2>/dev/null \
      | grep -qF 'values = { level = "level", trace_id = "trace_id" }'; then
    warn "trace_id IS a stream label - the cardinality bomb is ARMED"
  else
    echo "trace_id is structured metadata (healthy)"
  fi
}

cmd_level() {
  local lvl="${1:-}"
  [[ "$lvl" =~ ^[0-3]$ ]] || die "level must be 0, 1, 2 or 3"
  log "setting CHAOS_LEVEL=${lvl}"
  _set_env "CHAOS_LEVEL=${lvl}"
  case "$lvl" in
    0) echo "baseline: billing degrades on its own 20-minute cycle, others ~5%" ;;
    1) echo "~13% base failure rate, up to 4 retries" ;;
    2) echo "~21% base failure rate, up to 5 retries" ;;
    3) echo "~29% base failure rate, up to 6 retries - stack traces get common" ;;
  esac
}

cmd_rate() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "rate must be a whole number of lines/sec"
  log "setting LOG_RATE=${n} per pod"
  _set_env "LOG_RATE=${n}"
}

cmd_noise() {
  local r="${1:-}"
  [[ "$r" =~ ^0?\.[0-9]+$|^[01]$ ]] || die "noise must be between 0.0 and 1.0"
  log "setting NOISE_RATIO=${r}"
  _set_env "NOISE_RATIO=${r}"
}

cmd_malformed() {
  local r="${1:-}"
  [[ "$r" =~ ^0?\.[0-9]+$|^[01]$ ]] || die "malformed must be between 0.0 and 1.0"
  log "setting MALFORMED_RATIO=${r}"
  _set_env "MALFORMED_RATIO=${r}"
}

cmd_flood() {
  log "flooding: LOG_RATE=80 per pod for 3 minutes"
  _set_env "LOG_RATE=80"
  cat <<'EOF'

Flooding now. While it runs, watch what happens to:

  - ingest volume:   logcli --addr=http://loki:3100 volume '{namespace="demo"}'
  - Loki's own view: sum(rate(loki_distributor_bytes_received_total[1m]))
                     in Prometheus, NOT in Loki
  - your query cost: re-run any query from exercise 4 and compare --stats

EOF
  sleep 180
  log "restoring LOG_RATE=8"
  _set_env "LOG_RATE=8"
}

cmd_break_labels() {
  # THE CARDINALITY BOMB, log edition. Moves trace_id from structured
  # metadata to a stream label. demoapp emits a unique trace_id per request,
  # so this creates one Loki stream PER REQUEST.
  log "patching Alloy to make trace_id a stream LABEL"
  local cfg
  cfg="$(kubectl -n "$LOG_NS" get cm alloy -o jsonpath='{.data.config\.alloy}')"
  [[ -n "$cfg" ]] || die "could not read the alloy ConfigMap"

  if grep -qF 'values = { level = "level", trace_id = "trace_id" }' <<<"$cfg"; then
    warn "already armed"
    return 0
  fi

  # Add trace_id to stage.labels, leaving structured_metadata in place so the
  # only difference is the label.
  local patched
  patched="$(sed 's/values = { level = "level" }/values = { level = "level", trace_id = "trace_id" }/' <<<"$cfg")"

  kubectl -n "$LOG_NS" create configmap alloy \
    --from-literal=config.alloy="$patched" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log "restarting alloy to pick it up"
  kubectl -n "$LOG_NS" rollout restart daemonset/alloy
  kubectl -n "$LOG_NS" rollout status daemonset/alloy --timeout=2m

  cat <<'EOF'

ARMED. trace_id is now a stream label.

Give it 3-4 minutes, then measure the damage. The point is that NOTHING
breaks loudly - queries just get slower and Loki's memory climbs:

  # stream count, before vs after
  curl -sG http://loki:3100/loki/api/v1/series \
    --data-urlencode 'match[]={app="demoapp"}' | jq '.data | length'

  # Loki's own opinion
  curl -s http://loki:3100/metrics | grep loki_ingester_memory_streams

Undo with: ./scripts/chaos.sh fix-labels
EOF
}

cmd_fix_labels() {
  log "restoring the Alloy config from helm/alloy.values.yaml"
  command -v helm >/dev/null || die "helm not found - run this on the lab host"
  helm upgrade --install alloy grafana/alloy \
    --namespace "$LOG_NS" \
    --values "${ROOT_DIR}/helm/alloy.values.yaml" \
    --wait --timeout 5m
  kubectl -n "$LOG_NS" rollout restart daemonset/alloy
  kubectl -n "$LOG_NS" rollout status daemonset/alloy --timeout=2m

  cat <<'EOF'

Restored. Note what did NOT happen: the streams you already created are still
in the index until they age out of retention. You cannot un-ring that bell -
you can only stop ringing it. That is the actual lesson.
EOF
}

cmd_reset() {
  log "restoring batch-worker defaults"
  _set_env "CHAOS_LEVEL=0" "LOG_RATE=8" "NOISE_RATIO=0.55" "MALFORMED_RATIO=0.02"
  cmd_fix_labels
}

case "${1:-}" in
  status)       shift; cmd_status "$@" ;;
  level)        shift; cmd_level "$@" ;;
  rate)         shift; cmd_rate "$@" ;;
  noise)        shift; cmd_noise "$@" ;;
  malformed)    shift; cmd_malformed "$@" ;;
  flood)        shift; cmd_flood "$@" ;;
  break-labels) shift; cmd_break_labels "$@" ;;
  fix-labels)   shift; cmd_fix_labels "$@" ;;
  reset)        shift; cmd_reset "$@" ;;
  *)            usage; exit 1 ;;
esac
