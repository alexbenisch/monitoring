---
title: "Scenario 02 — Logs: Loki, Alloy and LogQL"
author: "Alex Benisch"
date: 2026-09-21
geometry: "margin=1.5cm"
papersize: a4
---

# Scenario 02 — Logs: Loki, Alloy and LogQL

Scenario 01 gave you metrics: cheap, aggregated, and unable to tell you *which*
request failed or *why*. This scenario is the other half. Loki stores the lines
themselves, Alloy collects them, and LogQL is how you interrogate them.

The central idea, and the one that makes Loki different from Elasticsearch:
**Loki indexes labels, not content.** A query that narrows by labels is cheap.
A query that greps content is a brute-force scan over whatever the labels
selected. Almost every exercise here is a variation on that one fact.

---

## What you should be able to do afterwards

- Read a LogQL query and say what each stage costs.
- Parse JSON, logfmt and arbitrary plaintext at query time, and know which
  parser to reach for.
- Find the lines your parser silently threw away.
- Build RED-style metrics out of nothing but log lines, and explain why that
  is a last resort rather than a design.
- Use `logcli` for the things the Grafana UI is bad at: counting, scripting,
  and measuring query cost.
- Query Loki from Python without falling into the four traps in `lokiq.py`.
- Decide what belongs in a stream label, what belongs in structured metadata,
  and what belongs only in the line — and explain the cost of getting it wrong.

---

## Prerequisites

Scenario 01, deployed and running. This scenario reuses its Grafana (as the
place you look at logs) and its Prometheus (which scrapes Loki and Alloy
themselves). `scripts/10-loki.sh` refuses to run without the `monitoring`
namespace.

On the lab host: `helm`, `docker`, `minikube`, `kubectl`.

On your workstation: `logcli`, and Python 3.11+ with `httpx`.

```bash
# logcli - the Loki CLI. Check the current release rather than pasting a version.
VERSION=3.6.12
curl -fsSL -o /tmp/logcli.zip \
  "https://github.com/grafana/loki/releases/download/v${VERSION}/logcli-linux-amd64.zip"
unzip -o /tmp/logcli.zip -d /tmp
sudo install -m 0755 /tmp/logcli-linux-amd64 /usr/local/bin/logcli
logcli --version

# Python client deps
cd scenario-02-logs/python && pip install -r requirements.txt
```

---

## Quick start

On the lab host:

```bash
cd scenario-02-logs
./scripts/10-loki.sh              # Loki (single binary) + Alloy (daemonset)
./scripts/20-deploy-logapps.sh    # batch-worker, and demoapp bumped to 1.1.0
```

### Access

Loki joins the tailnet the same way Grafana and Prometheus did in scenario 01,
so everything below works from your workstation with no port-forward:

```bash
export LOKI_ADDR=http://loki:3100      # logcli reads this
logcli labels
logcli query --limit=5 '{app="batch-worker"}'
```

If you are not on the tailnet:

```bash
kubectl -n logging port-forward svc/loki 3100:3100
export LOKI_ADDR=http://localhost:3100
```

Grafana picks Loki up automatically — scenario 01 runs the datasource sidecar
with `searchNamespace: ALL`, and `k8s/grafana-datasource.yaml` carries the
label it watches for. Go to **Explore → Loki**.

---

## What's running

| Piece | Where | Notes |
|---|---|---|
| Loki 3.6.x | `logging`, single binary | filesystem storage, 20Gi PVC, 72h retention |
| Alloy 1.19.x | `logging`, daemonset | tails `/var/log/pods`, ships to Loki |
| demoapp 1.1.0 | `demo` | scenario 01's app, now emitting JSON logs too |
| batch-worker 1.0.0 | `demo`, 2 replicas | four log formats, on purpose |

`batch-worker` has **no metrics endpoint at all**. That is deliberate: it is
the workload you cannot instrument, where logs are the only signal. Exercise 5
makes you build a RED view of it anyway.

Three incidents are planted in its output:

1. **The billing slow burn.** `upstream=billing` degrades on a ~20 minute
   cycle — retries climb, durations roughly triple, then it recovers. No
   single line says so.
2. **The poison record.** `REC-4417709` fails every time it is touched, about
   every 3 minutes, and is the only record that does.
3. **A FATAL, rarely.** One line roughly every 20 minutes, in tens of
   thousands.

---

## Concepts you need before exercise 2

A LogQL query has up to four stages, and they run in this order. The order is
the whole performance story:

```
{app="batch-worker"}          |= "error"        | json          | level="error"
└─ stream selector ─┘         └─ line filter ─┘ └─ parser ─┘    └─ label filter ─┘
   uses the INDEX                brute force      per line        on parsed fields
   cheap                         fast-ish         EXPENSIVE       cheap by then
```

