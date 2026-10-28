# Mutation testing

Mutation testing makes small, deliberate changes ("mutants") to the source
code — flipping operators, negating conditions, tweaking literals — and then
runs the test suite against each mutant. A mutant that the tests catch is
"killed"; one that slips through "survived" and points at a gap in the test
suite. The percentage of killed mutants (the mutation score) measures how
sensitive the tests really are to behavioral changes.

Vellum uses two mutation testers:

- **Dart interior logic** — the [`mutation_test`](https://pub.dev/packages/mutation_test)
  package, configured by `mutation_test.xml` at the repo root. Scope:
  `lib/core`, `lib/formats`, `lib/fts`, `lib/import`, `lib/metadata`,
  `lib/plugins`, `lib/reader`, `lib/stats`, `lib/store`, and
  `lib/app_state.dart`. `lib/ui` and `lib/main.dart` are excluded.
- **Python sidecar** — [mutmut](https://mutmut.readthedocs.io/) 3.x,
  configured by `sidecar/setup.cfg` (`source_paths = vellum_sidecar`,
  tests in `sidecar/tests` run via pytest).

## Running

All modes go through `tool/mutation.sh` (run it from anywhere; it cds to the
repo root):

```sh
tool/mutation.sh            # incremental: the configured scope's files changed vs HEAD~1
tool/mutation.sh --full     # full Dart run over everything in mutation_test.xml
tool/mutation.sh --sidecar  # Python sidecar only (mutmut run + mutmut results)
tool/mutation.sh --all      # full Dart run + Python sidecar
```

The incremental mode only mutates files inside `mutation_test.xml`'s scope
(`lib/ui` and `lib/main.dart` are outside it), so a UI-only change has
nothing to mutate.

Run `tool/coverage.sh` first: when `coverage/lcov.info` exists it is passed to
`mutation_test --coverage`, which skips mutating lines the tests never execute
and is significantly faster. Without it the script still works but warns that
the run will be slower.

The Dart test suite needs the pdfium shared library, which the PDF format
code resolves itself: `PDFIUM_PATH` when set and present, else
`~/.local/share/vellum-flutter/pdfium/lib/libpdfium.so`, else the system
loader path. If mutmut is not installed, the sidecar mode prints
`pip install --user mutmut` and skips without failing.

## Results

- **Dart**: an HTML report is written to `./mutation-test-report/`
  (open `mutation-test-report/mutation-test-report.html`). The run fails
  (non-zero exit) when the mutation score falls below the **70%** threshold
  configured via `<threshold failure="70"/>` in `mutation_test.xml`.
- **Sidecar**: `mutmut run` stores per-mutant results under `sidecar/mutants/`;
  `mutmut results` prints the killed/survived summary to the terminal, and
  `python3 -m mutmut browse` (from `sidecar/`) opens an interactive viewer.
  Both `mutation-test-report/` and `sidecar/mutants/` are git-ignored.
