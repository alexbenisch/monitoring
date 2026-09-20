# Scenario 01 — Metrics: Prometheus, the Operator, and Grafana

The foundation scenario. Everything later (Loki, OTel, Fluent Bit, Jenkins, Argo CD)
plugs into the Grafana and the demo app you build here.

**Time:** ~2–3 hours for the exercises, ~15 min for the bootstrap.

---

## What you should be able to do afterwards

- Explain the full discovery chain: `Pod → Service → ServiceMonitor → Prometheus CR`,
  and debug it when a target silently goes missing.
- Write RED (Rate/Errors/Duration) queries from scratch, without copying a dashboard.
- Explain what `rate()` actually computes and why `rate(x[5m])` on a 15s scrape is not
  "the last 5 minutes of traffic".
- Use `histogram_quantile` correctly — including the aggregation order that everyone
  gets wrong the first time.
- Detect, quantify and mitigate a cardinality explosion.
- Write recording rules and alerting rules, and say why an alert should use the former.
- Right-size CPU/memory requests from measurements instead of vibes.

---

## Prerequisites

On the vserver:

| Tool | Minimum | Check |
|---|---|---|
| Docker | 24 | `docker version` |
| minikube | 1.33 | `minikube version` |
| kubectl | 1.29 | `kubectl version --client` |
| helm | 3.14 | `helm version` |

Resources: **4 vCPU / 6 GB RAM / 20 GB disk** free. The stack is not tiny — Prometheus
alone asks for 700 MB. If you have less, drop `--cpus`/`--memory` and reduce
`prometheus.prometheusSpec.retention` in the values file.

```bash
chmod +x scripts/*.sh
```

---

## Quick start

```bash
./scripts/00-bootstrap.sh        # minikube + kube-prometheus-stack (~10 min)
./scripts/10-deploy-app.sh       # build image, apply manifests, start load
./scripts/30-tailscale.sh        # put the UIs on your tailnet (one-time)
```

### Access

`30-tailscale.sh` installs the Tailscale Kubernetes operator, which gives each
Service its own address on your tailnet. From any machine on the tailnet:

| | |
|---|---|
| Grafana | <http://grafana.YOUR-TAILNET.ts.net> |
| Prometheus | <http://prometheus.YOUR-TAILNET.ts.net:9090> |
| Alertmanager | <http://alertmanager.YOUR-TAILNET.ts.net:9093> |

Only Grafana works on the bare hostname: the operator proxies each Service's
own port, and Grafana's Service listens on 80 while the other two are on 9090
and 9093. `tailscale status` lists your exact names.

Grafana is **admin / `obslab`**, though anonymous browsing is enabled so the
dashboards open without logging in. Find **obs-lab / demoapp RED**.

`kubectl` works from your workstation too, through the operator's API server
proxy - no kubeconfig copying, no tunnel:

```bash
tailscale configure kubeconfig tailscale-operator.YOUR-TAILNET.ts.net
kubectl --context=tailscale-operator.YOUR-TAILNET.ts.net -n demo get pods
```

That command sets the new context as *current*, so check
`kubectl config current-context` before running anything destructive against
what you assume is a different cluster.

<details>
<summary>Fallback: port-forward and an SSH tunnel</summary>

Still works, and needs no tailnet, but both halves are fragile - `kubectl
port-forward` dies with its target Pod, and a second `ssh -L` silently fails to
bind ports the first one already holds:

```bash
./scripts/port-forward.sh        # on the host: Grafana :3000, Prom :9090, AM :9093

# from your workstation, in a separate terminal
ssh -o ExitOnForwardFailure=yes \
    -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 user@vserver
```

`ExitOnForwardFailure=yes` turns a half-bound tunnel into a refused connection
instead of a session where some ports work and others reset.

</details>

Reset to a clean baseline at any point:

```bash
./scripts/chaos.sh reset
```

---

## What's running

