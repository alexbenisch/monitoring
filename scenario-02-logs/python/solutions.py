#!/usr/bin/env python3
"""
Worked solutions to the Python exercises in scenario 02's README.

Run one:      python solutions.py 3
Run all:      python solutions.py all
Other Loki:   LOKI_URL=http://localhost:3100 python solutions.py 3

Read these AFTER trying the exercise. They are commented as explanations, not
as code you would copy into a service.
"""

from __future__ import annotations

import os
import statistics
import sys
from collections import Counter, defaultdict

from lokiq import LokiClient

LOKI_URL = os.getenv("LOKI_URL", "http://loki:3100")


def header(n: int, title: str) -> None:
    print(f"\n{'=' * 70}\nP{n}. {title}\n{'=' * 70}")


# --- P1 -----------------------------------------------------------------


def p1(loki: LokiClient) -> None:
    header(1, "What is actually in here?")

    # Always start here. Not with a query - with the label set. The labels ARE
    # the index; anything not in this list costs a full scan to filter on.
    labels = loki.labels(since="6h")
    print(f"labels ({len(labels)}): {', '.join(sorted(labels))}\n")

    for label in sorted(labels):
        values = loki.label_values(label, since="6h")
        # Truncate: if a label has hundreds of values, that is the finding.
        shown = ", ".join(sorted(values)[:8])
        more = f" ... (+{len(values) - 8} more)" if len(values) > 8 else ""
        print(f"  {label:<12} {len(values):>5} values   {shown}{more}")

    # The number that decides whether Loki is fast: how many streams exist.
    # A stream is one unique COMBINATION of label values.
    streams = loki.series('{namespace="demo"}', since="6h")
    print(f"\nstreams in namespace=demo: {len(streams)}")
    print("healthy for this lab is roughly 6-10. Hundreds means something")
    print("high-cardinality got promoted to a label - see P8 and exercise 7.")


# --- P2 -----------------------------------------------------------------


def p2(loki: LokiClient) -> None:
    header(2, "Errors by upstream, from JSON logs")

    # `| json` happens SERVER-side: Loki parses and filters, and only matching
    # lines cross the network. Doing the same filtering in Python means
    # downloading everything first. Push work into the query.
    query = '{app="batch-worker"} | json | level="error"'
    entries = loki.query_logs(query, since="1h", limit=5000)
    print(f"{len(entries)} error entries in the last hour\n")

    by_upstream: Counter[str] = Counter()
    by_error: Counter[str] = Counter()
    durations: dict[str, list[float]] = defaultdict(list)

    for entry in entries:
        # entry.json() returns None rather than raising, so a malformed line
        # is counted instead of crashing the loop. See P4.
        doc = entry.json()
        if doc is None:
            continue
        by_upstream[doc.get("upstream", "?")] += 1
        by_error[doc.get("error", "?")] += 1
        if "duration_ms" in doc:
            durations[doc["upstream"]].append(float(doc["duration_ms"]))

    print(f"{'upstream':<12} {'errors':>7} {'p50 ms':>9} {'p95 ms':>9}")
    for upstream, count in by_upstream.most_common():
        ds = sorted(durations[upstream])
        p50 = statistics.median(ds) if ds else 0.0
        p95 = ds[int(len(ds) * 0.95)] if len(ds) > 20 else (ds[-1] if ds else 0.0)
        print(f"{upstream:<12} {count:>7} {p50:>9.1f} {p95:>9.1f}")

    print("\nby error reason:")
    for reason, count in by_error.most_common():
        print(f"  {count:>5}  {reason}")

    print("\nExpect `billing` to lead by a wide margin. That is incident 1,")
    print("and P6 shows it is not constant - it comes and goes on a cycle.")


# --- P3 -----------------------------------------------------------------


