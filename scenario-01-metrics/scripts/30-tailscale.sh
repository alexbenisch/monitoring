#!/usr/bin/env bash
#
# Put Grafana, Prometheus and Alertmanager on the tailnet, and retire
# `kubectl port-forward` + `ssh -L` entirely.
#
# The Tailscale Kubernetes operator watches Services carrying
# `tailscale.com/expose: "true"` and runs a small proxy Pod for each. The
# resulting address follows the *Service*, so it survives Pod restarts - which
# is exactly what port-forward does not.
#
# Credentials: an OAuth client, NOT an auth key. Supply them either as
# environment variables or in a file (mode 600):
#
#   ~/.config/obs-lab/ts-oauth.env
#     TS_OAUTH_CLIENT_ID=...
#     TS_OAUTH_CLIENT_SECRET=...
#
# Prerequisites in the Tailscale admin console, both one-time:
#   1. Policy file: give the operator its tags
#        "tagOwners": {
#          "tag:k8s-operator": [],
#          "tag:k8s":          ["tag:k8s-operator"],
#        }
#   2. An OAuth client with *write* scope on "Devices Core" and "Auth Keys",
#      tagged tag:k8s-operator.
#   3. To use kubectl over the tailnet, a grant letting you reach the API
#      server proxy. The proxy impersonates your tailnet identity, so without
#      this every request is denied by RBAC:
#        "grants": [{
#          "src": ["autogroup:member"],
#          "dst": ["tag:k8s-operator"],
#          "app": {"tailscale.com/cap/kubernetes": [
#            {"impersonate": {"groups": ["system:masters"]}}
#          ]},
#        }]
# MagicDNS must be on (it is by default), and HTTPS certificates enabled if
# you want https:// rather than http:// on the ts.net names.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

NS="tailscale"
MON_NS="monitoring"
RELEASE="kube-prom-stack"
CHART_VERSION="${TS_CHART_VERSION:-1.102.4}"
ENV_FILE="${TS_ENV_FILE:-$HOME/.config/obs-lab/ts-oauth.env}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- credentials --------------------------------------------------------
if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
  if [[ -r "$ENV_FILE" ]]; then
    log "reading OAuth client from ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
  fi
fi

[[ -n "${TS_OAUTH_CLIENT_ID:-}" ]]     || die "TS_OAUTH_CLIENT_ID is not set (env or ${ENV_FILE})"
[[ -n "${TS_OAUTH_CLIENT_SECRET:-}" ]] || die "TS_OAUTH_CLIENT_SECRET is not set (env or ${ENV_FILE})"

# An auth key in place of an OAuth client is the most common mistake here, and
# the operator's failure mode is an unhelpful auth loop.
if [[ "${TS_OAUTH_CLIENT_SECRET}" == tskey-auth-* ]]; then
  die "that is an auth key, not an OAuth client secret. The operator needs an OAuth client (secret starts with tskey-client-)."
fi

# --- operator -----------------------------------------------------------
log "adding the tailscale helm repo"
helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null 2>&1 || true
helm repo update tailscale >/dev/null

# The OAuth client goes into the Secret directly, never through --set.
#
# Passing it as a Helm value writes it into the release history, where it sits
# in plaintext in sh.helm.release.v1.* and is printed by any `helm get values`.
# The chart only renders its own oauth Secret when oauth.clientId is set, so
# leaving that empty and supplying the Secret ourselves keeps the credential
# out of Helm entirely.
log "creating the operator OAuth secret in ${NS}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic operator-oauth \
  --from-literal=client_id="$TS_OAUTH_CLIENT_ID" \
  --from-literal=client_secret="$TS_OAUTH_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Helm would delete this Secret as a "removed resource" on the next upgrade,
# because it is not in the rendered manifest. This annotation stops that.
kubectl -n "$NS" annotate secret operator-oauth helm.sh/resource-policy=keep --overwrite >/dev/null

log "installing the tailscale operator (chart ${CHART_VERSION}) into ${NS}"
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace "$NS" \
  --version "$CHART_VERSION" \
  --set-string apiServerProxyConfig.mode="true" \
  --set-string apiServerProxyConfig.allowImpersonation="true" \
  --wait --timeout 5m

kubectl -n "$NS" rollout status deploy/operator --timeout=3m

# --- expose the services ------------------------------------------------
# The annotations live in the values file so a later `helm upgrade` cannot
# quietly drop them, which is what would happen if we patched the Services
# directly.
log "re-applying ${RELEASE} so the Service annotations take effect"
helm upgrade "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$MON_NS" \
  --values "${ROOT_DIR}/helm/kube-prometheus-stack.values.yaml" \
  --reuse-values \
  --wait --timeout 10m

# --- report -------------------------------------------------------------
log "waiting for the operator to register the proxies (up to 90s)"
for _ in $(seq 1 18); do
  ready="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c Running || true)"
  [[ "${ready:-0}" -ge 4 ]] && break
  sleep 5
done

echo
log "tailnet devices (also visible in the Tailscale admin console):"
kubectl -n "$NS" get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase --no-headers 2>/dev/null | sed 's/^/    /'

cat <<'TXT'

  Once the devices appear in your tailnet, reach them by MagicDNS name from
  any machine on the tailnet - no SSH tunnel, no port-forward:

    grafana.<your-tailnet>.ts.net
    prometheus.<your-tailnet>.ts.net
    alertmanager.<your-tailnet>.ts.net

  `tailscale status` on your workstation lists the exact names.

TXT