1. **Stream selector** — the only part that uses the index. It picks which
   streams (label combinations) to read. Everything after it operates on
   whatever this selected.
2. **Line filter** (`|=`, `!=`, `|~`, `!~`) — substring or regex over raw
   lines. No index, but very fast per byte. `|=` beats `|~` substantially.
3. **Parser** (`| json`, `| logfmt`, `| pattern`, `| regexp`) — turns the line
   into fields. Runs on every line that survived step 2, so every line you
   eliminate earlier is a line you do not parse.
4. **Label filter** (`| level="error"`, `| duration_ms > 500`) — on the fields
   step 3 produced. Cheap, because the work is already done.

**The rule that follows:** narrow the selector as hard as you can, then put
the cheapest filter that removes the most lines in front of the parser.

Those two halves of the rule are not the same lever, and exercise 4 measures
the difference. Only stage 1 reduces the data Loki **reads** — stages 2-4 all
run after the chunks are already fetched and decompressed, so they reduce
**CPU** rather than I/O. Both matter; they just show up in different columns
of `--stats`.

A **stream** is one unique combination of label values. Streams are the unit
of everything: storage, the index, and the memory Loki uses. Keep them few.

---

## Exercise 1 — The label set is the index

**Goal:** learn what you can query cheaply, before writing a single query.

```bash
export LOKI_ADDR=http://loki:3100

# 1. What labels exist at all?
logcli labels

# 2. What values does each have?
logcli labels app
logcli labels namespace
logcli labels pod

# 3. How many STREAMS is that? This is the number that matters.
logcli series --analyze-labels '{namespace="demo"}'
```

Now answer, without running anything else:

1. Is `level` a label? For which app? Why not for the other one?
2. Is `upstream` a label? It appears in thousands of lines — why can you not
   select on it in `{}`?
3. `logcli series --analyze-labels` prints a cardinality column. Which label
   is the most expensive, and what would happen to it at 50 replicas?

Then try to break it:

```bash
# This works.
logcli query --limit=5 '{app="batch-worker"}'

# This does not. Read the error carefully before continuing.
logcli query --limit=5 '{upstream="billing"}'
```

<details>
<summary><b>Discussion</b></summary>

`logcli labels` returns eight, from three different sources — and knowing
which is which is most of the exercise:

| Label | Where it comes from |
|---|---|
| `app`, `container`, `namespace`, `pod` | `discovery.relabel` in `alloy.values.yaml`, from Kubernetes metadata |
| `cluster` | `external_labels` on `loki.write` |
| `level` | `stage.labels`, **demoapp only** |
| `stream` | `stage.cri` — `stdout` or `stderr`, from the runtime's envelope |
| `service_name` | **Loki itself.** You configured nothing. |

`level` exists only for `demoapp`, because the config promotes it inside a
`stage.match { selector = "{app=\"demoapp\"}" }` block and deliberately does
not do the same for `batch-worker`. That asymmetry is what exercises 2 and 3
are built on.

`service_name` is added by Loki, which guesses it from the stream's other
labels. Depending on version you may meet `detected_level` too. Worth knowing
purely so "where did this label come from?" is not a confusing afternoon — the
answer is Loki, not your collector.

**And one that is deliberately missing.** `loki.source.file` attaches
`filename` to everything it tails, and `alloy.values.yaml` throws it away:

```river
stage.label_drop {
  values = ["filename"]
}
```

Look at what the value would have been and you can see why:

```
/var/log/pods/demo_batch-worker-98bc5b89-clr85_b9113bbb-.../batch-worker/0.log
                                  └─ pod uid ─┘            └ restart counter ┘
```

It carries the pod UID *and* the restart counter, so every container restart
mints a new label value and therefore a brand new stream, permanently. A pod
in CrashLoopBackOff would add streams until the index was useless. It is also
pure duplication — `namespace`, `pod` and `container` already say the same
thing without the UID.

Leaving it in took this lab from 6 streams to 12 before anything had even gone
wrong. That is exercise 7's lesson reaching you through a collector's default
rather than through anything you wrote, which is the more common way it
actually happens.

`upstream` is not a label anywhere. It is a *field inside the line*, and the
selector `{upstream="billing"}` fails with `parse error ... no matching
streams` — or matches nothing — because label matchers only ever see stream
labels. To filter on `upstream` you must first parse:

```logql
{app="batch-worker"} | json | upstream="billing"
```

which is a brute-force scan of every batch-worker line, not an index lookup.

That is the trade-off Loki asks you to make on every field:

| Where it lives | Cost to store | Cost to query | Cardinality it tolerates |
|---|---|---|---|
| Stream label | High — multiplies streams | Nearly free (index) | Low. Tens of values. |
| Structured metadata | Low | Cheap, no parse needed | High. Per-request is fine. |
| In the line | Free | Expensive — scan + parse | Unlimited |

