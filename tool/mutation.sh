#!/bin/sh
# Mutation testing entry points for vellum.
# See docs/mutation-testing.md for details.
#
# Usage:
#   tool/mutation.sh            incremental: the configured scope's changes vs HEAD~1
#   tool/mutation.sh --full     full Dart run over everything in mutation_test.xml
#   tool/mutation.sh --sidecar  Python sidecar only (mutmut)
#   tool/mutation.sh --all      full Dart run + Python sidecar
set -eu

# Run from the repository root regardless of the caller's cwd.
cd "$(dirname "$0")/.."

# Make the Flutter SDK available if it is not already on PATH.
if ! command -v flutter >/dev/null 2>&1 && [ -d "$HOME/src/flutter-sdk/flutter/bin" ]; then
  PATH="$HOME/src/flutter-sdk/flutter/bin:$PATH"
  export PATH
fi

# The pdfium the PDF tests load is resolved by the app itself: PDFIUM_PATH when
# set, else ~/.local/share/vellum-flutter/pdfium, else the system library.

if [ -f coverage/lcov.info ]; then
  COVERAGE_ARGS="--coverage coverage/lcov.info"
else
  COVERAGE_ARGS=""
  echo "mutation.sh: coverage/lcov.info not found; running without --coverage (slower)." >&2
  echo "mutation.sh: run tool/coverage.sh first to generate it." >&2
fi

run_dart_incremental() {
  # .dart files under lib/ touched by the last commit, in the same scope as
  # mutation_test.xml: the UI and main() are excluded there because widget
  # mutants are slow and mostly unkillable, so they are not mutated here
  # either. test/ and non-Dart files are dropped by the filters.
  changed=$(git diff --name-only HEAD HEAD~1 \
    | grep -E '^lib/.*\.dart$' \
    | grep -vE '^(lib/ui/|lib/main\.dart$)' || true)
  if [ -z "$changed" ]; then
    echo "mutation.sh: no mutable lib/*.dart changes vs HEAD~1; nothing to mutate (use --full for a complete run)"
    return 0
  fi
  echo "mutation.sh: incremental mutation run over:"
  echo "$changed"
  # shellcheck disable=SC2086 # intentional word splitting of file list
  dart run mutation_test $COVERAGE_ARGS $changed
}

run_dart_full() {
  # shellcheck disable=SC2086
  dart run mutation_test $COVERAGE_ARGS mutation_test.xml
}

run_sidecar() {
  if ! python3 -c 'import mutmut' >/dev/null 2>&1; then
    echo "mutation.sh: mutmut is not installed; install it with: pip install --user mutmut" >&2
    echo "mutation.sh: skipping Python sidecar mutation testing" >&2
    return 0
  fi
  (cd sidecar && python3 -m mutmut run && python3 -m mutmut results)
}

case "${1:-}" in
  "")        run_dart_incremental ;;
  --full)    run_dart_full ;;
  --sidecar) run_sidecar ;;
  --all)     run_dart_full; run_sidecar ;;
  *)
    echo "usage: $0 [--full|--sidecar|--all]" >&2
    exit 2
    ;;
esac
