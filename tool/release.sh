#!/usr/bin/env bash
# Release Vellum in one command. See docs/releasing.md.
#
#   preflight -> Flutter build -> signed Flatpak repository and bundle ->
#   install the bundle into a throwaway user installation and check its version
#   -> publish the repository and bundle to gh-pages -> tag and GitHub release.
#
# Every step is verified before the next one starts. Anything that is missing,
# inconsistent, or unsigned aborts the run.
set -eu
set -o pipefail

APP_ID=io.github.vellum.Vellum
ARCH=x86_64
DEFAULT_PAGES_DIR=/tmp/vellum-gh
DEFAULT_FLUTTER_BUILD_CMD="flutter build linux --release"

VERSION=
DRY_RUN=false
SKIP_TESTS=false
NOTES_FILE=
PAGES_DIR=$DEFAULT_PAGES_DIR
FLUTTER_BUILD_CMD=${FLUTTER_BUILD_CMD:-$DEFAULT_FLUTTER_BUILD_CMD}
BUILDER=${BUILDER:-"flatpak run org.flatpak.Builder"}

# Filled by capture(); declared up front so `set -u` is happy in dry-run.
CAP=

usage() {
  cat <<'EOF'
Usage: tool/release.sh VERSION [options]

Release Vellum VERSION. VERSION must already be committed in pubspec.yaml and
data/io.github.vellum.Vellum.metainfo.xml, and the working tree must be clean.

Options:
  --dry-run        Run preflight and print every command without executing it.
  --skip-tests     Skip flutter analyze and flutter test in preflight.
  --notes FILE     Use FILE as the GitHub release body instead of the
                   metainfo.xml <release> description.
  --pages DIR      gh-pages worktree (default: /tmp/vellum-gh).
  -h, --help       Show this help.

Environment:
  FLUTTER_BUILD_CMD   Flutter build command (default: flutter build linux --release)
  BUILDER             flatpak-builder command (default: flatpak run org.flatpak.Builder)
  FLATPAK_GPG_KEY     Key ID or fingerprint that signs the repository (required)
  FLATPAK_GPG_HOME    GNUPGHOME containing that key (required)
EOF
}

die() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'release: warning: %s\n' "$*" >&2
}

# need skips tool checks in dry-run: a dry run must work on a host without the
# Flutter SDK, Flatpak, or a signing key.
need() {
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

# run executes a command, or prints it in dry-run. Arguments are quoted for the
# reader with %q so paths and env assignments remain unambiguous.
run() {
  if [ "$DRY_RUN" = true ]; then
    printf '  +'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# capture is run() for commands whose output the next step needs. In dry-run
# it only prints the command and leaves CAP empty; callers supply a placeholder.
capture() {
  CAP=
  if [ "$DRY_RUN" = true ]; then
    printf '  +'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  CAP=$("$@")
}

# rewrite_index replaces the three machine-readable parts of the site: the
# release sentence, the bundle link, and the SHA256 line. It is idempotent for
# the same version, summary, bundle, and checksum.
rewrite_index() {
  local index=$1
  local version=$2
  local summary=$3
  local bundle=$4
  local sha=$5
  local tmp=$index.tmp.$$

  if [ "$DRY_RUN" = true ]; then
    printf '  + rewrite %q (release sentence, bundle link, SHA256)\n' "$index"
    return 0
  fi

  [ -f "$index" ] || die "missing $index"
  SUMMARY=$summary awk -v version="$version" '
    BEGIN { replaced = 0; skipping = 0 }
    skipping {
      if (index($0, "</p>")) skipping = 0
      next
    }
    !replaced && index($0, "<p><strong>") {
      print "  <p><strong>" version "</strong> — " ENVIRON["SUMMARY"] "</p>"
      replaced = 1
      if (!index($0, "</p>")) skipping = 1
      next
    }
    { print }
  ' "$index" > "$tmp"

  sed -E -i \
    -e "s|href=\"vellum-[^\"]*-$ARCH\\.flatpak\"|href=\"$bundle\"|" \
    -e "s|>vellum-[^<]*-$ARCH\\.flatpak<|>$bundle<|" \
    -e "s|SHA256: <code>[0-9a-f]{64}</code>|SHA256: <code>$sha</code>|" \
    "$tmp"

  grep -q -F "<p><strong>$version</strong>" "$tmp" ||
    die "could not update the release sentence in $index"
  grep -q -F "href=\"$bundle\"" "$tmp" ||
    die "could not update the bundle link in $index"
  grep -q -F "SHA256: <code>$sha</code>" "$tmp" ||
    die "could not update the SHA256 in $index"
  mv "$tmp" "$index"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      ;;
    --skip-tests)
      SKIP_TESTS=true
      ;;
    --notes)
      [ "$#" -ge 2 ] || die "--notes needs a file"
      NOTES_FILE=$2
      shift
      ;;
    --pages)
      [ "$#" -ge 2 ] || die "--pages needs a directory"
      PAGES_DIR=$2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [ -z "$VERSION" ] || die "unexpected argument: $1"
      VERSION=$1
      ;;
  esac
  shift