```
                   ┌──────────────────────── namespace: demo ───────────────────────┐
                   │                                                                │
   loadgen ×3 ───► │  Service/demoapp ──► Deployment/demoapp ×2                     │
   (curl loop)     │       :8000                 └── GET /metrics                    │
                   │          ▲                                                     │
                   │          │ selects on labels                                   │
                   │  ServiceMonitor/demoapp ──┐   PrometheusRule/demoapp-rules ──┐  │
                   └───────────────────────────│───────────────────────────────── │──┘
                                               │ release=kube-prom-stack          │
                   ┌───────────────── namespace: monitoring ─────────────────────┐ │
                   │                           ▼                                 │ │
                   │  Prometheus Operator ──► Prometheus CR ◄────────────────────────┘
                   │                            │  scrapes every 15s              │
                   │                            ├──► Alertmanager                 │
                   │                            └──► Grafana (dashboard from a    │
                   │                                  labelled ConfigMap)         │
                   └─────────────────────────────────────────────────────────────┘
```

The demo app exposes four routes with deliberately different personalities:

| Route | Behaviour |
|---|---|
| `GET /api/items` | fast and healthy, ~30 ms — your control group |
| `GET /api/search` | **bimodal**: 88% at ~60 ms, 12% between 0.8 s and 2.5 s |
| `POST /api/checkout` | ~8% `500`s at baseline, scales with `CHAOS_LEVEL` |
| `GET /api/report` | carries the cardinality trap |

---

## Concepts you need before exercise 2

**The four metric types.** `Counter` only goes up (and resets to 0 on restart —
`rate()` handles that). `Gauge` goes up and down. `Histogram` buckets observations
into cumulative `_bucket{le="..."}` series plus `_sum` and `_count`. `Summary`
computes quantiles client-side and **cannot be aggregated across instances** — which
is why this lab uses histograms everywhere.

**`rate()` is a per-second average, not a total.** `rate(http_requests_total[5m])`
takes the first and last sample in each 5-minute window, divides the increase by the
time between them, and returns requests *per second*. The window needs at least four
scrape intervals to be stable — with a 15s scrape, `[1m]` is the floor and `[5m]` is
a sane default. Use `irate()` only for fast-moving graphs you're staring at live;
never in an alert.

**Every label value combination is a separate time series.** That is the entire
cost model of Prometheus. `route` has 4 values: fine. `request_id` has one value per
request: not fine. Exercise 5.

**Selectors are silent.** If a `ServiceMonitor` label doesn't match what the
Prometheus CR selects, nothing errors — the target just never appears. This is the
single most common "Prometheus is broken" ticket.

---

## Exercise 1 — The discovery chain

**Goal:** understand why your target is scraped, by breaking it on purpose.

1. Open Prometheus → **Status → Target health**. Find `serviceMonitor/demo/demoapp/0`.
   You should see 2 targets `UP`.
2. Look at **Status → Configuration** and find the generated `job_name` for it.
   Note that you never wrote that scrape config — the Operator generated it.
3. Break it:
   ```bash
   ./scripts/chaos.sh break-scrape
   ```
4. Wait ~60 s. Watch the target disappear from `/targets`. Now go hunting:
   - Does `kubectl -n demo get servicemonitor` still show the object? (Yes.)
   - Does the Operator log an error?
     `kubectl -n monitoring logs deploy/kube-prom-stack-operator --tail=50`
   - Does Prometheus log an error?
5. In Grafana, look at the RED dashboard. **What does the error-ratio panel show
   during the outage?** This is the point of the exercise.
6. Fix it: `./scripts/chaos.sh fix-scrape`

<details>
<summary><b>Discussion</b></summary>

Nothing logged an error, anywhere. The `ServiceMonitor` still exists and looks
perfectly healthy. Prometheus simply never selected it, so there was never a target
to report as down.

The error-ratio panel goes **blank**, not red. `sum(rate(...5xx...)) / sum(rate(...))`
over no data returns no data. An operator glancing at the dashboard sees "no errors"
— which is indistinguishable from "no traffic" and from "monitoring is broken".

That's why `DemoAppAbsent` exists in `prometheusrule.yaml`:

