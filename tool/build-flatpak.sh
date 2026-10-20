#!/bin/sh
# Build the Flutter release bundle and package it as a Flatpak.
#
# Environment:
#   REPO_DIR         export repository (default: build/flatpak-repo)
#   BUILDER          flatpak-builder command (default: flatpak run org.flatpak.Builder)
#   FLATPAK_GPG_KEY  key ID/fingerprint used to sign repository summaries
#   FLATPAK_GPG_HOME GNUPGHOME containing that key
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

REPO_DIR=${REPO_DIR:-$ROOT/build/flatpak-repo}
BUILDER=${BUILDER:-"flatpak run org.flatpak.Builder"}
BUILD_DIR=$ROOT/build/flatpak-build

flutter build linux --release

rm -rf "$ROOT/flatpak/bundle" "$ROOT/flatpak/sidecar" "$ROOT/flatpak/data"
cp -a "$ROOT/build/linux/x64/release/bundle" "$ROOT/flatpak/bundle"
cp -a "$ROOT/sidecar" "$ROOT/flatpak/sidecar"
cp -a "$ROOT/data" "$ROOT/flatpak/data"
find "$ROOT/flatpak/sidecar" -type d \( -name __pycache__ -o -name .pytest_cache \) -prune -exec rm -rf {} +

mkdir -p "$REPO_DIR" "$BUILD_DIR"
$BUILDER --force-clean --repo="$REPO_DIR" --arch=x86_64 "$BUILD_DIR" "$ROOT/flatpak/io.github.vellum.Vellum.yml"

if [ -n "${FLATPAK_GPG_KEY:-}" ]; then
  if [ -n "${FLATPAK_GPG_HOME:-}" ]; then
    flatpak build-update-repo --gpg-sign="$FLATPAK_GPG_KEY" --gpg-homedir="$FLATPAK_GPG_HOME" --generate-static-deltas "$REPO_DIR"
  else
    flatpak build-update-repo --gpg-sign="$FLATPAK_GPG_KEY" --generate-static-deltas "$REPO_DIR"
  fi
fi
