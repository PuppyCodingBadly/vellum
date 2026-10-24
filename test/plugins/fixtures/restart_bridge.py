#!/usr/bin/env python3
"""Sidecar fixture for plugin-registry restoration tests.

argv[1]: counter file; one line is appended per `load_all` call.
argv[2]: marker file; the first `die` call exits the process, later calls
         answer "survived".

Each process starts with an empty plugin registry (`loaded = False`), so
`metadata_search` fails until `load_all` runs. That makes a missing reload
after a crash visible as an error instead of silently empty results.
"""

import json
import os
import sys

COUNTER = sys.argv[1] if len(sys.argv) > 1 else None
MARKER = sys.argv[2] if len(sys.argv) > 2 else None

loaded = False


def respond(req_id, *, result=None, error=None):
    resp = {"id": req_id}
    if error is not None:
        resp["error"] = error
    else:
        resp["result"] = result
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()


def main():
    global loaded
    sys.stderr.write("restart_bridge ready\n")
    sys.stderr.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        req_id = req.get("id")
        method = req.get("method", "")
        if method == "ping":
            respond(req_id, result="pong")
        elif method == "load_all":
            loaded = True
            if COUNTER is not None:
                with open(COUNTER, "a", encoding="utf-8") as counter:
                    counter.write("load\n")
            respond(req_id, result={
                "metadata": [
                    {"name": "FakeMeta", "version": "1.0",
                     "description": "fake metadata plugin"},
                ],
                "stores": [],
            })
        elif method == "metadata_search":
            if not loaded:
                respond(req_id, error="plugin registry empty")
            else:
                respond(req_id, result=[
                    {"title": "Result", "authors": ["Someone"],
                     "source": "FakeMeta"},
                ])
        elif method == "die":
            if MARKER is not None and not os.path.exists(MARKER):
                open(MARKER, "w").close()
                sys.exit(1)
            respond(req_id, result="survived")
        else:
            respond(req_id, error=f"unknown method: {method}")


if __name__ == "__main__":
    main()
