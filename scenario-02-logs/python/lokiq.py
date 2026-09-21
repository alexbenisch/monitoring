"""
lokiq - a small, honest Loki client for scenario 02.

This started as the twenty-line httpx snippet everyone writes first:

    resp = httpx.get(f"{url}/loki/api/v1/query_range", params={...})
    return resp.json()["data"]["result"]

That snippet is correct and it is also a trap, in four specific ways. Each one
is handled below and called out in a comment, because the comment IS the
lesson:

  1. TWO TIMESTAMP FORMATS. Log queries return nanosecond strings. Metric
     queries return float seconds. Same endpoint, same field name, different
     unit. Parse them the same way and your timestamps land in 1970.

  2. `limit` SILENTLY TRUNCATES. Ask for 1000, get 1000, and there is nothing
     in the response saying "there were 40000". Combined with
     direction=backward you get the NEWEST 1000, so a naive script quietly
     analyses the wrong slice and reports a confident wrong answer.

  3. RESULT TYPE IS NOT FIXED. `data.resultType` is "streams" for log queries
     and "matrix" for metric queries. Code that assumes one crashes on the
     other, usually in production, usually at 3am.

  4. ENTRIES MAY HAVE THREE ELEMENTS. With structured metadata enabled, a
     value is [ts, line, {metadata}] rather than [ts, line]. Unpacking with
     `for ts, line in ...` raises ValueError the moment someone enables it.

Usage:

    from lokiq import LokiClient
    loki = LokiClient("http://loki:3100")

    for entry in loki.query_logs('{app="batch-worker"} |= "error"', since="1h"):
        print(entry.ts, entry.line)
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterator

import httpx

__all__ = ["LokiClient", "LogEntry", "MetricSample", "QueryStats", "parse_duration"]


# --- helpers ------------------------------------------------------------


def parse_duration(s: str) -> timedelta:
    """Accept Loki/Prometheus-style durations: 30s, 5m, 2h, 7d."""
    units = {"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}
    unit = s[-1]
    if unit not in units:
        raise ValueError(f"unknown duration {s!r}; use e.g. 30s, 5m, 2h, 7d")
    return timedelta(**{units[unit]: float(s[:-1])})


def _stream_key(labels: dict[str, str]) -> str:
    """A stable identity for a stream, for de-duplication."""
    return ",".join(f"{k}={v}" for k, v in sorted(labels.items()))


def _to_ns(dt: datetime) -> str:
    """Loki wants nanoseconds since the epoch, as a string.

    Passing an int works until the number exceeds what the receiving JSON
    parser handles as an integer, so send it as a string and stop thinking
    about it.
    """
    return str(int(dt.timestamp() * 1_000_000_000))


def _ns_to_datetime(ts_ns: int) -> datetime:
    """Convert Loki's nanosecond timestamp without going through a float.

    `datetime.fromtimestamp(ts_ns / 1e9)` looks obvious and is subtly lossy:
    a modern epoch in nanoseconds needs ~19 significant digits and float64
    carries under 16, so two entries 1000ns apart can round into the SAME
    microsecond. Integer divmod keeps every digit that datetime can hold.
    """
    seconds, remainder = divmod(int(ts_ns), 1_000_000_000)
    return datetime.fromtimestamp(seconds, tz=timezone.utc) + timedelta(
        microseconds=remainder // 1000
    )


@dataclass(frozen=True)
class LogEntry:
    """One log line, with the labels of the stream it came from."""

    ts: datetime
    line: str
    labels: dict[str, str]
    # The raw nanosecond timestamp, exactly as Loki sent it. `ts` is a
    # datetime and therefore only microsecond-resolution; keep the original
    # for anything that needs to compare or de-duplicate precisely.
    ts_ns: int = 0
    # Present only when the stream carries structured metadata (trace_id in
    # this lab). Empty dict, never None, so callers can always .get() it.
    metadata: dict[str, str] = field(default_factory=dict)

    def json(self) -> dict[str, Any] | None:
        """Parse the line as JSON, or None if it is not JSON.

        Roughly 2% of batch-worker's lines are deliberately truncated JSON.
        Returning None rather than raising is what lets you COUNT them, which
        is the whole point of exercise 3.
        """
        try:
            return json.loads(self.line)
        except (json.JSONDecodeError, ValueError):
            return None


@dataclass(frozen=True)
class MetricSample:
    """One point of a metric query result (rate, count_over_time, ...)."""

    ts: datetime
    value: float
    labels: dict[str, str]


@dataclass(frozen=True)
class QueryStats:
    """The bit of the response everyone ignores, and shouldn't.

    Read the two numbers as different things, which is exercise 4's point:

      bytes_processed  what Loki had to READ. Determined by the stream
                       selector alone - line filters and parsers run after
                       the chunks are already fetched, so they never reduce
                       it. Narrowing `{}` is the only lever here.

      exec_time_s      what Loki had to COMPUTE. This is where a regex
                       instead of a substring, or a parser with no line
                       filter in front of it, actually shows up.

    Measure with a metric query (`count_over_time`), not a bare log query: a
    small `limit` lets Loki stop early and the stats then describe the early
    exit rather than the work.
    """

    bytes_processed: int
    lines_processed: int
    exec_time_s: float
    raw: dict[str, Any]

    @classmethod
    def from_response(cls, data: dict[str, Any]) -> "QueryStats":
        s = data.get("stats", {})
        summary = s.get("summary", {})
        return cls(
            bytes_processed=summary.get("totalBytesProcessed", 0),
            lines_processed=summary.get("totalLinesProcessed", 0),
            exec_time_s=summary.get("execTime", 0.0),
            raw=s,
        )

    def __str__(self) -> str:
        mb = self.bytes_processed / 1_048_576
        return (
            f"{self.lines_processed:,} lines / {mb:,.2f} MiB "
            f"in {self.exec_time_s:.3f}s"
        )


# --- the client ---------------------------------------------------------


class LokiClient:
    def __init__(
        self,
        url: str = "http://loki:3100",
        *,
        tenant: str | None = None,
        timeout: float = 60.0,
        auth: tuple[str, str] | None = None,
        verify: bool | str = True,
    ) -> None:
        self.url = url.rstrip("/")
        headers = {}
        # auth_enabled is false in this lab, so no tenant header is needed.
        # Against any multi-tenant Loki it is mandatory, and its absence is a
        # 401 that reads like a network problem.
        if tenant:
            headers["X-Scope-OrgID"] = tenant
        self._client = httpx.Client(
            timeout=timeout, headers=headers, auth=auth, verify=verify
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "LokiClient":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    # --- plumbing -------------------------------------------------------

    def _get(self, path: str, params: dict[str, Any]) -> dict[str, Any]:
        resp = self._client.get(f"{self.url}{path}", params=params)
        if resp.status_code >= 400:
            # Loki puts the useful part in the BODY, not the status line.
            # "400 Bad Request" tells you nothing; the body says
            # "parse error at line 1, col 23: syntax error: unexpected IDENTIFIER".
            raise RuntimeError(
                f"{resp.status_code} from {path}: {resp.text.strip()[:500]}"
            )
        return resp.json()

    @staticmethod
    def _window(
        start: datetime | None, end: datetime | None, since: str | None
    ) -> tuple[datetime, datetime]:
        end = end or datetime.now(timezone.utc)
        if start is None:
            start = end - parse_duration(since or "1h")
        return start, end

    # --- log queries ----------------------------------------------------

    def query_logs(
        self,
        query: str,
        *,
        since: str | None = "1h",
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = 1000,
        direction: str = "backward",
        warn_on_truncation: bool = True,
    ) -> list[LogEntry]:
        """Run a LOG query and return a flat, time-sorted list of entries.

        Flat, because `data.result` is grouped by stream and almost nothing you
        want to do afterwards is per-stream. Iterating streams-then-values is
        how people accidentally analyse one pod instead of all of them.
        """
        # Resolve the window ONCE. Calling _window() twice would call
        # datetime.now() twice and give `start` and `end` two different
        # notions of "now" - a real bug that shows up as a window a few
        # microseconds wider than you asked for.
        win_start, win_end = self._window(start, end, since)
        data = self._get(
            "/loki/api/v1/query_range",
            {
                "query": query,
                "start": _to_ns(win_start),
                "end": _to_ns(win_end),
                "limit": limit,
                "direction": direction,
            },
        )["data"]

        if data.get("resultType") not in ("streams", None):
            raise TypeError(
                f"{query!r} is a metric query (resultType="
                f"{data.get('resultType')}); use query_metrics() instead"
            )

        entries: list[LogEntry] = []
        for stream in data.get("result", []):
            labels = stream.get("stream", {})
            for value in stream.get("values", []):
                # 2 elements normally, 3 when structured metadata is present.
                ts_ns, line = value[0], value[1]
                metadata = value[2] if len(value) > 2 else {}
                entries.append(
                    LogEntry(
                        ts=_ns_to_datetime(ts_ns),
                        line=line,
                        labels=labels,
                        ts_ns=int(ts_ns),
                        metadata=metadata or {},
                    )
                )

        entries.sort(key=lambda e: e.ts)

        if warn_on_truncation and len(entries) >= limit:
            # Not an exception: truncation is legal and often fine. But it is
            # never something you should discover by noticing your numbers
            # look small.
            import warnings

            warnings.warn(
                f"got exactly limit={limit} entries - the result is almost "
                f"certainly truncated, and with direction={direction!r} you "
                f"have the "
                f"{'newest' if direction == 'backward' else 'oldest'} "
                f"{limit}. Use iter_logs() to page through all of them.",
                stacklevel=2,
            )
        return entries

    def iter_logs(
        self,
        query: str,
        *,
        since: str | None = "24h",
        start: datetime | None = None,
        end: datetime | None = None,
        page_size: int = 1000,
    ) -> Iterator[LogEntry]:
        """Page through EVERY matching entry, oldest first.

        Loki has no cursor. You page by moving the time window: take the
        timestamp of the last entry you got and use it as the next `start`.

        The subtlety is the boundary. Several entries can share a timestamp,
        so advancing to exactly last_ts re-reads them, while advancing past it
        can skip them. This advances by the smallest step that actually exists
        and de-duplicates on (ts, line) to absorb the overlap.

        Two details that a naive version gets wrong, both found by counting
        the result against `sum(count_over_time(...))` and finding it short:

        1. The dedupe key must include the STREAM. Two pods emitting a
           byte-identical line at the same instant are two entries, not one.
        2. The window resumes AT the last timestamp, not past it, so entries
           sharing that instant cannot fall down the gap between pages.

        A timedelta cannot express a nanosecond - `timedelta(microseconds=0.001)`
        silently evaluates to `timedelta(0)` - so the guard below steps by a
        whole microsecond in the one case where the window would otherwise
        never advance.
        """
        window_start, window_end = self._window(start, end, since)
        # Key on (nanosecond, stream, line). Dropping the stream would make
        # two pods emitting an identical line at the same instant collapse
        # into one - which is not a hypothetical: it is exactly what a
        # replicated deployment logging the same startup banner does.
        seen: set[tuple[int, str, str]] = set()

        while window_start < window_end:
            batch = self.query_logs(
                query,
                start=window_start,
                end=window_end,
                limit=page_size,
                direction="forward",  # forward, so paging moves ahead
                warn_on_truncation=False,
            )
            if not batch:
                return

            for entry in batch:
                key = (entry.ts_ns, _stream_key(entry.labels), entry.line)
                if key not in seen:
                    seen.add(key)
                    yield entry

            if len(batch) < page_size:
                return  # last page

            # Resume AT the last entry's microsecond, not past it. Advancing
            # past it would skip any entry sharing that microsecond that did
            # not fit in this page; the dedupe set absorbs the re-read
            # instead. The guard is for the pathological case where an entire
            # page falls inside one microsecond - then we must step over it,
            # or the window never moves and this loops forever.
            next_start = batch[-1].ts
            if next_start <= window_start:
                next_start = window_start + timedelta(microseconds=1)
            window_start = next_start

            # Bound the memory of the dedupe set: only entries at or after
            # the new window start can be re-read, so forget everything older.
            boundary_ns = (batch[-1].ts_ns // 1000) * 1000
            seen = {k for k in seen if k[0] >= boundary_ns}

    # --- metric queries -------------------------------------------------

    def query_metrics(
        self,
        query: str,
        *,
        since: str | None = "1h",
        start: datetime | None = None,
        end: datetime | None = None,
        step: str = "60s",
    ) -> list[MetricSample]:
        """Run a METRIC query: rate(), count_over_time(), sum by (...), ...

        Note the timestamp handling. A matrix result gives FLOAT SECONDS,
        where a streams result gives NANOSECOND STRINGS. Reusing the log
        parser here divides by 1e9 twice and puts every point in January 1970.
        """
        s, e = self._window(start, end, since)
        data = self._get(
            "/loki/api/v1/query_range",
            {"query": query, "start": _to_ns(s), "end": _to_ns(e), "step": step},
        )["data"]

        if data.get("resultType") == "streams":
            raise TypeError(
                f"{query!r} is a log query, not a metric query; "
                "use query_logs() instead"
            )

        samples: list[MetricSample] = []
        for series in data.get("result", []):
            labels = series.get("metric", {})
            # An instant metric query returns "value"; a range one "values".
            points = series.get("values") or [series["value"]]
            for ts_s, value in points:
                samples.append(
                    MetricSample(
                        ts=datetime.fromtimestamp(float(ts_s), tz=timezone.utc),
                        value=float(value),
                        labels=labels,
                    )
                )
        samples.sort(key=lambda s_: s_.ts)
        return samples

    def stats(
        self,
        query: str,
        *,
        since: str | None = "1h",
        start: datetime | None = None,
        end: datetime | None = None,
    ) -> QueryStats:
        """What a query COSTS, without fetching the results."""
        s, e = self._window(start, end, since)
        data = self._get(
            "/loki/api/v1/query_range",
            {"query": query, "start": _to_ns(s), "end": _to_ns(e), "limit": 1},
        )["data"]
        return QueryStats.from_response(data)

    # --- metadata -------------------------------------------------------

    def labels(
        self, *, since: str | None = "1h", start: datetime | None = None
    ) -> list[str]:
        s, e = self._window(start, None, since)
        return self._get(
            "/loki/api/v1/labels", {"start": _to_ns(s), "end": _to_ns(e)}
        ).get("data", [])

    def label_values(
        self, label: str, *, since: str | None = "1h", start: datetime | None = None
    ) -> list[str]:
        s, e = self._window(start, None, since)
        return self._get(
            f"/loki/api/v1/label/{label}/values",
            {"start": _to_ns(s), "end": _to_ns(e)},
        ).get("data", [])

    def series(
        self, selector: str, *, since: str | None = "1h"
    ) -> list[dict[str, str]]:
        """Every STREAM matching a selector - i.e. every label combination.

        len(series(...)) is your stream count, which is the number that
        decides whether Loki is fast or miserable. Exercise 7 watches this
        number explode.
        """
        s, e = self._window(None, None, since)
        return self._get(
            "/loki/api/v1/series",
            {"match[]": selector, "start": _to_ns(s), "end": _to_ns(e)},
        ).get("data", [])

    def volume(
        self, selector: str, *, since: str | None = "1h"
    ) -> dict[str, float]:
        """Bytes ingested per stream - which log is eating your disk.

        Requires volume_enabled in limits_config, which loki.values.yaml sets.
        """
        s, e = self._window(None, None, since)
        data = self._get(
            "/loki/api/v1/index/volume",
            {"query": selector, "start": _to_ns(s), "end": _to_ns(e)},
        )["data"]
        out: dict[str, float] = {}
        for series in data.get("result", []):
            key = ",".join(f"{k}={v}" for k, v in sorted(series["metric"].items()))
            out[key] = float(series["value"][1])
        return dict(sorted(out.items(), key=lambda kv: -kv[1]))