```promql
absent(up{job="demoapp"} == 1)
```

`absent()` returns `1` when its argument produces no series — the only way to alert
on the absence of data. Every service you monitor needs one of these, or an
equivalent dead-man's-switch. kube-prometheus-stack ships one for itself: the
`Watchdog` alert that fires permanently, so you can alert on *it* going quiet.

The selector chain, top to bottom:

```
Prometheus CR .spec.serviceMonitorSelector      → matchLabels: release=kube-prom-stack
  ServiceMonitor .metadata.labels                 must contain that
  ServiceMonitor .spec.selector.matchLabels      → matches SERVICE labels (not pod labels)
  ServiceMonitor .spec.endpoints[].port          → the Service port NAME
    Service .spec.selector                       → matches POD labels
```

Four places to get it wrong. Check them in that order.
</details>

---

## Exercise 2 — Write the RED queries yourself

**Goal:** produce the three golden-signal queries without looking at the dashboard JSON.

In the Prometheus UI (`/graph`), write PromQL for:

1. Requests per second, broken down by route.
2. The **ratio** of 5xx responses to all responses, per route.
3. The 99th percentile latency, per route.
4. Bonus: requests per second by route **and** pod, then explain why you'd rarely
   want that on a dashboard.

Then check `k8s/prometheusrule.yaml` — the recording rules there are the answers.

<details>
<summary><b>Solutions</b></summary>

```promql
# 1. Rate by route
sum by (route) (rate(demoapp_http_requests_total[5m]))

# 2. Error RATIO by route. Note both sides aggregate by the same label set,
#    otherwise the division finds no matching series and returns empty.
sum by (route) (rate(demoapp_http_requests_total{status=~"5.."}[5m]))
/
sum by (route) (rate(demoapp_http_requests_total[5m]))

# 3. p99 by route — read the aggregation carefully, exercise 4 is about this
histogram_quantile(
  0.99,
  sum by (route, le) (rate(demoapp_http_request_duration_seconds_bucket[5m]))
)

# 4. By route and pod
sum by (route, pod) (rate(demoapp_http_requests_total[5m]))
```

Why not graph by pod: with 2 replicas × 4 routes you get 8 series; at 50 replicas you
get 200 and the graph is unreadable. Per-pod breakdown is for *drilling in* after an
aggregate signal tells you something is wrong, not for the overview. The same logic
applies to alerts — alert on the service, then use labels to find the pod.

Gotcha to notice in #2: if you write `sum(rate(...5xx...)) by (route) / sum(rate(...))`
without `by (route)` on the denominator, PromQL cannot match the vectors and returns
nothing. Empty result ≠ zero errors.
</details>

---

## Exercise 3 — Make an alert fire, end to end

**Goal:** follow one alert from rule evaluation to Alertmanager.

1. `./scripts/chaos.sh level 2` (≈32% errors on `/api/checkout`).
2. Prometheus → **Alerts**. Watch `DemoAppHighErrorRate` go `Inactive → Pending → Firing`.
   Time how long `Pending` lasts and reconcile it with the rule.
3. Open Alertmanager (`:9093`). Find the alert. Look at how it was grouped.
4. Silence it from the Alertmanager UI, then check that Prometheus still shows it
   firing. Explain the difference.
5. `./scripts/chaos.sh reset` and watch it resolve.

<details>
<summary><b>Answers</b></summary>

**Pending lasts 2 minutes** — the rule's `for: 2m`. `for` is the anti-flap mechanism:
the condition must hold continuously for that long. Note the total detection delay is
`rate() window ramp-up + evaluation interval + for`, so roughly 2.5–3 minutes here.
Shortening `for` makes you faster and noisier; that trade is the entire craft of
alerting.

**Grouping:** the Alertmanager config groups by `["alertname", "namespace"]`, so if
two routes breached at once you'd get one notification, not two. `group_wait: 10s`
holds the first notification briefly to collect siblings.