done

if [ -z "$VERSION" ]; then
  usage >&2
  die "VERSION is required"
fi

if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "VERSION must look like MAJOR.MINOR.PATCH, not '$VERSION'"
fi

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
CALLER_DIR=$(pwd -P)
[ "$CALLER_DIR" = "$ROOT" ] ||
  die "run from the repository root: cd '$ROOT' && tool/release.sh $VERSION"

need git
need awk
need sed

GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "not inside a git worktree"
[ "$GIT_TOP" = "$ROOT" ] || die "script root '$ROOT' is not the git root '$GIT_TOP'"

ORIGIN_URL=$(git remote get-url origin 2>/dev/null) ||
  die "no 'origin' remote; configure one before releasing"
# gh-pages is pushed through an HTTPS URL so git uses the gh credential helper
# even when origin itself is an SSH remote.
PUSH_URL=$ORIGIN_URL
case $ORIGIN_URL in
  git@github.com:*)
    PUSH_URL="https://github.com/${ORIGIN_URL#git@github.com:}"
    ;;
  ssh://git@github.com/*)
    PUSH_URL="https://github.com/${ORIGIN_URL#ssh://git@github.com/}"
    ;;
esac

TAG=v$VERSION
METAINFO=$ROOT/data/$APP_ID.metainfo.xml
PUBSPEC=$ROOT/pubspec.yaml

info "Preflight for Vellum $VERSION"

if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  die "working tree is not clean; commit or stash the changes first"
fi

CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD) ||
  die "detached HEAD; check out master before releasing"
[ "$CURRENT_BRANCH" = master ] ||
  die "releases are cut from master, not '$CURRENT_BRANCH'"

RELEASE_COMMIT=$(git rev-parse HEAD)

[ -f "$PUBSPEC" ] || die "missing $PUBSPEC"
PUBSPEC_VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC")
[ -n "$PUBSPEC_VERSION" ] || die "pubspec.yaml has no version"
case $PUBSPEC_VERSION in
  "$VERSION"|"$VERSION"+*) ;;
  *) die "pubspec.yaml version '$PUBSPEC_VERSION' does not match $VERSION" ;;
esac

[ -f "$METAINFO" ] || die "missing $METAINFO"
grep -q -F "<release version=\"$VERSION\"" "$METAINFO" ||
  die "metainfo.xml has no <release version=\"$VERSION\"> entry"

if git show-ref --verify --quiet "refs/tags/$TAG"; then
  die "tag $TAG already exists locally"
fi
REMOTE_TAG=$(git ls-remote --tags "$PUSH_URL" "refs/tags/$TAG") ||
  die "cannot read tags from $PUSH_URL"
if [ -n "$REMOTE_TAG" ]; then
  die "tag $TAG already exists on the remote"
fi

if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || die "notes file not found: $NOTES_FILE"
  [ -s "$NOTES_FILE" ] || die "notes file is empty: $NOTES_FILE"
  NOTES_TEXT=$(cat "$NOTES_FILE")
