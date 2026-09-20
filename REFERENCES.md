---
title: "Observability Lab — Reference Material"
author: "Alex Benisch"
date: 2026-09-20
geometry: "margin=1.5cm"
papersize: a4
---

# Reference material

Upstream sources to lean on when building the later scenarios. Nothing here is a
dependency of scenario 01 — it is reading and stealing material.

## Grafana Killercoda — Kubernetes Monitoring Helm tutorial

<https://github.com/grafana/killercoda/tree/staging/loki/k8s-monitoring-helm>

Grafana's own interactive tutorial repo (the scenarios published on killercoda.com).
This particular scenario is the closest published thing to our planned **scenario 02
(Loki + log collection)**, and it is a useful counterweight: it deploys **Alloy** via
the `k8s-monitoring` Helm chart rather than Fluent Bit, and it collects *pod logs +
Kubernetes events*, not just application stdout.

Shape of it (`intro.md`, `step1..8.md`, `finish.md`):

| Step | Content |
|---|---|
| 1 | Create the `meta` and `prod` namespaces — collector and workload kept apart |
| 2 | Add the Grafana Helm repo |
| 3 | Deploy Loki, monolithic mode, MinIO as the object store |
| 4 | Deploy Grafana |
| 5 | Deploy the `k8s-monitoring` Helm chart (this is where Alloy comes in) |
| 6 | Access Grafana |
| 7 | (Optional) the Alloy UI — the pipeline graph is worth seeing |
| 8 | Add a sample app to `prod` and watch its logs arrive |

Things to pull from it, and things to deliberately diverge on:

- **Pull:** the three log categories it names up front — pod logs, Kubernetes events,
  node logs. Scenario 02 should cover at least the first two; most homegrown setups
  only ever ship the first and then get surprised.
- **Pull:** the namespace split (`meta` vs `prod`), which makes the collector's own
  RBAC and its own failure modes visible instead of hiding them in `default`.
- **Diverge:** it deploys a *second* Grafana. Ours should reuse the Grafana that
  kube-prometheus-stack already installs in scenario 01 and add Loki as a datasource —
  that is the whole point of building metrics first.
- **Diverge:** monolithic Loki + MinIO is right for a lab but the tutorial says so only
  in passing. Worth making the single-binary/distributed and MinIO/S3 trade-off an
  explicit note rather than a footnote.
- **Note:** `staging` is the working branch of that repo; `main` holds the published
  version. Pin to a commit if we quote it, the content moves.

## Grafana Labs on GitHub

<https://github.com/grafana>

The org itself. The repos that matter for the scenarios we have lined up:

| Repo | Why it's relevant |
|---|---|
| [grafana/loki](https://github.com/grafana/loki) | "Like Prometheus, but for logs." Scenario 02 backend. |
| [grafana/alloy](https://github.com/grafana/alloy) | OTel Collector distribution with programmable pipelines. The modern answer to Promtail/Fluent Bit, and the collector in the tutorial above. |
| [grafana/k8s-monitoring-helm](https://github.com/grafana/k8s-monitoring-helm) | The `k8s-monitoring` chart used in step 5. Read its `values.yaml` — it is a good map of what a complete collection story includes. |
| [grafana/helm-charts](https://github.com/grafana/helm-charts) | The older chart repo: `loki`, `promtail`, `grafana` itself. |
| [grafana/tempo](https://github.com/grafana/tempo) | Tracing backend for scenario 03, and the other half of exemplars. |
| [grafana/mimir](https://github.com/grafana/mimir) | Long-term, multi-tenant Prometheus storage. Relevant once "where does retention go" comes up. |
| [grafana/intro-to-mltp](https://github.com/grafana/intro-to-mltp) | Companion code for Metrics/Logs/Traces/Profiles — a pre-wired demo of exactly the stack these scenarios build up to. Good for cross-checking our datasource and exemplar config. |
| [grafana/beyla](https://github.com/grafana/beyla) | eBPF auto-instrumentation. The "what if you can't touch the app" counterpoint to instrumenting `demoapp` by hand. |
| [grafana/pyroscope](https://github.com/grafana/pyroscope) | Continuous profiling — the P in MLTP, if a later scenario wants it. |
| [grafana/killercoda](https://github.com/grafana/killercoda) | Parent of the tutorial above; other scenarios under `loki/` are worth skimming. |

## Related, not Grafana

- [prometheus-operator/kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) —
  the upstream of the `kube-prometheus-stack` chart scenario 01 installs. The CRD
  reference for `ServiceMonitor`/`PrometheusRule` lives here.
- [prometheus/prometheus](https://github.com/prometheus/prometheus) — in particular
  `documentation/examples/` and the TSDB docs behind exercise 5.
