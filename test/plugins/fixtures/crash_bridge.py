#!/usr/bin/env python3
"""Test fixture for SidecarClient's restart budget: a process that always dies.

argv[1]: start counter file; one line is appended per process start, so a test
         can tell how often the client respawned a crash-looping sidecar.

It lingers briefly before exiting so the client's write to stdin lands in a
live pipe, which keeps the test independent of fork/exec timing races.
"""

import sys
import time

COUNTER = sys.argv[1] if len(sys.argv) > 1 else None

if COUNTER is not None:
    with open(COUNTER, "a", encoding="utf-8") as counter:
        counter.write("start\n")

time.sleep(0.2)
sys.exit(3)
