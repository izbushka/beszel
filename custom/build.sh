#!/usr/bin/env bash
# Builds the custom-metrics hub and agent for Linux and packs them with
# install.sh into build/beszel-custom_linux_<arch>.tar.gz.
#
#   custom/build.sh [arch...]     # default: amd64; also arm64, arm
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
ARCHES=("${@:-amd64}")
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)

# The web UI build rewrites locale catalogs (and package-lock.json with npm);
# undo that afterwards unless those files already had local changes.
GENERATED=(internal/site/src/locales internal/site/package-lock.json)
generated_clean=false
git diff --quiet -- "${GENERATED[@]}" && generated_clean=true

echo "==> Building web UI"
make build-web-ui >/dev/null
$generated_clean && git checkout -- "${GENERATED[@]}"

for arch in "${ARCHES[@]}"; do
  out="build/beszel-custom_linux_$arch"
  rm -rf "$out"
  mkdir -p "$out"
  echo "==> Building linux/$arch ($VERSION)"
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -tags no_self_update -ldflags "-w -s" \
    -o "$out/beszel_linux_$arch" ./internal/cmd/hub
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -tags no_self_update -ldflags "-w -s" \
    -o "$out/beszel-agent_linux_$arch" ./internal/cmd/agent
  cp custom/install.sh "$out/"
  chmod 755 "$out/install.sh"
  tar -czf "$out.tar.gz" -C build "$(basename "$out")"
  echo "    $out.tar.gz"
done
