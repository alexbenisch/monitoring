# monitoring

Observability lab — self-contained scenarios, each building on the last.

| Scenario | Topic | Status |
|---|---|---|
| [01 — Metrics](scenario-01-metrics/README.md) | Prometheus, the Operator, Grafana, an instrumented FastAPI app on minikube | ready |
| [02 — Logs](scenario-02-logs/README.md) | Loki, Alloy, LogQL, and querying it from Python | ready |
| 03 | OpenTelemetry traces, Tempo, exemplars | planned |
| 04 | Argo CD owns this repo; break things by pushing commits | planned |

Later scenarios reuse the Grafana and the demo app from scenario 01. Scenario
02 bumps that app to 1.1.0, which adds structured logging and changes nothing
else, so scenario 01 behaves identically either way.

## Infrastructure

[`infra/`](infra/README.md) — Terraform for the Hetzner lab host and its
Cloudflare DNS (`app.kubetest.uk`, `monitoring.kubetest.uk`), applied from
GitHub Actions only. Plans appear on PRs; applies and destroys are manual
`workflow_dispatch` runs. The `hcloud` workflow answers what is orderable and
what is running.

[REFERENCES.md](REFERENCES.md) — upstream repos and tutorials to steal from.