else
  # The release description is the source of truth written by the developer.
  # Paragraphs become blank-line-separated plain text for the release body.
  NOTES_TEXT=$(awk -v version="$VERSION" '
    BEGIN { in_release = 0; in_desc = 0; printed = 0 }
    index($0, "<release version=\"" version "\"") { in_release = 1 }
    in_release && index($0, "<description>") { in_desc = 1; next }
    in_desc && index($0, "</description>") { exit }
    in_desc {
      if (index($0, "<p>") && printed) print ""
      line = $0
      gsub(/<[^>]*>/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line != "") {
        print line
        printed = 1
      }
    }
  ' "$METAINFO")
  if [ -z "$NOTES_TEXT" ]; then
    NOTES_TEXT="Vellum $VERSION."
  fi
fi

# The website sentence is the first release paragraph, collapsed to one line.
SUMMARY=$(printf '%s\n\n' "$NOTES_TEXT" | awk '
  BEGIN { RS = ""; ORS = "" }
  NR == 1 {
    gsub(/\n/, " ")
    gsub(/[ \t]+/, " ")
    sub(/^[ \t]+/, "")
    sub(/[ \t]+$/, "")
    print
    exit
  }
')
[ -n "$SUMMARY" ] || SUMMARY="Vellum $VERSION."
case $SUMMARY in
  *[.!?]) ;;
  *) SUMMARY="$SUMMARY." ;;
esac