`pod` is the interesting one in this lab. It is borderline: with 2 replicas it
is cheap and it answers "one pod or both?", which you genuinely need. At 50
replicas it would be 25x the streams for a question you could answer with
structured metadata instead. There is no universally right answer — but there
is a right way to decide, which is to count.

</details>

---

## Exercise 2 — Parse all four formats

**Goal:** get structured fields out of a process that logs four different ways.

`batch-worker` emits JSON, logfmt, plain timestamped text, and Java stack
traces. Write a query for each:

1. From the **JSON** lines, every failed record with its `upstream` and
   `duration_ms`.
2. From the **logfmt** lines, every `job started` with its `job` and `batch_size`.
3. From the **plain** retry lines, the attempt number and upstream. (Neither
   `| json` nor `| logfmt` can read these.)
4. Every **stack trace**, as one result per exception rather than per frame.

<details>
<summary><b>Solutions</b></summary>

```logql
# 1. JSON. The |= prefilter is not decoration - it is what stops the parser
#    from running on the ~90% of lines that cannot match.
{app="batch-worker"} |= "record failed"
  | json
  | level="error"
  | line_format "{{.upstream}} {{.record_id}} {{.duration_ms}}ms {{.error}}"

# 2. logfmt. Note these lines are NOT JSON - same process, different format.
{app="batch-worker"} |= "job started"
  | logfmt
  | line_format "{{.job}} batch={{.batch_size}} run={{.run_id}}"

# 3. pattern. <_> means "match and discard". Whitespace is literal, and the
#    source line has TWO spaces after WARN.
{app="batch-worker"} |= "WARN  retry"
  | pattern "<_> <_> WARN  retry <attempt>/<total> upstream=<upstream> <_>"
  | line_format "{{.upstream}} attempt {{.attempt}}/{{.total}}"

# 3b. Same thing with regexp, when pattern is not enough. Named capture
#     groups become fields. More powerful, noticeably slower.
{app="batch-worker"} |= "WARN  retry"
  | regexp "retry (?P<attempt>\\d+)/(?P<total>\\d+) upstream=(?P<upstream>\\w+)"

# 4. Stack traces. One result per exception, because Alloy joined the frames
#    at collection time.
{app="batch-worker"} |= "Exception in thread"
```

**Pattern vs regexp:** reach for `pattern` first. It is dramatically faster
because it does no backtracking, and it is far easier to read six months later.
Drop to `regexp` only when the structure genuinely varies.

**On #4 — the one that cannot be fixed later.** That query returns whole
exceptions only because `alloy.values.yaml` has:

```river
stage.multiline {
  firstline     = "^(\\{|ts=|\\[GC\\]|\\d{4}-\\d{2}-\\d{2} |Exception in thread)"
  max_lines     = 20
  max_wait_time = "3s"
}
```

Without it, each trace arrives as nine separate entries. No LogQL query can
reassemble them, because the fact that they belonged together was never
recorded. Multi-line joining is a *collection-time* decision, and it is the
main reason the collector config matters at all.

Prove it to yourself:

```bash
logcli query --limit=20 -o raw '{app="batch-worker"} |= "Exception in thread"'
```

Each result should be a complete trace, `Caused by:` and all.
</details>

---

## Exercise 3 — Find what your parser threw away

**Goal:** discover that `| json` is discarding real lines and telling nobody.

Run these two and compare the counts:

```bash
logcli query --limit=1 --stats --since=1h '{app="batch-worker"} | json | level="error"'
logcli query --limit=20 --since=1h '{app="batch-worker"} | json | __error__="JSONParserErr"'
```

1. How many lines fail to parse in the last hour? Look at what they *are* —
   the number is much bigger than you expect, and the reason matters.
2. Of those, how many are genuinely *broken* JSON rather than "not JSON"?
3. Does `| json | level="error"` include or exclude them?
4. Write a query for the parse-failure *rate* — one that is actually
   meaningful.

<details>
<summary><b>Solutions</b></summary>

**1. The naive count is enormous, and mostly meaningless.**

```logql
{app="batch-worker"} | json | __error__="JSONParserErr"
```

This returns a large fraction of everything `batch-worker` writes. The reason
is not that the app is broken — it is that `batch-worker` emits four formats,
and `| json` fails on every line that was **never JSON in the first place**:
the logfmt lines, the plaintext retries, the `[GC]` lines, the stack traces.

This is the trap inside the trap. `__error__` counts "this parser did not
apply", not "this data is bad". Point a parser at a mixed stream and your
error count measures your own query, not the system.

**2. Scope the parser to the lines it is meant for.**