**Silence vs. alert state:** a silence lives entirely in Alertmanager. Prometheus
keeps evaluating and keeps showing the alert as firing; Alertmanager just suppresses
the *notification*. This matters operationally — a silenced alert is still an
unresolved problem, and silences expire. Compare with `inhibit_rules`, which suppress
one alert because another is firing (e.g. don't page about high latency when the
whole cluster is down).

Worth noticing: the alert expression uses the recording rule
`route:demoapp_error_ratio:rate5m`, not the raw expression. Alert rules are evaluated
constantly; keeping them cheap is what stops your Prometheus from falling over when
you have 400 of them.
</details>

---

## Exercise 4 — Histograms, and the aggregation order that ruins them

**Goal:** understand `histogram_quantile` well enough to spot a broken dashboard.

1. Look at the **Latency distribution** heatmap with `route=/api/search`. You should
   see two distinct bands. Now look at the quantile panel. p50 sits in the lower band,
   p99 in the upper.
2. Run these two queries side by side over the last 30 minutes:

   ```promql
   # A - aggregate the buckets, then compute the quantile  (correct)
   histogram_quantile(0.99,
     sum by (le) (rate(demoapp_http_request_duration_seconds_bucket{route="/api/search"}[5m])))

   # B - compute per-series quantiles, then average them   (wrong)
   avg(histogram_quantile(0.99,
     rate(demoapp_http_request_duration_seconds_bucket{route="/api/search"}[5m])))
   ```
3. Scale up (`./scripts/chaos.sh scale 5`) and compare them again. Does the gap widen?
4. Query `demoapp_http_request_duration_seconds_bucket{route="/api/search"}` directly
   and look at the `le` values. What is the **highest finite bucket**, and what does
   that imply about the p99 you just read?

<details>
<summary><b>Answers</b></summary>

**A vs. B.** Quantiles are not averageable. The mean of each pod's p99 is not the p99
of the whole service — it systematically *understates* it, because a bad pod's tail
gets diluted by good pods. Version B gets worse the more replicas you have, which is
exactly backwards from what you want. **Always `sum by (le)` first, then
`histogram_quantile`.** If you remember one thing from this exercise, that is it.

**Bucket resolution.** The buckets are
`0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5 10 +Inf`. `histogram_quantile` does linear
interpolation *within* the bucket the quantile falls into. The cold path on
`/api/search` runs 0.8–2.5 s, which lands in the `le="2.5"` bucket — a bucket 1.5 s
wide. So your "p99 = 2.1s" is really "p99 is somewhere between 1 s and 2.5 s, and the
interpolation guessed 2.1". The number has far fewer significant digits than it looks
like it has.

The practical rule: put bucket boundaries **around your SLO**. If you promise 500 ms,
you want buckets at 0.25/0.4/0.5/0.6/0.75 so you can actually see movement near the
threshold. Buckets are also the cost lever — each one is a time series per label
combination, so 11 buckets × 4 routes × 2 pods = 88 series from this one histogram.

**Native histograms** (Prometheus 2.40+, stable in 3.x) sidestep the bucket-choice
problem with exponential buckets at configurable resolution, stored as a single
series. Worth knowing they exist; classic histograms are still what you'll meet in
most codebases.
</details>

---

## Exercise 5 — The cardinality bomb

**Goal:** detect, quantify, and mitigate a label explosion. This is the failure that
actually takes Prometheus down in production.

1. Note the current baseline:
   ```promql
   prometheus_tsdb_head_series
   count(demoapp_report_requests_total)
   ```
2. Light the fuse: `./scripts/chaos.sh cardinality on`
3. Watch for 5–10 minutes. Traffic to `/api/report` is only ~8% of the load, so this
   is a slow burn rather than an instant kill — which is exactly how it happens in
   real life.
4. Find the culprit **without already knowing the answer**:
   - Prometheus → **Status → TSDB Status**. Read the top series by metric name.
   - `topk(10, count by (__name__)({__name__=~".+"}))`
   - `curl` the cardinality API:
     ```bash
     kubectl -n monitoring exec -it sts/prometheus-kube-prom-stack-prometheus -c prometheus -- \
       wget -qO- 'http://localhost:9090/api/v1/status/tsdb' | head -c 2000
     ```
