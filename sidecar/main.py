#!/usr/bin/env python3
"""Vellum plugin sidecar entry point.

Thin wrapper around ``python -m vellum_sidecar`` so the bridge can also be
started as a plain script (e.g. by the Flutter app's sidecar client).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from vellum_sidecar.__main__ import main

if __name__ == "__main__":
    main()
