#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
workspace=$(mktemp -d "${TMPDIR:-/tmp}/Maschinery-XPC.XXXXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
architectures=(x86_64)
if [[ "$(uname -m)" == arm64 ]]; then architectures=(arm64 x86_64); fi
for arch in "${architectures[@]}"; do
  swiftc -O -target "$arch-apple-macos14.0" scripts/helper-trust-probe.swift -o "$workspace/probe-$arch"
  codesign --force --options runtime --sign - --identifier local.maschinery.app "$workspace/probe-$arch"
  hash=$(codesign -d --verbose=4 "$workspace/probe-$arch" 2>&1 | sed -n 's/^CDHash=//p')
  /usr/bin/arch -"$arch" "$workspace/probe-$arch" "$hash"
done
