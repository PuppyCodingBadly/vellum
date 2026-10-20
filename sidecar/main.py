#!/usr/bin/env python3
"""Vellum plugin sidecar entry point.

Reads line-delimited JSON requests from stdin and writes line-delimited JSON
responses to stdout, flushing after each.  Every request gets a response;
failures become {"id": N, "error": str}.
"""

import json
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from vellum_sidecar.bridge import Bridge

logging.basicConfig(stream=sys.stderr, level=logging.WARNING)


def main() -> None:
    bridge = Bridge()
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = None
        try:
            req = json.loads(line)
            req_id = req.get("id")
            result = bridge.dispatch(req.get("method", ""), req.get("params") or {})
            resp = {"id": req_id, "result": result}
        except Exception as exc:  # catch-all per request
            logging.getLogger(__name__).exception("request failed")
            resp = {"id": req_id, "error": str(exc)}
        out.write(json.dumps(resp) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
