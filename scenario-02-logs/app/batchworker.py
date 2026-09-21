"""
obs-lab batch-worker - a deliberately badly-behaved log producer.

Where demoapp emits clean JSON, this thing emits what you actually find in
production: four different formats from the same process, multi-line stack
traces, a steady drizzle of low-value noise, and the occasional malformed
record that will silently break your parser.

Every exercise in scenario 02 that involves parsing points at this workload.

Log shapes emitted, and the exercise each one exists for:

  logfmt      ts=.. level=info msg=".." job=.. run_id=.. upstream=..
              -> `| logfmt`, label filters on parsed fields

  plain       2026-09-21 16:04:11 WARN  retry 3/5 upstream=billing backoff_ms=800
              -> `| pattern` and `| regexp`, because nothing else will read it

  java        Exception in thread "main" java.lang.IllegalStateException: ..
                  at com.acme.billing.Charger.charge(Charger.java:88)
              -> multi-line handling. Without stage.multiline in Alloy these
                 arrive as 9 separate, individually useless lines.

  json        {"ts":"..","level":"..","msg":"..","duration_ms":123,..}
              -> `| json`, `unwrap`, quantile_over_time

  malformed   {"ts":"..","level":"error","msg":"unterminated
              -> `__error__="JSONParserErr"`. Roughly 2% of JSON lines. The
                 lesson is that `| json | level="error"` silently drops these,
                 so your error count is wrong and nothing tells you.

Planted incidents, for the hunting exercises:

  1. BILLING SLOW BURN. `upstream=billing` degrades on a ~20 minute cycle:
     retries climb from ~0 to ~9 per minute, duration_ms roughly triples, then
     it recovers. Visible with rate() by upstream, invisible in any single line.

  2. THE POISON RECORD. record_id=REC-4417709 fails every single time it is
     picked up, about once every 3 minutes, and is the only record that does.
     Findable by counting failures by record_id.

  3. FATAL, RARELY. One FATAL line roughly every 20 minutes. It is one line in
     tens of thousands - the needle exercise.

Env:
  LOG_RATE          lines/sec, default 8
  CHAOS_LEVEL       0..3, default 0. Raises failure rate and retry pressure.
  NOISE_RATIO       0..1, default 0.55. Share of lines that are pure noise.
  MALFORMED_RATIO   0..1, default 0.02. Share of JSON lines that are broken.
  WORKER_NAME       defaults to hostname
"""

import json
import os
import random
import socket
import sys
import time
import uuid
from datetime import datetime, timezone

LOG_RATE = float(os.getenv("LOG_RATE", "8"))
CHAOS_LEVEL = int(os.getenv("CHAOS_LEVEL", "0"))
NOISE_RATIO = float(os.getenv("NOISE_RATIO", "0.55"))
MALFORMED_RATIO = float(os.getenv("MALFORMED_RATIO", "0.02"))
WORKER_NAME = os.getenv("WORKER_NAME", socket.gethostname())

UPSTREAMS = ["billing", "inventory", "shipping", "identity"]
JOBS = ["nightly-reconcile", "invoice-export", "stock-sync", "audit-sweep"]

# Incident 2. This one record is cursed and always will be.
POISON_RECORD = "REC-4417709"

# Incident 1. Billing's degradation follows this cycle, in seconds.
BILLING_CYCLE_S = 20 * 60

START = time.monotonic()


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def now_plain() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def emit(line: str) -> None:
    """One write, one flush.

    Unbuffered matters more than it looks: with block buffering the container
    runtime gets logs in 4KB bursts, every line in a burst lands within the
    same millisecond, and your rate() graphs turn into a comb. This is a real
    and very common cause of 'why is my log rate spiky'.
    """
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def billing_pressure() -> float:
    """0.0 healthy .. 1.0 fully degraded, on a sawtooth."""
    phase = ((time.monotonic() - START) % BILLING_CYCLE_S) / BILLING_CYCLE_S
    # Ramp for the first 70% of the cycle, then recover sharply.
    return phase / 0.7 if phase < 0.7 else max(0.0, (1.0 - phase) / 0.3)


def upstream_health(upstream: str) -> float:
    base = 0.05 + CHAOS_LEVEL * 0.08
    if upstream == "billing":
        base += billing_pressure() * 0.45
    return min(base, 0.95)


# --- the individual log shapes -----------------------------------------


def line_noise() -> None:
    """High volume, near-zero value. Every real system is mostly this."""
    choice = random.random()
    if choice < 0.4:
        emit(
            f"ts={now_iso()} level=debug msg=\"heartbeat\" worker={WORKER_NAME} "
            f"queue_depth={random.randint(0, 40)}"
        )
    elif choice < 0.7:
        emit(
            f"{now_plain()} DEBUG connection pool stats active="
            f"{random.randint(1, 8)} idle={random.randint(0, 12)} max=16"
        )
    elif choice < 0.9:
        emit(
            f"ts={now_iso()} level=debug msg=\"cache lookup\" "
            f"hit={'true' if random.random() < 0.8 else 'false'} "
            f"key=sku:{random.randint(1000, 9999)}"
        )
    else:
        emit(
            f"[GC] pause young {random.randint(8, 60)}ms heap="
            f"{random.randint(200, 900)}M/1024M"
        )


def line_job_start(job: str, run_id: str) -> None:
    emit(
        f"ts={now_iso()} level=info msg=\"job started\" job={job} "
        f"run_id={run_id} worker={WORKER_NAME} batch_size={random.randint(50, 500)}"
    )