def p3(loki: LokiClient) -> None:
    header(3, "Find the poison record")

    # The needle: exactly one record_id fails every time it is touched.
    # Everything else fails at random. So: count failures per record_id and
    # look for the one that is not a one-off.
    entries = loki.query_logs(
        '{app="batch-worker"} | json | level="error"', since="6h", limit=10000
    )

    failures: Counter[str] = Counter()
    for entry in entries:
        doc = entry.json()
        if doc and "record_id" in doc:
            failures[doc["record_id"]] += 1

    print(f"{len(failures)} distinct record_ids failed at least once\n")
    print("top offenders:")
    for record_id, count in failures.most_common(5):
        marker = "  <-- this one" if count > 3 else ""
        print(f"  {count:>4}x  {record_id}{marker}")

    repeat = [r for r, c in failures.items() if c > 3]
    print(
        f"\n{len(repeat)} record(s) failed more than 3 times: "
        f"{', '.join(repeat) or 'none yet - widen the window'}"
    )
    print("\nThe distribution is the finding. Random failures give you a long")
    print("tail of 1s and 2s; a systematic one stands out by an order of")
    print("magnitude. You cannot see this in any single log line.")


# --- P4 -----------------------------------------------------------------


def p4(loki: LokiClient) -> None:
    header(4, "Count what your parser silently dropped")

    # THE most important exercise here. `| json` does not fail loudly on a
    # malformed line - it tags it __error__="JSONParserErr" and drops it from
    # anything that filters on a parsed field. Your error count is then wrong
    # by however many lines were too broken to parse, and nothing says so.

    # FIRST, the trap inside the trap. The obvious query counts far more
    # failures than there are broken lines:
    naive_bad = loki.query_logs(
        '{app="batch-worker"} | json | __error__="JSONParserErr"',
        since="1h", limit=5000, warn_on_truncation=False,
    )
    print(f"naive __error__ count : {len(naive_bad)}")
    print("  ...which is mostly lines that were NEVER JSON - batch-worker's")
    print("  logfmt, plaintext, [GC] and stack-trace lines all fail `| json`.")
    print("  __error__ means 'this parser did not apply', not 'this data is bad'.\n")

    # So SCOPE the parser to the lines it was meant for. `{` only appears in
    # the JSON-ish lines, valid or truncated.
    ok = loki.query_logs(
        '{app="batch-worker"} |= "{" | json | __error__=""', since="1h",
        limit=5000, warn_on_truncation=False,
    )
    bad = loki.query_logs(
        '{app="batch-worker"} |= "{" | json | __error__="JSONParserErr"',
        since="1h", limit=5000, warn_on_truncation=False,
    )

    print(f"scoped, parsed cleanly : {len(ok)}")
    print(f"scoped, REAL failures  : {len(bad)}")

    if bad:
        pct = 100 * len(bad) / (len(ok) + len(bad))
        print(f"                 ({pct:.1f}% of lines reaching the json parser)\n")
        print("sample of what broke:")
        for entry in bad[:3]:
            print(f"  {entry.line[:100]}")

    # 3. The honest cross-check: parse them ourselves, client-side, and see
    #    whether we agree with Loki. Disagreement here means your query and
    #    your script have different ideas about what the data is.
    raw = loki.query_logs(
        '{app="batch-worker"} |= "{"', since="1h", limit=5000,
        warn_on_truncation=False,
    )
    client_bad = sum(1 for e in raw if e.json() is None)
    print(f"\nclient-side check: {client_bad} of {len(raw)} JSON-ish lines "
          f"fail json.loads()")
    print("\nTwo lessons:")
    print("  1. Scope every parser with a line filter, so __error__ counts bad")
    print("     DATA rather than the wrong format.")
    print("  2. Every `| json` in a dashboard silently discards some number of")
    print("     lines. If you never measure it, you do not know how wrong the")
    print("     panel is - and it gets MORE wrong as the writer degrades.")


# --- P5 -----------------------------------------------------------------