5. Estimate the damage: at the current rate of new series, how long until you hit
   1 million? Prometheus needs roughly 3–4 KB of RAM per active series.
6. Mitigate at three different layers, and rank them:
   - **a)** `./scripts/chaos.sh cardinality off` — fix the app.
   - **b)** Uncomment the `metricRelabelings` drop rule in
     `k8s/servicemonitor.yaml`, re-apply, and confirm the series stop arriving.
   - **c)** Think about what a `sample_limit` on the ServiceMonitor would do.
7. After turning it off, check `count(demoapp_report_requests_total)` again. Did the
   old series disappear?

<details>
<summary><b>Answers</b></summary>

**Step 7 is the real lesson: no, they don't disappear.** Series that stop receiving
samples remain in the TSDB head block until they fall out of the retention window
(and stale markers only stop them being returned by instant queries after ~5 min).
Memory does not come back when you deploy the fix. On a real incident you are often
looking at a restart, or `POST /api/v1/admin/tsdb/delete_series` with the admin API
enabled. **Cardinality damage is not retroactively undoable** — which is why review
of label sets is a code-review item, not a monitoring-team item.

**Ranking the mitigations:**

- **(a) Fix the app** — the only real fix. The other two are tourniquets.
- **(b) `metricRelabelings` drop** — applied by Prometheus *after* the scrape but
  *before* ingestion. The right emergency lever: it takes effect on config reload,
  needs no app deploy, and you can ship it in minutes. Note the distinction from
  `relabelings` (which act on *target* labels during service discovery, before the
  scrape happens).
  ```yaml
  metricRelabelings:
    - sourceLabels: [__name__]
      regex: demoapp_report_requests_total
      action: drop
  ```
  A surgical alternative that keeps the metric but kills the label:
  ```yaml
    - action: labeldrop
      regex: request_id
  ```
- **(c) `sampleLimit`** — set on the ServiceMonitor, it makes the whole scrape *fail*
  once the target exceeds N samples. It protects Prometheus by sacrificing the target:
  you lose all visibility into that service instead of losing the cluster. A
  reasonable last-resort guardrail, a terrible primary control. Pair it with
  `labelLimit`/`labelValueLengthLimit` for defence in depth.

**The design rule:** a label is only allowed if its value set is bounded and small,
and you would actually group or filter by it. `request_id`, `user_id`, `email`,
`session_id`, raw URL paths with IDs in them, and full error messages are all
disqualified. If you need per-request identity, that's a **log or a trace**, not a
metric — which is precisely what scenarios 2 and 3 are for.
</details>

---

## Exercise 6 — Recording rules and query cost

**Goal:** see what a recording rule buys you.

1. In Prometheus → **Graph**, run the raw p99 expression over `1h`, then over `7d`.
   Note the query time shown under the graph.
2. Run the recording rule `route:demoapp_latency_p99:5m` over the same ranges.
3. Look at `prometheus_rule_group_last_duration_seconds` and
   `prometheus_rule_group_iterations_total` to see what evaluating the rules costs.
4. Add your own recording rule: **error ratio across all routes combined**, named
   following the `level:metric:operations` convention. Apply it and confirm it appears.
5. Why is `route:demoapp_error_ratio:rate5m` safe to alert on, but a rule recording
   `histogram_quantile(0.99, ...)` is subtly dangerous to *re-aggregate* later?

<details>
<summary><b>Answers</b></summary>

**Step 4** — add to `k8s/prometheusrule.yaml` under `demoapp.rules`:

```yaml
- record: service:demoapp_error_ratio:rate5m
  expr: |
    sum(rate(demoapp_http_requests_total{status=~"5.."}[5m]))
    /
    sum(rate(demoapp_http_requests_total[5m]))
```