def line_retry(upstream: str, attempt: int, total: int) -> None:
    backoff = 100 * (2 ** (attempt - 1))
    emit(
        f"{now_plain()} WARN  retry {attempt}/{total} upstream={upstream} "
        f"backoff_ms={backoff} reason=timeout"
    )


def line_record_ok(job: str, run_id: str, record_id: str, upstream: str) -> None:
    dur = random.gauss(120, 40)
    if upstream == "billing":
        dur *= 1 + billing_pressure() * 2.2
    payload = {
        "ts": now_iso(),
        "level": "info",
        "msg": "record processed",
        "job": job,
        "run_id": run_id,
        "record_id": record_id,
        "upstream": upstream,
        "duration_ms": round(max(5.0, dur), 1),
        "worker": WORKER_NAME,
    }
    emit(json.dumps(payload, separators=(",", ":")))


def line_record_fail(job: str, run_id: str, record_id: str, upstream: str) -> None:
    dur = random.gauss(800, 250)
    payload = {
        "ts": now_iso(),
        "level": "error",
        "msg": "record failed",
        "job": job,
        "run_id": run_id,
        "record_id": record_id,
        "upstream": upstream,
        "duration_ms": round(max(20.0, dur), 1),
        "error": random.choice(
            ["deadline exceeded", "connection reset", "409 conflict", "schema mismatch"]
        ),
        "worker": WORKER_NAME,
    }
    emit(json.dumps(payload, separators=(",", ":")))


def line_malformed() -> None:
    """Truncated JSON, exactly as a crashing writer produces it."""
    emit(
        f'{{"ts":"{now_iso()}","level":"error","msg":"unterminated record '
        f'{random.randint(1000, 9999)}'
    )


def line_stack_trace(upstream: str, record_id: str) -> None:
    """Java-style multi-line exception. Nine lines, one event."""
    emit(
        'Exception in thread "batch-worker" java.lang.IllegalStateException: '
        f"upstream {upstream} returned no settlement for {record_id}"
    )
    emit("\tat com.acme.billing.Charger.charge(Charger.java:88)")
    emit("\tat com.acme.billing.Charger.settle(Charger.java:142)")
    emit("\tat com.acme.batch.RecordHandler.handle(RecordHandler.java:61)")
    emit("\tat com.acme.batch.Worker.runBatch(Worker.java:42)")
    emit("\tat com.acme.batch.Worker.main(Worker.java:19)")
    emit("Caused by: java.net.SocketTimeoutException: Read timed out")
    emit("\tat java.base/java.net.SocketInputStream.read(SocketInputStream.java:204)")
    emit("\t... 5 more")


def line_fatal() -> None:
    emit(
        f"ts={now_iso()} level=fatal msg=\"unrecoverable: ledger checksum mismatch\" "
        f"worker={WORKER_NAME} ledger=2026-09-21 expected=8f3a91c actual=1d77e02 "
        f"action=halting_batch"
    )


# --- the loop -----------------------------------------------------------


def main() -> None:
    emit(
        f"ts={now_iso()} level=info msg=\"batch-worker starting\" "
        f"worker={WORKER_NAME} chaos_level={CHAOS_LEVEL} log_rate={LOG_RATE} "
        f"version=1.0.0"
    )

    interval = 1.0 / LOG_RATE if LOG_RATE > 0 else 0.125
    run_id = str(uuid.uuid4())[:8]
    job = random.choice(JOBS)
    records_left = random.randint(20, 60)
    last_fatal = time.monotonic()
    last_poison = time.monotonic()

    while True:
        time.sleep(interval)

        # Incident 3: a FATAL roughly every 20 minutes.
        if time.monotonic() - last_fatal > 20 * 60:
            line_fatal()
            last_fatal = time.monotonic()
            continue

        if random.random() < NOISE_RATIO:
            line_noise()
            continue

        # New run?
        if records_left <= 0:
            emit(
                f"ts={now_iso()} level=info msg=\"job finished\" job={job} "
                f"run_id={run_id} worker={WORKER_NAME}"
            )
            run_id = str(uuid.uuid4())[:8]
            job = random.choice(JOBS)
            records_left = random.randint(20, 60)
            line_job_start(job, run_id)
            continue

        records_left -= 1
        upstream = random.choice(UPSTREAMS)

        # Incident 2: the poison record, about every 3 minutes.
        if time.monotonic() - last_poison > 180:
            last_poison = time.monotonic()
            line_record_fail(job, run_id, POISON_RECORD, "billing")
            line_stack_trace("billing", POISON_RECORD)
            continue

        record_id = f"REC-{random.randint(1000000, 9999999)}"
        fail_chance = upstream_health(upstream)

        if random.random() < fail_chance:
            attempts = random.randint(1, 3 + CHAOS_LEVEL)
            for attempt in range(1, attempts + 1):
                line_retry(upstream, attempt, attempts + 1)
            if random.random() < 0.45:
                line_record_fail(job, run_id, record_id, upstream)
                if random.random() < 0.25:
                    line_stack_trace(upstream, record_id)
            else:
                # Recovered after retrying. Counts as success, but the retries
                # are the early warning - exercise 5 is about exactly this.
                line_record_ok(job, run_id, record_id, upstream)
        elif random.random() < MALFORMED_RATIO:
            line_malformed()
        else:
            line_record_ok(job, run_id, record_id, upstream)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