def p5(loki: LokiClient) -> None:
    header(5, "RED metrics from logs alone")

    # batch-worker exposes NO metrics endpoint. Everything below is derived
    # from log lines - which is the situation you are in with most vendor
    # software, and with anything written before someone cared.
    #
    # These are METRIC queries: they return a matrix, not streams, so they go
    # through query_metrics() and come back as float seconds.

    # The |= prefilter is LOAD-BEARING, and not for performance.
    #
    # A metric query REFUSES to run if its pipeline hit a parse error:
    #   400: pipeline error: 'JSONParserErr' for series ...
    # Log queries silently drop those lines; metric queries hard-fail. So a
    # pipeline that is merely sloppy in a log query becomes a broken
    # dashboard panel the moment you wrap it in rate().
    #
    # Two ways to satisfy it: filter so no unparseable line reaches the
    # parser (below), or say `| __error__=""` to skip them on purpose.
    rate_q = (
        'sum by (upstream) ('
        '  rate({app="batch-worker"} |= "record failed" | json [5m])'
        ')'
    )
    samples = loki.query_metrics(rate_q, since="1h", step="5m")

    per_upstream: dict[str, list[float]] = defaultdict(list)
    for sample in samples:
        per_upstream[sample.labels.get("upstream", "?")].append(sample.value)

    print("error rate per second, by upstream (5m windows over the last hour)")
    print(f"\n{'upstream':<12} {'mean':>8} {'peak':>8}   shape")
    for upstream, values in sorted(
        per_upstream.items(), key=lambda kv: -max(kv[1], default=0)
    ):
        mean = statistics.mean(values)
        peak = max(values)
        # A crude sparkline is enough to see a ramp versus a flat line.
        blocks = "▁▂▃▄▅▆▇█"
        scale = peak or 1
        spark = "".join(blocks[min(int(v / scale * 7), 7)] for v in values)
        print(f"{upstream:<12} {mean:>8.3f} {peak:>8.3f}   {spark}")

    # Duration percentiles, from a log FIELD rather than a histogram. unwrap
    # turns a parsed numeric field into something you can aggregate.
    # `by (upstream)` is mandatory, not cosmetic. Without an explicit
    # aggregation, an unwrapped range aggregation keeps one series per
    # distinct label combination - and `| json` has just made every field in
    # the line a label. The query then dies on the 500-series limit.
    dur_q = (
        'quantile_over_time(0.95,'
        '  {app="batch-worker"} |~ "record (processed|failed)" '
        '  | json | unwrap duration_ms [5m]'
        ') by (upstream)'
    )
    print("\np95 duration_ms by upstream:")
    try:
        dur_samples = loki.query_metrics(dur_q, since="1h", step="5m")
        latest: dict[str, float] = {}
        for sample in dur_samples:
            latest[sample.labels.get("upstream", "?")] = sample.value
        for upstream, value in sorted(latest.items(), key=lambda kv: -kv[1]):
            print(f"  {upstream:<12} {value:>8.1f} ms")
    except RuntimeError as exc:
        print(f"  query failed: {exc}")

    print("\nThis is a real RED view built from stdout. It is also 100x more")
    print("expensive to compute than the equivalent Prometheus query, because")
    print("Loki re-parses every line every time. Derive metrics from logs when")
    print("you have no choice - not as a design.")


# --- P6 -----------------------------------------------------------------


