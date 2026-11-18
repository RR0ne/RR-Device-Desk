#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$1"
NOTICES="$2"
GO_BIN="${RR_DEVICE_DESK_GO:-go}"
VERSION=2.8.1
SOURCE_SHA256=88704a28231ac0019016c1900edebc9dea0cf14de4e5bc90aa96fd594925bdc0

export GOTOOLCHAIN=local
if ! "$GO_BIN" version | grep -Eq ' go1\.27\.4 '; then
  echo 'RR Device Desk 0.3.15 build 21 requires Go 1.27.4. Set RR_DEVICE_DESK_GO to its executable.' >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
if [[ -n "${RR_DEVICE_DESK_ENGINE_SOURCE:-}" ]]; then
  cp "$RR_DEVICE_DESK_ENGINE_SOURCE" "$WORK/source.tar.gz"
else
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 90 \
    "https://codeload.github.com/majd/ipatool/tar.gz/refs/tags/v$VERSION" -o "$WORK/source.tar.gz"
fi
printf '%s  %s\n' "$SOURCE_SHA256" "$WORK/source.tar.gz" | shasum -a 256 -c
tar -xzf "$WORK/source.tar.gz" -C "$WORK"
cd "$WORK/ipatool-$VERSION"
patch -p1 < "$SCRIPT_DIR/store-engine.patch"
patch -p1 < "$SCRIPT_DIR/store-security.patch"
export PATH="$(dirname "$(command -v "$GO_BIN")"):$PATH"
export MACOSX_DEPLOYMENT_TARGET=13.0
"$GO_BIN" mod verify
"$GO_BIN" generate ./pkg/...
"$GO_BIN" test -mod=readonly -count=1 ./...
"$GO_BIN" build -trimpath -buildvcs=false -ldflags="-s -w -X github.com/majd/ipatool/v2/cmd.version=$VERSION-rr" -o "$ENGINE" .

mkdir -p "$NOTICES/go"
cp "$("$GO_BIN" env GOROOT)/LICENSE" "$NOTICES/go/"
mkdir -p "$NOTICES/ipatool"
cp LICENSE "$NOTICES/ipatool/"
"$GO_BIN" list -deps -f '{{with .Module}}{{if .Version}}{{.Path}}{{"\t"}}{{.Dir}}{{end}}{{end}}' . | sort -u |
while IFS=$'\t' read -r module directory; do
  if [[ -z "$module" || -z "$directory" ]]; then continue; fi
  for notice in "$directory"/{LICENSE,LICENCE,COPYING,NOTICE}*; do
    if [[ -f "$notice" ]]; then
      mkdir -p "$NOTICES/$module"
      cp "$notice" "$NOTICES/$module/"
    fi
  done
done
