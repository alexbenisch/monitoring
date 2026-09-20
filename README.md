# monitoring

Observability lab — self-contained scenarios, each building on the last.

| Scenario | Topic | Status |
|---|---|---|
| [01 — Metrics](scenario-01-metrics/README.md) | Prometheus, the Operator, Grafana, an instrumented FastAPI app on minikube | ready |
| 02 | Loki + log collection (Fluent Bit or Alloy) — *or* Jenkins + Argo CD | undecided |
| 03 | OpenTelemetry traces, Tempo, exemplars | planned |
| 04 | Argo CD owns this repo; break things by pushing commits | planned |

Later scenarios reuse the Grafana and the demo app from scenario 01.

[REFERENCES.md](REFERENCES.md) — upstream repos and tutorials to steal from.