```logql
# Only lines that were trying to be JSON, and failed.
{app="batch-worker"} |= "{" | json | __error__="JSONParserErr"

# And the clean ones, for a denominator.
{app="batch-worker"} |= "{" | json | __error__=""
```

Now the number is small — roughly 2% — and it means something: a writer that
truncated mid-line. That is a real defect worth alerting on.

**3. Excluded. Silently.** A line that failed to parse has no `level` field,
so `| level="error"` cannot match it. Not counted, not reported. To be
explicit about wanting only cleanly-parsed lines:

```logql
{app="batch-worker"} |= "{" | json | __error__="" | level="error"
```

**4. The rate, with a denominator that makes it a ratio rather than a
function of traffic volume:**

```logql
sum(rate({app="batch-worker"} |= "{" | json | __error__="JSONParserErr" [5m]))
/
sum(rate({app="batch-worker"} |= "{" | json [5m]))
```

Keep the broken line's content when you need to debug it — `__error__` is
dropped by the next label filter, so capture it into a real label first:

```logql
{app="batch-worker"} |= "{" | json | label_format parse_error="{{.__error__}}"
```

**Why this is the most under-appreciated failure mode in log alerting.** Your
"errors per second" panel is built on `| json`. The writer starts truncating
under load. The panel goes **down**, because broken lines stop being counted,
at exactly the moment things are getting worse.

Two habits worth keeping:

- Every dashboard with a parser gets a companion panel counting `__error__`.
- Scope every parser with a line filter, so `__error__` means "bad data" and
  not "wrong format".

Watch it happen:

```bash
./scripts/chaos.sh malformed 0.4     # 40% of JSON lines truncated
# wait ~2 minutes, then re-run your error-rate query from step 3. It goes DOWN.
./scripts/chaos.sh malformed 0.02
```
</details>

---

## Exercise 4 — What your query costs

**Goal:** find out what actually drives query cost, which is probably not what
you think.

`--stats` is the most useful flag in `logcli`. But measure carefully: a log
query with a small `--limit` lets Loki stop as soon as it has enough lines, so
the stats describe an early exit rather than real work. Wrap each pipeline in
`count_over_time` to force evaluation of the whole window, exactly as a
dashboard panel does.

```bash
export LOKI_ADDR=http://loki:3100

# Part 1 - vary the STREAM SELECTOR, keep the pipeline empty.
for sel in '{namespace="demo"}' '{app="batch-worker"}' ; do
  echo "--- $sel"
  logcli query --limit=1 --quiet --stats --since=2h \
    "sum(count_over_time(${sel} [5m]))" 2>&1 \
    | grep -E "Bytes Processed|Lines Processed|Exec Time"
done

# Part 2 - keep the selector fixed, vary the PIPELINE.
for pipe in \
  '{app="batch-worker"}' \
  '{app="batch-worker"} |~ "(?i)error"' \
  '{app="batch-worker"} |= "error"' \
  '{app="batch-worker"} |= "{" | json | __error__=""' \
  '{app="batch-worker"} | json | __error__=""' ; do
  echo "--- $pipe"
  logcli query --limit=1 --quiet --stats --since=2h \
    "sum(count_over_time(${pipe} [5m]))" 2>&1 \
    | grep -E "Bytes Processed|Exec Time"
done
```

1. In part 1, how much does `Bytes Processed` change?
2. In part 2, how much does `Bytes Processed` change?
3. Explain the difference. Then decide what that means for how you write
   queries.

<details>
<summary><b>Solutions</b></summary>

**1. Part 1 changes a lot, and roughly in proportion to how much of the data
the selector covers:**

| Selector | Bytes read |
|---|---|
| `{namespace="demo"}` | ~5.0 MB (1.00x) |
| `{app="batch-worker"}` | ~3.7 MB (0.74x) |
| `{app="batch-worker", pod="batch-worker-<one pod>"}` | ~1.8 MB (0.37x) |

**2. Part 2 barely changes at all.** Every pipeline reads the *same* bytes —
the regex, the substring and the JSON parser all report essentially identical
`Bytes Processed`.

**3. This is the finding, and it surprises most people.**

`Bytes Processed` is decided by the **stream selector and nothing else**. The
line filter and the parser run *after* the chunks have been fetched and
decompressed. They cannot un-read data. What they change is **CPU**, which
shows up in `Exec Time`, not in bytes.

So there are two separate levers, and they are not interchangeable:

| Stage | Lever | Cost it controls | Backed by an index? |
|---|---|---|---|
| `{...}` stream selector | narrow the labels | **I/O** — bytes read | Yes. The only one. |
| `\|=` / `\|~` line filter | prefer substring over regex | CPU | No |
| `\| json` parser | put a line filter in front of it | CPU, the largest share | No |

**What this means in practice:**

