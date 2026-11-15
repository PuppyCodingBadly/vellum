#!/usr/bin/env python3
"""Test fixture for SidecarClient: a canned line-delimited JSON bridge.

Protocol behaviours:
  ping      -> "pong"
  load_all  -> canned metadata/stores listing
  boom      -> error response
  die       -> exit(1); on the FIRST invocation only (tracked via a marker
               file passed as argv[1]); after a restart it answers
               "survived"
  slow      -> sleeps params["seconds"] (float), then answers "awake"
  delayed   -> sleeps params["seconds"], then answers params["value"]
  stderr    -> writes params["lines"] lines to stderr, then answers "ok"
  stall     -> creates the marker file (argv[1]) on the FIRST invocation only
               and never answers, as a wedged process does; after a restart
               it answers "awake"
"""

import json
import os
import sys
import time

MARKER = sys.argv[1] if len(sys.argv) > 1 else None
# A process started before the marker existed is the wedged one; a process
# started after it behaves normally, so a restart is observable.
WEDGED = MARKER is not None and not os.path.exists(MARKER)


def respond(req_id, *, result=None, error=None):
    resp = {"id": req_id}
    if error is not None:
        resp["error"] = error
    else:
        resp["result"] = result
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()


def main():
    sys.stderr.write("echo_bridge ready\n")
    sys.stderr.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method", "")
            params = req.get("params") or {}
            if method == "ping":
                respond(req_id, result="pong")
            elif method == "load_all":
                respond(req_id, result={
                    "metadata": [
                        {"name": "FakeMeta", "version": "1.0",
                         "description": "fake metadata plugin"},
                    ],
                    "stores": [
                        {"name": "FakeStore", "description": "fake store"},
                    ],
                })
            elif method == "boom":
                respond(req_id, error="kaboom")
            elif method == "die":
                if MARKER is not None and not os.path.exists(MARKER):
                    open(MARKER, "w").close()
                    sys.exit(1)
                respond(req_id, result="survived")
            elif method in ("slow", "delayed"):
                time.sleep(float(params.get("seconds", 1.0)))
                respond(req_id, result=params.get("value", "awake"))
            elif method == "stderr":
                for i in range(int(params.get("lines", 1))):
                    sys.stderr.write(f"noise {i}\n")
                sys.stderr.flush()
                respond(req_id, result="ok")
            elif method == "stall":
                if WEDGED:
                    open(MARKER, "w").close()
                    continue  # wedged: deliberately no answer
                respond(req_id, result="awake")
            else:
                respond(req_id, error=f"unknown method: {method}")
        except SystemExit:
            raise
        except Exception as exc:
            respond(req.get("id") if "req" in dir() else None, error=str(exc))


if __name__ == "__main__":
    main()
