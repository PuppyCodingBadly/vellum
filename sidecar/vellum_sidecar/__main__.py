"""Vellum plugin sidecar entry point (``python -m vellum_sidecar``).

Reads line-delimited JSON requests from stdin and answers on the real
stdout, which only the protocol writes to.  Every request gets a response;
failures become {"id": N, "error": str}.
"""

import logging
import sys

from vellum_sidecar.bridge import Bridge
from vellum_sidecar.protocol import adopt_stdout, serve

logging.basicConfig(stream=sys.stderr, level=logging.WARNING)


def main() -> None:
    out = adopt_stdout()
    serve(Bridge(), sys.stdin, out)


if __name__ == "__main__":
    main()
