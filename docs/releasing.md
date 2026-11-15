# Releasing Vellum

`tool/release.sh` cuts a release in one command. It refuses to continue when
any precondition or verification fails, so a version that reaches the website,
the Flatpak repository, and GitHub has passed every gate.

```sh
tool/release.sh 0.3.2
```

The version must already be committed:

- `pubspec.yaml` contains `version: 0.3.2` or `version: 0.3.2+BUILD`.
- `data/io.github.vellum.Vellum.metainfo.xml` contains a
  `<release version="0.3.2" date="...">` entry with a `<description>`.
- The working tree is clean and the current branch is `master`.

The commit that contains those changes is the release commit. The script tags
that exact commit at the end, after building and publishing, and refuses to tag
if `HEAD` moved during the run.

## Usage

```
tool/release.sh VERSION [--dry-run] [--skip-tests] [--notes FILE] [--pages DIR]
```

| Option | Effect |
| --- | --- |
| `--dry-run` | Run preflight and print every command without executing it. |
| `--skip-tests` | Skip `flutter analyze` and `flutter test` in preflight. |
| `--notes FILE` | Use `FILE` as the GitHub release body instead of the metainfo description. |
| `--pages DIR` | Use `DIR` as the gh-pages worktree. Default: `/tmp/vellum-gh`. |

`--notes` is useful when the release body needs Markdown that the metainfo
entry cannot express. The first paragraph also becomes the sentence next to
the version on the website; markup in that paragraph is escaped rather than
interpreted.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `FLUTTER_BUILD_CMD` | `flutter build linux --release` | Command that produces `build/linux/x64/release/bundle`. |
| `BUILDER` | `flatpak run org.flatpak.Builder` | flatpak-builder command. |
| `FLATPAK_GPG_KEY` | none, required | Key ID or fingerprint that signs commits and the summary. |
| `FLATPAK_GPG_HOME` | none, required | `GNUPGHOME` that contains `FLATPAK_GPG_KEY`. |

`FLUTTER_BUILD_CMD` and `BUILDER` are split on whitespace, like a simple
command line, so shell quoting, pipelines, and `VAR=value` prefixes do not
work inside them. Put anything more complex in a wrapper script.

When the host has no Flutter SDK or cmake, build inside a development
container. For example, from the repository root:

```sh
FLUTTER_BUILD_CMD="distrobox enter flutter-dev -- flutter build linux --release" \
  tool/release.sh 0.3.2 --skip-tests
```

`--skip-tests` is needed there because the host cannot run `flutter analyze` or
`flutter test`; run those inside the container separately. If `distrobox` is
not on `PATH`, `tool/release.sh` stops before building.

## The pipeline

### 1. Preflight

The script verifies, in order:

1. It is running from the repository root, inside the git worktree.
2. The working tree is clean and `master` is checked out.
3. `VERSION` is `MAJOR.MINOR.PATCH`.
4. `pubspec.yaml` agrees with `VERSION`.
5. The metainfo file has a `<release version="VERSION">` entry.
6. The tag `vVERSION` does not exist locally or on the remote.
7. `appstreamcli validate --no-net` passes.
8. `flutter analyze` and `flutter test` pass, unless `--skip-tests`.

Missing tools, an unreadable notes file, and a failed check all abort before
anything is built.

### 2. Build

`FLUTTER_BUILD_CMD` runs and must leave
`build/linux/x64/release/bundle` behind. The script checks for the directory
and aborts if the build reported success without producing it.

### 3. Package

The bundle, `sidecar/`, and `data/` are staged into `flatpak/`, then packaged
with `BUILDER` into `build/flatpak-repo`.

Signing is mandatory. The repository is exported and the summary is signed
with `FLATPAK_GPG_KEY` from `FLATPAK_GPG_HOME`. Static deltas are removed:
they would include the unsigned appstream commit, and libostree verifies that
commit before the delta superblock, so every pull would fail. The appstream
commits are signed through a temporary app ref, and the summary is signed
again with `--no-update-appstream` so the signed appstream refs survive.

The result is `build/vellum-VERSION-x86_64.flatpak`.

### 4. Verify the artifact

The bundle is installed with

```sh
FLATPAK_USER_DIR=$(mktemp -d) flatpak install --user --no-deps --noninteractive \
  build/vellum-VERSION-x86_64.flatpak
```