# Metainfo text is already XML-escaped, so it can go into HTML unchanged. A
# --notes file is plain Markdown and must be escaped first.
if [ -n "$NOTES_FILE" ]; then
  SUMMARY=$(printf '%s' "$SUMMARY" |
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
fi

# Check every tool before the first side effect, so a missing release tool
# cannot leave a half-published release behind.
need appstreamcli
if [ "$SKIP_TESTS" != true ]; then
  need flutter
fi
need "${FLUTTER_BUILD_CMD%% *}"
need flatpak
need ostree
need "${BUILDER%% *}"
need sha256sum
need rsync
need gh

info "Validating metadata and tests"
run appstreamcli validate --no-net "$METAINFO"

if [ "$SKIP_TESTS" != true ]; then
  run flutter analyze
  run flutter test
fi

info "Building the Flutter bundle"
# FLUTTER_BUILD_CMD is a whitespace-separated command line on purpose: it lets
# the host delegate the build, for example to distrobox. Paths with spaces
# belong in a wrapper script.
# shellcheck disable=SC2086
run $FLUTTER_BUILD_CMD
BUNDLE_SRC=$ROOT/build/linux/x64/release/bundle
if [ "$DRY_RUN" != true ] && [ ! -d "$BUNDLE_SRC" ]; then
  die "Flutter build did not produce $BUNDLE_SRC"
fi

info "Packaging the signed Flatpak"

if [ -z "${FLATPAK_GPG_KEY:-}" ]; then
  if [ "$DRY_RUN" = true ]; then
    GPG_KEY=DRY_RUN_KEY
  else
    die "FLATPAK_GPG_KEY must name the key that signs the repository"
  fi
else
  GPG_KEY=$FLATPAK_GPG_KEY
fi
if [ -z "${FLATPAK_GPG_HOME:-}" ]; then
  if [ "$DRY_RUN" = true ]; then
    GPG_HOME=/dry-run/gnupg
  else
    die "FLATPAK_GPG_HOME must point at the GNUPGHOME containing that key"
  fi
else
  GPG_HOME=$FLATPAK_GPG_HOME
fi
if [ "$DRY_RUN" = true ] &&
  { [ -z "${FLATPAK_GPG_KEY:-}" ] || [ -z "${FLATPAK_GPG_HOME:-}" ]; }; then
  warn "signing environment is unset; dry run uses placeholders"
fi
GPG_ARGS=(--gpg-sign="$GPG_KEY" --gpg-homedir="$GPG_HOME")

STAGE=$ROOT/flatpak
REPO_DIR=$ROOT/build/flatpak-repo
BUILD_DIR=$ROOT/build/flatpak-build
MANIFEST=$STAGE/$APP_ID.yml
BUNDLE_NAME=vellum-$VERSION-$ARCH.flatpak
BUNDLE_FILE=$ROOT/build/$BUNDLE_NAME

run rm -rf "$STAGE/bundle" "$STAGE/sidecar" "$STAGE/data"
run cp -a "$BUNDLE_SRC" "$STAGE/bundle"
run cp -a "$ROOT/sidecar" "$STAGE/sidecar"
run cp -a "$ROOT/data" "$STAGE/data"
run find "$STAGE/sidecar" -type d \
  \( -name __pycache__ -o -name .pytest_cache \) -prune -exec rm -rf {} +

run mkdir -p "$REPO_DIR" "$BUILD_DIR"
# BUILDER is a whitespace-separated command line, like FLUTTER_BUILD_CMD.
# shellcheck disable=SC2086
run $BUILDER --force-clean --repo="$REPO_DIR" --arch="$ARCH" \
  "$BUILD_DIR" "$MANIFEST"

# Re-export the application commit with a signature and refresh appstream.
run mkdir -p "$REPO_DIR/refs/remotes"
run flatpak build-export "${GPG_ARGS[@]}" --update-appstream --arch="$ARCH" \
  "$REPO_DIR" "$BUILD_DIR" master

# Static deltas would include the unsigned appstream commit and libostree
# verifies that commit before the delta superblock, breaking every pull.
run rm -rf "$REPO_DIR/deltas" "$REPO_DIR/delta-indexes"

# build-update-repo signs the summary and generates the appstream commits.
run flatpak build-update-repo "${GPG_ARGS[@]}" "$REPO_DIR"

# Appstream commits have no signature: build-update-repo signs only the
# summary. Sign each commit through a temporary application ref, then delete
# the temporary ref.
for ref in appstream/"$ARCH" appstream2/"$ARCH"; do
  ref_file=$REPO_DIR/refs/heads/$ref
  if [ "$DRY_RUN" = true ]; then
    printf '  + cat %q\n' "$ref_file"
    commit=DRY_RUN_COMMIT
  elif [ -f "$ref_file" ]; then
    commit=$(cat "$ref_file")
  else
    continue
  fi
  run ostree --repo="$REPO_DIR" refs \
    --create="app/$APP_ID.Temp/$ARCH/master" --force "$commit"
  run flatpak build-sign "${GPG_ARGS[@]}" --arch="$ARCH" \
    "$REPO_DIR" "$APP_ID.Temp" master
  run ostree --repo="$REPO_DIR" refs \
    --delete "app/$APP_ID.Temp/$ARCH/master"
done

# Re-sign the summary over the now-signed appstream refs, without replacing
# those refs with fresh unsigned commits.
run flatpak build-update-repo "${GPG_ARGS[@]}" --no-update-appstream "$REPO_DIR"

run rm -f "$BUNDLE_FILE"
run flatpak build-bundle --arch="$ARCH" "$REPO_DIR" "$BUNDLE_FILE" "$APP_ID" master

info "Verifying the bundle"
if [ "$DRY_RUN" = true ]; then
  VERIFY_DIR=${TMPDIR:-/tmp}/vellum-verify-dry-run
else
  VERIFY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vellum-verify.XXXXXX")
  trap 'rm -rf "$VERIFY_DIR"' EXIT
fi

# A throwaway user installation proves the bundle installs without touching the
# release machine's own Flatpak installation.
run env FLATPAK_USER_DIR="$VERIFY_DIR" flatpak install --user --no-deps \
  --noninteractive --assumeyes "$BUNDLE_FILE"
capture env FLATPAK_USER_DIR="$VERIFY_DIR" flatpak info --user "$APP_ID"
if [ "$DRY_RUN" = true ]; then
  INSTALLED_VERSION=$VERSION
else
  INSTALLED_VERSION=$(printf '%s\n' "$CAP" |
    sed -n 's/^[[:space:]]*Version:[[:space:]]*//p')
fi
[ "$INSTALLED_VERSION" = "$VERSION" ] ||
  die "installed version '$INSTALLED_VERSION' does not match $VERSION"

capture sha256sum "$BUNDLE_FILE"
if [ "$DRY_RUN" = true ]; then
  SHA256=$(printf '%064d' 0)
else
  SHA256=${CAP%% *}
  case $SHA256 in
    ""|*[!0-9a-f]*) die "unexpected sha256sum output: $CAP" ;;
  esac
  [ "${#SHA256}" -eq 64 ] || die "unexpected sha256 length for $BUNDLE_FILE"
fi

info "Publishing gh-pages"
run git fetch "$PUSH_URL" gh-pages:refs/remotes/origin/gh-pages