- Narrowing the selector is the only way to make Loki read less. This is why
  exercise 1 matters and why label design matters: if `upstream` were a label,
  `{upstream="billing"}` would read a fraction of the data instead of scanning
  all of it.
- A line filter before a parser is still worth writing, but for a CPU reason,
  not an I/O one. On this lab's few MB the difference is small and mostly
  lost in noise. At a few hundred GB/day it decides whether the panel loads.
- `(?i)` case-insensitive regex disables the fast literal-substring path. If
  you can normalise case at write time, do.

Now make volume the variable instead:

```bash
./scripts/chaos.sh flood     # 10x the log rate for 3 minutes
# re-run part 1 during the flood
```

Same queries, same results, several times the bytes. **Query cost in Loki is a
function of data volume, not of query complexity** — which is why the
commented-out `stage.drop` in `alloy.values.yaml` matters more than any query
tuning you will ever do. The cheapest line to query is the one you never
ingested.
</details>

---

## Exercise 5 — RED metrics from logs alone

**Goal:** build rate, errors and duration for a service with no metrics
endpoint.

`batch-worker` exposes nothing. Using only its log lines, produce:

1. Records processed per second, by upstream.
2. The error ratio, by upstream.
3. p95 `duration_ms`, by upstream.
4. Retries per second, by upstream — from the plaintext lines.

<details>
<summary><b>Solutions</b></summary>

```logql
# 1. Rate. count_over_time counts LINES; rate() gives per-second.
sum by (upstream) (
  rate({app="batch-worker"} |= "record processed" | json [5m])
)

# 2. Error ratio. Both sides must aggregate by the SAME label set, exactly as
#    in scenario 01 exercise 2 - otherwise the division matches nothing.
sum by (upstream) (rate({app="batch-worker"} |= "record failed" | json [5m]))
/
sum by (upstream) (
  rate({app="batch-worker"} |~ "record (processed|failed)" | json [5m])
)

# 3. p95 duration. `unwrap` turns a parsed numeric FIELD into a value that can
#    be aggregated - this is the bridge from logs to numbers.
quantile_over_time(0.95,
  {app="batch-worker"} |~ "record (processed|failed)"
    | json
    | unwrap duration_ms [5m]
) by (upstream)

# 4. Retries, from plaintext. Note `pattern` inside a metric query.
sum by (upstream) (
  count_over_time(
    {app="batch-worker"} |= "WARN  retry"
      | pattern "<_> <_> WARN  retry <attempt>/<total> upstream=<upstream> <_>"
    [5m]
  )
)
```

**Why every one of those starts with a line filter.** It is not for speed
here — it is required. A metric query *refuses to run* if its pipeline hit a
parse error:

```
400: pipeline error: 'JSONParserErr' for series {__error__="JSONParserErr", ...}
Use a label filter to intentionally skip this error.
```

This is a real asymmetry, and it catches people out constantly:

| | parse errors |
|---|---|
| Log query (`{...} \| json \| ...`) | silently dropped |
| Metric query (`rate({...} \| json ...)`) | **hard 400, no results at all** |

So a pipeline that looks fine while you are exploring in Explore becomes a
broken dashboard panel the moment you wrap it in `rate()`. Two ways to satisfy
it — filter so nothing unparseable reaches the parser, as above, or skip them
explicitly:

```logql
sum by (upstream) (rate({app="batch-worker"} | json | __error__="" [5m]))
```

Prefer the line filter: `__error__=""` silently discards the broken lines,
which is exercise 3's problem all over again. The filter avoids creating them.

Then compare the *cost* of #3 against scenario 01's equivalent:

```promql
histogram_quantile(0.99,
  sum by (route, le) (rate(demoapp_http_request_duration_seconds_bucket[5m])))
```

Prometheus answers that from pre-aggregated buckets — a handful of series,
microseconds of work. Loki answers the log version by re-reading and
re-parsing every matching line, every time the panel refreshes.

**So: derive metrics from logs when you have no choice.** For a vendor binary
or a legacy service, it is genuinely the only option and it works. As a
*design*, for software you control, it is choosing to pay for the same
computation forever instead of once.

There is a middle path worth knowing about, though it is out of scope here:
Loki's ruler can evaluate these queries on a schedule and write the results to
Prometheus as recording rules — computing once and querying cheaply thereafter.
</details>

---

## Exercise 6 — Hunt the slow burn

**Goal:** find an incident that no individual log line describes.

One upstream degrades gradually and recovers, on a cycle. Find it, with these
constraints:

- Do not read the source in `app/batchworker.py`.
- Start from `{namespace="demo"}` and nothing else.
- Work out *which* upstream, *how long* the cycle is, and *what leads* —
  retries or failures.

<details>
<summary><b>How to work it, and the answer</b></summary>

A workable method, which generalises well beyond this lab:

