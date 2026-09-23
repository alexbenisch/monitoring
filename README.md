# monitoring

Observability lab — self-contained scenarios, each building on the last.

| Scenario | Topic | Status |
|---|---|---|
| [01 — Metrics](scenario-01-metrics/README.md) | Prometheus, the Operator, Grafana, an instrumented FastAPI app on minikube | ready |
| [02 — Logs](scenario-02-logs/README.md) | Loki, Alloy, LogQL, and querying it from Python | ready |
| 03 | OpenTelemetry traces, Tempo, exemplars | planned |
| 04 | Argo CD owns this repo; break things by pushing commits | planned |
| [05 — Jenkins CI/CD](scenario-05-jenkins/PLAN.md) | Jenkins on Kubernetes, ephemeral agents, Kaniko, for a small Spring Boot app | in progress |

Later scenarios reuse the Grafana and the demo app from scenario 01. Scenario
02 bumps that app to 1.1.0, which adds structured logging and changes nothing
else, so scenario 01 behaves identically either way.

Scenario 05 is numbered out of order on purpose: it was pulled forward ahead
of the planned 03 and 04, and renaming the directory later costs nothing.

## The lab host

One Hetzner server, `obs-lab`, running minikube. Sized `cpx42` (8 vCPU /
16 GB) since 2026-09-23 — scenario 05 adds a Jenkins controller and a build
agent per build, which did not fit in the previous 8 GB.

Note the ceiling that actually applies is minikube's, not the server's. The
node container is capped at **13312 MiB**, while the kubelet advertises the
host's full RAM because it reads `/proc/meminfo`, which is not namespaced.
The scheduler therefore plans against a number the runtime does not enforce.
`scenario-01-metrics/scripts/00-bootstrap.sh` carries the details.

Services reachable on the tailnet when it is up: `grafana`, `prometheus`,
`alertmanager`, `loki`, `demoapp`, `hello-java`.

**The host is destroyed when not in use**, since Hetzner bills a server for
existing rather than for running — stopping it saves nothing. State lives in a
snapshot, and `var.image` is pinned to it, so coming back is one command:

```bash
gh workflow run terraform.yml -f action=apply
```

Expect new IP addresses (the DNS records follow) and read `bd show obs-1du`
first — stale Tailscale devices will steal the hostnames back otherwise.

## Open work

Tracked in [beads](https://github.com/steveyegge/beads) (`bd`), not in this
file:

```bash
bd ready          # what is unblocked right now
bd list           # everything still open
bd show obs-m23   # one issue
```

## Infrastructure

[`infra/`](infra/README.md) — Terraform for the Hetzner lab host and its
Cloudflare DNS (`app.kubetest.uk`, `monitoring.kubetest.uk`), applied from
GitHub Actions only. Plans appear on PRs; applies and destroys are manual
`workflow_dispatch` runs. The `hcloud` workflow answers what is orderable and
what is running.

[REFERENCES.md](REFERENCES.md) — upstream repos and tutorials to steal from.