if [ -e "$PAGES_DIR" ]; then
  [ -d "$PAGES_DIR" ] || die "$PAGES_DIR is not a directory"
  [ -e "$PAGES_DIR/.git" ] ||
    die "$PAGES_DIR exists but is not a git worktree"
  PAGES_BRANCH=$(git -C "$PAGES_DIR" rev-parse --abbrev-ref HEAD) ||
    die "cannot read the branch of $PAGES_DIR"
  [ "$PAGES_BRANCH" = gh-pages ] ||
    die "$PAGES_DIR is on '$PAGES_BRANCH', not gh-pages"
  if [ "$DRY_RUN" != true ] && [ -n "$(git -C "$PAGES_DIR" status --porcelain)" ]; then
    git -C "$PAGES_DIR" status --short >&2
    die "$PAGES_DIR has uncommitted changes; commit or discard them first"
  fi
  run git -C "$PAGES_DIR" merge --ff-only origin/gh-pages
else
  if git show-ref --verify --quiet refs/heads/gh-pages; then
    run git worktree add "$PAGES_DIR" gh-pages
  else
    run git worktree add -b gh-pages "$PAGES_DIR" origin/gh-pages
  fi
  run git -C "$PAGES_DIR" merge --ff-only origin/gh-pages
fi

# The repository is the only tracked-content replacement: rsync --delete keeps
# gh-pages free of refs and objects that were pruned locally.
run rsync -a --delete "$REPO_DIR/" "$PAGES_DIR/repo/"
# Exactly one standalone bundle stays published.
run rm -f "$PAGES_DIR"/vellum-*-"$ARCH".flatpak
run cp "$BUNDLE_FILE" "$PAGES_DIR/$BUNDLE_NAME"
rewrite_index "$PAGES_DIR/index.html" "$VERSION" "$SUMMARY" "$BUNDLE_NAME" "$SHA256"

if [ "$DRY_RUN" = true ]; then
  run git -C "$PAGES_DIR" add --all
  run git -C "$PAGES_DIR" commit -m "Publish Vellum $VERSION flatpak repo and bundle"
  run git -C "$PAGES_DIR" push "$PUSH_URL" gh-pages
else
  if [ -n "$(git -C "$PAGES_DIR" status --porcelain)" ]; then
    run git -C "$PAGES_DIR" add --all
    run git -C "$PAGES_DIR" commit -m "Publish Vellum $VERSION flatpak repo and bundle"
  fi
  PAGES_HEAD=$(git -C "$PAGES_DIR" rev-parse HEAD)
  PAGES_REMOTE=$(git -C "$PAGES_DIR" rev-parse origin/gh-pages)
  if [ "$PAGES_HEAD" != "$PAGES_REMOTE" ]; then
    run git -C "$PAGES_DIR" push "$PUSH_URL" gh-pages
  else
    info "gh-pages already matches this release; nothing to push"
  fi
fi

info "Tagging and creating the GitHub release"
if [ "$DRY_RUN" != true ]; then
  [ "$(git rev-parse HEAD)" = "$RELEASE_COMMIT" ] ||
    die "HEAD moved during the release; refusing to tag a different commit"
  [ -z "$(git status --porcelain)" ] ||
    die "working tree changed during the release; refusing to tag"
fi

if [ -n "$NOTES_FILE" ]; then
  NOTES_PATH=$NOTES_FILE
else
  NOTES_PATH=$ROOT/build/release-notes-$VERSION.md
  if [ "$DRY_RUN" != true ]; then
    mkdir -p "$ROOT/build"
    printf '%s\n' "$NOTES_TEXT" > "$NOTES_PATH"
  fi
fi

run git tag -a "$TAG" -m "Vellum $VERSION" "$RELEASE_COMMIT"
run git push "$PUSH_URL" master
run git push "$PUSH_URL" "refs/tags/$TAG"
run gh release create "$TAG" "$BUNDLE_FILE" \
  "$ROOT/$APP_ID.flatpakref" "$ROOT/$APP_ID.flatpakrepo" \
  --title "Vellum $VERSION" --notes-file "$NOTES_PATH" --latest

if [ "$DRY_RUN" = true ]; then
  printf 'Dry run complete: nothing was built, signed, published, tagged, or released.\n'
  exit 0
fi

printf 'Released Vellum %s\n' "$VERSION"
printf '  bundle: %s\n' "$BUNDLE_FILE"
printf '  sha256: %s\n' "$SHA256"