```bash
# 1. Where is the volume? Start broad, narrow by evidence.
logcli volume --since=2h '{namespace="demo"}'

# 2. Is anything trending? Errors over time, by app.
logcli query --since=2h -o jsonl \
  'sum by (app) (count_over_time({namespace="demo"} |~ "(?i)(error|fail)" [5m]))'

# 3. Break it down by the field that matters.
logcli query --since=2h \
  'sum by (upstream) (rate({app="batch-worker"} |= "record failed" | json [5m]))'

# 4. Then look for the LEADING indicator, not the lagging one.
logcli query --since=2h \
  'sum by (upstream) (count_over_time({app="batch-worker"} |= "WARN  retry"
     | pattern "<_> <_> WARN  retry <attempt>/<total> upstream=<upstream> <_>" [5m]))'
```

**The answer:** `billing`, on a ~20 minute sawtooth — a ramp over roughly 14
minutes, then a sharp recovery. Failures triple and `duration_ms` rises with
them.

**Retries lead failures.** Retries climb while requests are still ultimately
succeeding, because most are retried into success; failures only rise later,
once retries stop being enough. That ordering is the entire value of the
exercise — the retry line is the one worth alerting on, and it is in
unstructured plaintext that no `| json` would ever have found.

The Python version of this, with sparklines, is `python/solutions.py 6`.

Two things worth taking away:

1. The signal is a *shape over time*, not a value. Any threshold alert tuned
   to the peak fires late; one tuned to the mean fires constantly.
2. In a real system you would compare against the same window last week
   (`offset 7d`), not against this window's own average — daily and weekly
   cycles will otherwise produce endless false positives.
</details>

---

## Exercise 7 — The cardinality bomb, log edition

**Goal:** the direct sequel to scenario 01 exercise 5. Same mistake, different
system, worse consequences.

`demoapp` emits a unique `trace_id` on every request. Right now Alloy attaches
it as **structured metadata**. Arm the bomb and make it a **label** instead:

```bash
# Measure first. You cannot see damage you did not baseline.
logcli series --analyze-labels '{app="demoapp"}'
curl -sG http://loki:3100/loki/api/v1/series \
  --data-urlencode 'match[]={app="demoapp"}' | jq '.data | length'

./scripts/chaos.sh break-labels
# wait 3-4 minutes
```

Then measure again, and answer:

1. How many streams now, and how fast is it growing?
2. What does `logcli query '{app="demoapp"}'` feel like?
3. Did anything anywhere report an error?
4. After `fix-labels`, is it over?

<details>
<summary><b>Discussion</b></summary>

**1.** Streams go from single digits to one per request, and keep climbing for
as long as the bomb is armed. Loki's own view, via Prometheus (scenario 01
scrapes it):

```promql
loki_ingester_memory_streams
rate(loki_ingester_chunks_created_total[5m])
```

Chunk creation is the part that hurts. Each stream gets its own chunk, so
instead of a few large well-compressed chunks you get thousands of tiny ones.
Compression collapses, the index balloons, and every query has to open all of
them.

**2.** Slow, and progressively slower. Queries that were instant start taking
seconds, and `--stats` shows the damage in chunk counts rather than bytes.

**3.** No. Nothing errors. Ingestion keeps working, queries keep returning
correct results, and the only symptom is that everything gets worse — which is
precisely why this reaches production so often. Compare scenario 01 exercise 1:
the same "nothing logged an error, anywhere" lesson, in a different register.

**4.** No, and this is the important part. `fix-labels` stops *new* bad streams
being created. Every stream already in the index stays there until it ages out
of the 72h retention. You cannot un-ring the bell; you can only stop ringing
it. In production with 30-day retention, one afternoon's mistake is a month of
degraded queries.

**The actual rule.** Ask one question of every field: *how many distinct values
can this have?*

| Values | Where it goes |
|---|---|
| Tens, bounded, known ahead of time | Stream label |
| Unbounded, but you need to filter on it | Structured metadata |
| Unbounded, you only read it once you have the line | Leave it in the line |

`trace_id` is the textbook case for structured metadata: per-request, so
catastrophic as a label, but you genuinely do want to jump straight to one
trace's lines. That is exactly the gap structured metadata was added to fill.

```logql
# Structured metadata is queryable WITHOUT a parser - it is already a field.
{app="demoapp"} | trace_id="<paste one>"
```

Compare that with what the same lookup costs if `trace_id` only exists inside
the line:

```logql
{app="demoapp"} |= "<trace id>"      # full scan of every demoapp line
```
</details>

---

## Exercise 8 — Make the metric and the log agree

**Goal:** use two signals together, which is the entire point of having both.

Scenario 01 exercise 4 showed `/api/search` has a bimodal latency
distribution: a fast bulk and a slow tail. The histogram shows you the *shape*.
It cannot tell you *which* requests were slow or *why*.