def p6(loki: LokiClient) -> None:
    header(6, "Catch the slow burn")

    # Incident 1: billing degrades gradually over ~20 minutes, then recovers.
    # No single line says "billing is degrading". The RETRY lines are the
    # early warning, and they are plain text, not JSON - so this needs a
    # pattern or regexp parser, not `| json`.
    query = (
        'sum by (upstream) ('
        '  count_over_time('
        '    {app="batch-worker"} |~ "WARN  retry" '
        '    | pattern "<_> <_> WARN  retry <attempt>/<total> upstream=<upstream> <_>" '
        '    [5m]'
        '  )'
        ')'
    )
    samples = loki.query_metrics(query, since="2h", step="5m")

    series: dict[str, list[tuple[str, float]]] = defaultdict(list)
    for sample in samples:
        series[sample.labels.get("upstream", "?")].append(
            (sample.ts.strftime("%H:%M"), sample.value)
        )

    print("retries per 5m window, by upstream\n")
    for upstream, points in sorted(series.items()):
        values = [v for _, v in points]
        peak = max(values) if values else 0
        mean = statistics.mean(values) if values else 0
        blocks = "▁▂▃▄▅▆▇█"
        scale = peak or 1
        spark = "".join(blocks[min(int(v / scale * 7), 7)] for v in values)
        ratio = peak / mean if mean else 0
        flag = "  <-- cycling" if ratio > 2.5 else ""
        print(f"  {upstream:<11} peak {peak:>5.0f}  mean {mean:>6.1f}  {spark}{flag}")

    print("\nbilling should show a repeating ramp-and-drop; the others should")
    print("be roughly flat. peak/mean > 2.5 is the crude detector - in a real")
    print("system you would alert on deviation from the same window last week,")
    print("not from this window's own mean.")


# --- P7 -----------------------------------------------------------------


def p7(loki: LokiClient) -> None:
    header(7, "The limit that lies to you")

    query = '{app="batch-worker"}'

    # The naive call. It returns exactly `limit` entries and looks complete.
    import warnings

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        naive = loki.query_logs(query, since="6h", limit=1000)
        warned = bool(caught)

    print(f"query_logs(limit=1000)  -> {len(naive):>7} entries"
          f"{'  (warned)' if warned else ''}")
    if naive:
        print(f"  window actually covered: {naive[0].ts:%H:%M:%S} .. "
              f"{naive[-1].ts:%H:%M:%S}")
        print("  ^ note this is NOT 6 hours. direction=backward means you got")
        print("    the NEWEST 1000 lines, so you are looking at the last few")
        print("    minutes while believing you asked for six hours.")

    # The paging call. Slower, correct.
    print("\npaging through everything (this takes a few seconds)...")
    total = 0
    first_ts = last_ts = None
    for entry in loki.iter_logs(query, since="6h", page_size=1000):
        total += 1
        if first_ts is None:
            first_ts = entry.ts
        last_ts = entry.ts

    print(f"iter_logs()             -> {total:>7} entries")
    if first_ts and last_ts:
        print(f"  window actually covered: {first_ts:%H:%M:%S} .. "
              f"{last_ts:%H:%M:%S}")

    if naive and total:
        print(f"\nthe naive call saw {100 * len(naive) / total:.1f}% of the data")
        print("and told you nothing about the other "
              f"{total - len(naive):,} lines.")

    # The cheap way to get the true count, when you only want the number:
    # ask Loki to count, instead of downloading the lines and counting them.
    counted = loki.query_metrics(
        f"sum(count_over_time({query} [6h]))", since="6h", step="6h"
    )
    if counted:
        print(f"\nsum(count_over_time(...)) says: {counted[-1].value:,.0f}")
        print("one request, no pagination, no lines transferred. When you want")
        print("a NUMBER, never fetch the lines.")


# --- P8 -----------------------------------------------------------------


