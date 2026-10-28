#!/bin/sh
# Run the test suites with coverage and print per-file summaries.
#
# Any extra arguments are passed to flutter test.
set -eu

# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

echo "== Flutter tests =="
flutter test --coverage "$@"

echo
echo "== Dart line coverage (coverage/lcov.info) =="
awk -F: '
  /^SF:/ {
    file = substr($0, 4)
    files[++n] = file
  }
  /^DA:/ {
    split($2, parts, ",")
    found[file]++
    if (parts[2] + 0 > 0) hit[file]++
  }
  END {
    for (i = 1; i <= n; i++) {
      f = files[i]
      pct = found[f] ? 100.0 * hit[f] / found[f] : 100
      printf "%6.2f%%  %4d/%-4d  %s\n", pct, hit[f], found[f], f
      total_hit += hit[f]
      total_found += found[f]
    }
    if (total_found)
      printf "%6.2f%%  %4d/%-4d  TOTAL\n", \
        100.0 * total_hit / total_found, total_hit, total_found
  }
' coverage/lcov.info

if command -v genhtml >/dev/null 2>&1; then
  genhtml -q coverage/lcov.info -o coverage/html
  echo "HTML report: $ROOT/coverage/html/index.html"
else
  echo "genhtml not found on PATH; skipping HTML report (dnf install lcov)."
fi

if [ -d sidecar/vellum_sidecar ]; then
  echo
  echo "== Sidecar tests =="
  if python3 -c 'import coverage' >/dev/null 2>&1; then
    python3 -m coverage run --source=sidecar/vellum_sidecar -m pytest sidecar/tests -q
    echo
    echo "== Python line coverage (sidecar/vellum_sidecar) =="
    python3 -m coverage report
  else
    echo "python coverage.py not installed; skipping sidecar coverage" \
      "(pip install --user coverage)."
  fi
fi