demoapp 1.1.0 now logs an `index_state` field on every search.

1. In Prometheus, get p50 and p99 for `/api/search`.
2. In Loki, get p50 and p99 of `duration_ms` for the same route.
3. Do they agree? Should they?
4. Use `index_state` to explain the two humps.
5. What fraction of searches take the cold path, from logs? Does it match the
   12% the histogram implies?

<details>
<summary><b>Solutions</b></summary>

```promql
# 1. Prometheus
histogram_quantile(0.50, sum by (le) (
  rate(demoapp_http_request_duration_seconds_bucket{route="/api/search"}[5m])))
histogram_quantile(0.99, sum by (le) (
  rate(demoapp_http_request_duration_seconds_bucket{route="/api/search"}[5m])))
```

```logql
# 2. Loki. Note TWO things here.
#
#    First the unit: the metric is in SECONDS, the log field is MILLISECONDS.
#
#    Second, and less obvious - the `by ()` is NOT optional. Drop it and the
#    query fails with "maximum number of series (500) reached". See below.
quantile_over_time(0.50,
  {app="demoapp"} |= "/api/search" | json | unwrap duration_ms [5m]) by ()
quantile_over_time(0.99,
  {app="demoapp"} |= "/api/search" | json | unwrap duration_ms [5m]) by ()

# 4. The explanation the histogram cannot give you.
quantile_over_time(0.95,
  {app="demoapp"} |= "/api/search" | json | unwrap duration_ms [5m])
  by (index_state)

# 5. The share of cold requests.
sum(count_over_time({app="demoapp"} | json | index_state="cold" [5m]))
/
sum(count_over_time({app="demoapp"} | json | index_state=~"cold|warm" [5m]))
```

**On that mandatory `by ()`.** Without it the query dies:

```
maximum number of series (500) reached for a single query
```

`| json` promotes *every* field in the line to a label, and demoapp lines
carry `trace_id` — unique per request. An unwrapped range aggregation keeps
one series per distinct label combination, so you have asked Loki for one
series per request. `by ()` collapses them all into one; `by (route)` or
`by (index_state)` collapses them into the grouping you actually want.

This is exercise 7's cardinality lesson arriving from a completely different
direction: it is not only the *collector* that can promote a high-cardinality
field. Your query can do it too, and the failure is loud here only because
Loki has a series limit. Note that `| drop trace_id` does **not** rescue it —
every other parsed field is still a label, `duration_ms` included. Aggregate
explicitly; do not try to prune your way out.

**3. They will not match exactly, and both are right.** Prometheus interpolates
within histogram buckets — with a boundary at 1.0s and another at 2.5s, a p99
that truly falls at 1.7s is estimated from the bucket edges and can be off by
hundreds of milliseconds. Loki computes over actual observed values, so it is
exact for the lines it read — but it read only the lines matching the query in
that window, so it is a sample.

Neither is "the truth":

- The histogram is **cheap, aggregated, and approximate**. Correct for alerting
  and trends.
- The log quantile is **expensive, exact, and specific**. Correct for
  investigating.

Knowing *why* they differ is what stops you filing a bug against your own
monitoring. If you need exactness at a specific latency, move a histogram
bucket boundary there — that is what buckets are for.

**4/5.** Splitting by `index_state` separates the humps cleanly: warm sits
around 60-80ms, cold anywhere from 800ms to 2.5s. The cold share should land
near 12%, matching `app/main.py`. That is the whole argument for having both
signals: the metric told you *that* p99 was bad and it was cheap to know,
the log told you *which* requests and *why*, and neither could have done the
other's job.
</details>

---

## Python exercises

Everything above works from Python too, and some of it is much nicer there —
anything needing a join, a distribution, or a report.

`python/lokiq.py` is a small client, written to be read. Its docstring lists
four traps in the twenty-line httpx snippet everyone writes first; each is
handled in the code with a comment explaining why.

```bash
cd python
pip install -r requirements.txt
export LOKI_URL=http://loki:3100     # or http://localhost:3100 via port-forward

python solutions.py 1       # one exercise
python solutions.py all     # all of them
```

| # | Exercise | What it teaches |
|---|---|---|
| P1 | Inventory the label set and count streams | Start from the index, not from a query |
| P2 | Errors by upstream, with latency percentiles | Push filtering server-side, not into Python |
| P3 | Find the poison record | The distribution is the finding, not any line |
| P4 | Count what `\| json` silently dropped | `__error__`, and cross-checking Loki against yourself |
| P5 | RED metrics from logs alone | `query_metrics`, and why matrix ≠ streams |
| P6 | Detect the slow burn, with sparklines | Shape over time beats any threshold |
| P7 | `limit=1000` vs real pagination | The silent truncation that makes scripts lie |
| P8 | Separate what costs I/O from what costs CPU | The selector reads; everything after it computes |