and `flatpak info` must report `Version: VERSION`. The temporary user
installation is removed afterwards. The script then computes the SHA256 of the
bundle. Any mismatch aborts before publishing.

This proves that the file users download installs and carries the intended
version. It does not replace testing the app itself.

### 5. Publish gh-pages

The script uses or creates a worktree for the `gh-pages` branch at `--pages`
(default `/tmp/vellum-gh`), fast-forwards it, and rsyncs `build/flatpak-repo/`
with `--delete` into `repo/`. The previous `vellum-*-x86_64.flatpak` bundle is
replaced by the new one.

`index.html` is edited idempotently:

- the sentence next to `<strong>VERSION</strong>` becomes the first release
  paragraph;
- the direct-download link and its text point at the new bundle name;
- the `SHA256:` line carries the checksum computed in step 4.

The change is committed and pushed as `gh-pages`. The push uses an HTTPS URL
derived from `origin`, even when `origin` itself is SSH, so git uses the
configured GitHub credential helper (for example `gh auth git-credential`).
If the contents already match the release, the commit and push are skipped.

### 6. Tag and release

The script asserts that `HEAD` is still the release commit and the tree is
still clean, creates the annotated tag `vVERSION`, pushes `master` and the tag,
and creates the GitHub release:

```sh
gh release create vVERSION build/vellum-VERSION-x86_64.flatpak \
  --title "Vellum VERSION" --notes-file NOTES --latest
```

Without `--notes`, the release body is extracted from the metainfo
`<description>`. The bundle is the release asset. The tag and the GitHub
release are created last; nothing is tagged until the artifact has been
verified and the website has been published.

## Signing key

`FLATPAK_GPG_KEY` and `FLATPAK_GPG_HOME` are required. The public key in
`io.github.vellum.Vellum.flatpakrepo` and
`io.github.vellum.Vellum.flatpakref` must match that secret key; otherwise
clients reject the signed commits and summary.

A typical setup:

```sh
export FLATPAK_GPG_HOME=$HOME/.gnupg-vellum
export FLATPAK_GPG_KEY=0123456789ABCDEF
gpg --homedir "$FLATPAK_GPG_HOME" --list-secret-keys "$FLATPAK_GPG_KEY"
```

The script aborts before packaging when either variable is unset. It passes
both `--gpg-sign` and `--gpg-homedir` to `flatpak build-export`,
`flatpak build-sign`, and `flatpak build-update-repo`.

## Dry run

```sh
tool/release.sh 0.3.2 --dry-run
```

A dry run performs the preflight checks that do not need the release
toolchain: repository state, version consistency, tag absence, and notes
parsing. It then prints every command it would run, including the build,
signing, verification, rsync, git, and `gh` commands. It does not invoke
Flutter, Flatpak, flatpak-builder, ostree, rsync, or gh, does not create a
worktree or temporary installation, does not modify `index.html`, and does not
push, tag, or publish anything.

Values that only exist after a real build are shown as placeholders:
`DRY_RUN_KEY`/`/dry-run/gnupg` for an unset signing key, `DRY_RUN_COMMIT` for
appstream commits, and an all-zero SHA256. A dry run works on a host without
Flutter, Flatpak, or a signing key.

## Failure and recovery

Every step fails closed. The release commit is tagged only at the end, so a
failure before step 6 leaves no tag behind. Common recoveries:

- Build, packaging, or verification failed: fix the cause, commit the fix,
  and rerun. The working tree must be clean, so uncommitted debug edits must
  be removed or committed.
- gh-pages push failed: the local gh-pages worktree has the commit. Push it
  again or rerun. The script skips an unchanged gh-pages.
- The tag exists locally but the push or GitHub release failed: push the tag
  and create the release manually with the same commands printed by
  `--dry-run`, or delete the local tag with `git tag -d vVERSION` and rerun
  after confirming the remote tag is absent and the artifact is current.
- A previous run already created the release: do not rerun the script for the
  same version; it will refuse because the tag exists.

## Relation to `tool/build-flatpak.sh`

`tool/build-flatpak.sh` is a developer convenience: it runs the Flutter build
directly, signs only when a key happens to be in the environment, and stops at
a local repository. It does not bundle, verify, publish, or tag.

`tool/release.sh` is the release path. It requires signing, produces the
versioned bundle, verifies it in a throwaway installation, updates gh-pages,
and creates the tag and GitHub release. Use the build script for local
experiments; use the release script for anything users will install.