def p8(loki: LokiClient) -> None:
    header(8, "What your query costs")

    # Measure with count_over_time, not a bare log query. A log query with a
    # small `limit` lets Loki stop as soon as it has enough entries, so the
    # stats describe an early exit rather than the work a dashboard does.
    # Wrapping in a range aggregation forces evaluation of the whole window.
    def cost(pipeline: str) -> tuple[int, int, float]:
        q = f"sum(count_over_time({pipeline} [5m]))"
        # Best of three: exec time at this data volume is mostly noise.
        best = None
        for _ in range(3):
            st = loki.stats(q, since="2h")
            if best is None or st.exec_time_s < best.exec_time_s:
                best = st
        assert best is not None
        return best.bytes_processed, best.lines_processed, best.exec_time_s

    print("PART 1 - the stream selector, which is the only thing that")
    print("         changes how much data is READ.\n")
    selectors = [
        ('{namespace="demo"}', "both apps"),
        ('{app="batch-worker"}', "one app"),
    ]
    # Pod names from a Deployment carry a random suffix, so pick a real one
    # rather than guessing a pattern.
    pods = [
        pod
        for pod in loki.label_values("pod", since="2h")
        if pod.startswith("batch-worker")
    ]
    if pods:
        selectors.append(
            (f'{{app="batch-worker", pod="{pods[0]}"}}', "one app, one pod")
        )
    base = None
    print(f"{'bytes read':>12} {'lines':>9}   selector")
    for selector, label in selectors:
        b, ln, _ = cost(selector)
        base = base or b or 1
        print(f"{b:>12,} {ln:>9,}   {selector}   ({b / base:.2f}x)  {label}")

    print("\nPART 2 - filters and parsers, which change how much data is")
    print("         PROCESSED but not how much is read.\n")
    pipelines = [
        ('{app="batch-worker"}', "no filter at all"),
        ('{app="batch-worker"} |~ "(?i)error"', "case-insensitive regex"),
        ('{app="batch-worker"} |= "error"', "plain substring"),
        ('{app="batch-worker"} |= "{" | json | __error__=""', "parse, prefiltered"),
        ('{app="batch-worker"} | json | __error__=""', "parse, NO prefilter"),
    ]
    print(f"{'bytes read':>12} {'exec':>8}   pipeline")
    for pipeline, label in pipelines:
        b, _, t = cost(pipeline)
        print(f"{b:>12,} {t:>8.4f}   {label}")
        print(f"{'':>12} {'':>8}   {pipeline}")

    print("""
Read those two tables together, because the conclusion is not the one
most people expect:

  1. Bytes read is decided by the STREAM SELECTOR and nothing else. Every
     pipeline in part 2 reads the same bytes. The line filter and the parser
     run AFTER the chunks have been fetched and decompressed - they cannot
     un-read them.

  2. So narrowing `{}` is the only change that reduces I/O, and it is the
     only stage backed by an index. Everything after it is CPU.

  3. The parser is the expensive CPU stage, and a line filter in front of it
     is what stops it running on lines that can never match. In this lab that
     difference is small and mostly lost in noise - there are only a few MB
     here. At a few hundred GB/day it is the difference between a dashboard
     that loads and one that times out.

The practical rule stays the same, but now for the right reason: narrow the
selector to cut I/O, then prefilter to cut CPU before the parser.""")


SOLUTIONS = {1: p1, 2: p2, 3: p3, 4: p4, 5: p5, 6: p6, 7: p7, 8: p8}


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        print(f"available: {', '.join(str(k) for k in SOLUTIONS)}")
        return 1

    arg = sys.argv[1]
    wanted = list(SOLUTIONS) if arg == "all" else [int(arg)]

    with LokiClient(LOKI_URL) as loki:
        # Fail fast and clearly, rather than eight confusing tracebacks.
        try:
            if not loki.labels(since="1h"):
                print(f"Loki at {LOKI_URL} has no labels in the last hour.")
                print("Is Alloy running? kubectl -n logging logs daemonset/alloy")
                return 1
        except Exception as exc:  # noqa: BLE001 - top-level guard
            print(f"cannot reach Loki at {LOKI_URL}: {exc}")
            print("\nOn the tailnet this should be http://loki:3100")
            print("Otherwise: kubectl -n logging port-forward svc/loki 3100:3100")
            print("then LOKI_URL=http://localhost:3100 python solutions.py ...")
            return 1

        for n in wanted:
            if n not in SOLUTIONS:
                print(f"no solution {n}")
                continue
            SOLUTIONS[n](loki)

    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
