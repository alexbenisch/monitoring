# Stdlib only - no requirements.txt, nothing to install, no wheel cache to bust.
FROM python:3.12-slim

WORKDIR /app
COPY batchworker.py .

# PYTHONUNBUFFERED is belt-and-braces: batchworker.py flushes every line
# itself, but if you ever add a library that writes to stdout, this keeps its
# output in the right order relative to ours.
ENV PYTHONUNBUFFERED=1

USER 65532:65532
ENTRYPOINT ["python", "-u", "batchworker.py"]