Then `kubectl apply -k k8s/`. The Operator reloads Prometheus within ~60s; check
Prometheus → **Status → Rules**. Note the naming convention
`level:metric:operations` — `level` is the aggregation level (`service`, `route`,
`instance`), `operations` is what was applied (`rate5m`, `sum`). Underscores inside
each part, colons only as separators. Colons are reserved for recording rules by
convention precisely so you can tell at a glance whether a metric came from an
exporter or from your own rules.

**Step 5** — a recorded *ratio* is still a ratio: you cannot average it across routes
to get the service-wide ratio unless the routes have equal traffic. A recorded
*quantile* is worse: it's already collapsed, so there is no valid way to combine
`route:demoapp_latency_p99:5m` values back into a global p99. If you need both, record
the aggregated **buckets** (`sum by (le)(rate(..._bucket[5m]))`) and apply
`histogram_quantile` at query time — that composes correctly at any level.

Rule of thumb: record things that are *additive* (counters, sums, bucket rates).
Compute the non-additive things (ratios, quantiles, averages) at the last moment.
</details>

---

## Exercise 7 — Right-size the deployment from metrics (USE)

**Goal:** replace guessed resource values with measured ones. RED looks at the
service from outside; **USE** (Utilization, Saturation, Errors) looks at the resources
from inside.

The manifest currently asks for `cpu: 50m / memory: 96Mi` and limits at
`300m / 192Mi`. Those numbers were made up. Prove them right or wrong.

1. Measure actual usage over a 30-minute window under load:

   ```promql
   # CPU cores actually used, per pod
   sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="demo", container="demoapp"}[5m]))

   # Working set memory
   sum by (pod) (container_memory_working_set_bytes{namespace="demo", container="demoapp"})
   ```
2. Check whether the CPU limit is being hit:
   ```promql
   sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="demo", container="demoapp"}[5m]))
   /
   sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="demo", container="demoapp"}[5m]))
   ```
3. Run `./scripts/chaos.sh scale 6` and repeat under contention.
4. Propose new requests/limits and justify each number.
5. Correlate: does the throttle ratio line up with any movement in
   `route:demoapp_latency_p99:5m`?

<details>
<summary><b>Answers and the reasoning</b></summary>

**Requests** should sit near the p95 of observed usage — they're what the scheduler
uses to place the pod and what protects you from noisy neighbours. Use
`quantile_over_time(0.95, ...[30m])` rather than the max, so one spike doesn't reserve
capacity forever.

**Memory limit** should be comfortably above observed working set (30–50% headroom).
Memory is *incompressible*: exceeding the limit means OOMKill, not slowdown. Many
teams set memory request == limit for exactly this reason (Guaranteed QoS class).

**CPU limits are the controversial one.** CPU is compressible — exceeding the limit
means CFS throttling, which shows up as latency, not as a crash. That's what step 2
measures, and a throttle ratio above ~5% while latency degrades is your evidence.
A defensible position, common in production: **set CPU requests, omit CPU limits**,
and rely on requests plus cluster autoscaling for fairness. The counter-argument is
predictability and noisy-neighbour protection in multi-tenant clusters. Know both
arguments; the answer depends on the cluster, not on a blog post.

**The correlation in step 5 is the real skill.** Throttling is a *cause* metric;
latency is a *symptom* metric. Being able to say "p99 rose at 14:32, throttling rose
at 14:31, here are both graphs" is the difference between an incident report and a
guess. Note that `container_cpu_*` comes from cAdvisor and
`kube_pod_container_resource_*` from kube-state-metrics — two different exporters,
joined at query time by the `pod` label. That join is why label consistency across
exporters matters so much.
</details>

---

## Troubleshooting

**Target missing from `/targets`.** Walk the chain from exercise 1 in order. The
quickest check:
```bash
kubectl -n demo get servicemonitor demoapp -o yaml | grep -A3 'labels:'
kubectl -n demo get endpoints demoapp          # empty = the Service selector is wrong
```

**Dashboard not in Grafana.** The sidecar needs the ConfigMap label:
```bash
kubectl -n demo get cm -l grafana_dashboard=1
kubectl -n monitoring logs deploy/kube-prom-stack-grafana -c grafana-sc-dashboard --tail=30
```
Invalid JSON is dropped with a log line and no UI feedback.