Write your own first, then read the solution. P4 and P7 are the two that
change how you write scripts afterwards.

**The four traps, since they are the reason the file exists:**

1. **Two timestamp formats.** Log queries return nanosecond *strings*; metric
   queries return float *seconds*. Same endpoint, same field name. Parse them
   identically and half your timestamps land in 1970.
2. **`limit` truncates silently.** You asked for 1000, you got 1000, and
   nothing says there were 40,000. With `direction="backward"` you got the
   *newest* 1000 — so a script that "analysed the last 6 hours" actually
   analysed the last four minutes, and reported a confident wrong answer.
3. **`resultType` is not fixed.** `"streams"` or `"matrix"` depending on the
   query. Code assuming one crashes on the other.
4. **Entries may have three elements.** With structured metadata,
   `[ts, line, {metadata}]`. `for ts, line in values` raises `ValueError` the
   day someone enables it — which, in this lab, is already.

---

## Troubleshooting

**`logcli labels` returns nothing.**
Alloy has not shipped anything. In order:
```bash
kubectl -n logging get pods                       # alloy running?
kubectl -n logging logs daemonset/alloy --tail=50 # complaining?
kubectl -n logging port-forward svc/alloy 12345:12345
# -> http://localhost:12345 draws the pipeline graph, component by component
```
That UI is the fastest way to find a broken pipeline: it shows each component's
health and how many entries passed through it, so you can see exactly where
the flow stops.

**Loki pod is not becoming ready.**
Almost always `replication_factor`. The chart defaults to 3; a single binary
cannot satisfy a quorum of 3 against itself and sits there forever.
`helm/loki.values.yaml` sets it to 1.
```bash
kubectl -n logging logs statefulset/loki --tail=100
kubectl -n logging exec statefulset/loki -- wget -qO- http://127.0.0.1:3100/ready
```

**Logs from some pods but not others.**
Check `discovery.relabel "pod_logs"` in `helm/alloy.values.yaml`. It keeps only
`namespace="demo"`. A pod elsewhere is working exactly as configured.

**`parse error: unexpected IDENTIFIER`.**
Usually a field used as a label matcher: `{upstream="billing"}` instead of
`| upstream="billing"` after a parser. Exercise 1.

**Queries are slow, and were not yesterday.**
```bash
logcli series --analyze-labels '{namespace="demo"}'
```
If a label has thousands of values, something high-cardinality got promoted.
See exercise 7 — and check whether `chaos.sh break-labels` is still armed:
```bash
./scripts/chaos.sh status
```

**Disk filling up.**
Retention needs *both* `retention_period` and `compactor.retention_enabled`.
Setting only the first is the classic version of this bug, and the symptom is
a disk that never stops growing while the config clearly says 72h.

---

## Cleanup

```bash
./scripts/chaos.sh reset          # undo fault injection, keep everything
./scripts/99-teardown.sh          # remove scenario 02, keep the PVC
./scripts/99-teardown.sh --all    # also delete the PVC and namespace
```

`helm uninstall` does **not** delete StatefulSet PVCs. Every log line you
ingested is still on that disk until `--all`.

---

## Files

```
scenario-02-logs/
├── app/
│   ├── batchworker.py          four log formats, three planted incidents
│   └── Dockerfile
├── helm/
│   ├── loki.values.yaml        single binary, filesystem, mostly turning things off
│   └── alloy.values.yaml       the collection pipeline, and why each stage exists
├── k8s/
│   ├── batchworker.yaml        no Service, no metrics - logs are the only signal
│   ├── grafana-datasource.yaml picked up by scenario 01's sidecar
│   ├── loki-tailnet-service.yaml
│   ├── namespace.yaml
│   └── kustomization.yaml
├── python/
│   ├── lokiq.py                the client, and the four traps it avoids
│   ├── solutions.py            P1-P8, runnable
│   └── requirements.txt
└── scripts/
    ├── 10-loki.sh              Loki + Alloy
    ├── 20-deploy-logapps.sh    batch-worker + demoapp 1.1.0
    ├── chaos.sh                log-flavoured fault injection
    └── 99-teardown.sh
```

---

## Before scenario 3

Scenario 03 adds traces. The `trace_id` already in demoapp's logs is the hook:
once Tempo exists, Grafana's derived fields turn it into a link, and a log line
becomes one click from the full request trace.

The question worth holding on to: you now have two signals that overlap
heavily. Metrics told you *that* something is wrong and were cheap. Logs told
you *which* and *why* and were expensive. Traces will tell you *where in the
call path* — and will be more expensive still. Deciding what goes in which is
the actual skill; the query languages are just syntax.