**Pods `ImagePullBackOff`.** The image lives only inside the minikube node.
Re-run `minikube image load obs-lab/demoapp:1.0.0 -p obs-lab`, and confirm
`imagePullPolicy: IfNotPresent`.

**Prometheus OOMKilled.** Lower `retention`, or you left exercise 5 running. Check
`prometheus_tsdb_head_series`.

**`minikube start` fails on the vserver.** With the `docker` driver, your user needs
to be in the `docker` group. Nested virtualisation is a common vserver limitation —
stick to `--driver=docker`.

**Nothing is reachable after a reboot.** minikube creates its node container
with `RestartPolicy=no`, so a restart leaves it `Exited(137)`: Docker comes
back, the cluster does not, and the tailnet names go with it. The
`minikube.service` unit in `infra/files/` fixes this permanently —
`systemctl status minikube` on the host says whether it ran.

**Tailnet hostname does not resolve or times out.** Check the device is
actually up (`tailscale status | grep grafana`), then that you used the right
port — only Grafana answers on the bare hostname; Prometheus needs `:9090` and
Alertmanager `:9093`. A *first* request can also time out while Tailscale
issues the TLS certificate; retry once.

**`kubectl` says Forbidden through the API server proxy.** The proxy
impersonates your tailnet identity, so Kubernetes needs to know who that is.
`kubectl auth whoami` shows the groups you actually have; if it lists only
`system:authenticated`, the grant is missing or in the wrong place. `grants` is
a **top-level** key in the Tailscale policy file, a sibling of `acls` — nested
inside `acls` it parses fine and does nothing.

**`kubectl` connection refused right after restarting the operator.** The API
server proxy runs in-process in the operator, so restarting it removes the path
you are using. It returns on its own; keep SSH available before you restart it.

**Rule changes not taking effect.** The Operator reloads config on a timer.
`kubectl -n monitoring logs sts/prometheus-kube-prom-stack-prometheus -c config-reloader`
shows when it last happened.

---

## Cleanup

```bash
./scripts/99-teardown.sh          # just the app
./scripts/99-teardown.sh --stack  # also the monitoring stack + CRDs
./scripts/99-teardown.sh --all    # nuke the minikube profile
```

Keep the cluster if you're going straight to scenario 2 — it reuses this Grafana.

---

## Files

```
scenario-01-metrics/
├── app/                    demo service (FastAPI + prometheus_client)
├── helm/                   kube-prometheus-stack values, commented
├── k8s/
│   ├── deployment.yaml     resources deliberately unproven (exercise 7)
│   ├── service.yaml        named port - the ServiceMonitor depends on it
│   ├── servicemonitor.yaml release label + the metricRelabelings slot (exercise 5)
│   ├── prometheusrule.yaml recording rules + 3 alerts
│   ├── loadgen.yaml        weighted traffic generator
│   └── dashboards/         RED dashboard, loaded via labelled ConfigMap
└── scripts/                bootstrap, deploy, tailscale, chaos, port-forward, teardown
```

---

## Before scenario 2

Note what was *annoying* here — those gaps drive the next scenarios:

- When the error ratio spiked, you had no way to see **why** a given request failed.
  → Scenario 2: **Loki + Promtail/Fluent Bit**, and `demoapp` grows structured logs
  with a trace ID.
- You couldn't tell whether a slow `/api/search` was slow in the app or downstream.
  → Scenario 3: **OpenTelemetry** traces, Tempo, and exemplars linking the p99 panel
  straight to a trace.
- Everything here was applied with `kubectl apply -k` by hand.
  → Scenario 4: **Argo CD** owns this repo, and you break things by pushing commits
  instead of running scripts. The kustomize layout is already Argo-shaped.

Tell me which of those you want next, or if Jenkins should come earlier — a
CI pipeline that builds this image and lets Argo deploy it is a reasonable scenario 2
if the Jenkins responsibility at work is more urgent than the logging one.
