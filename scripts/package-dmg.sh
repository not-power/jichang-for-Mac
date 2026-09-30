#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$source_root/dist}"
mkdir -p "$output_root"
app_bundle="$source_root/build/Build/Products/Release/鸡场.app"
test -d "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/jichang-dmg.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
ditto "$app_bundle" "$stage_root/鸡场.app"
ln -s /Applications "$stage_root/Applications"
hdiutil create -volname "鸡场 0.11.0" -srcfolder "$stage_root" -ov -format UDZO "$output_root/鸡场-0.11.0-arm64.dmg"
hdiutil verify "$output_root/鸡场-0.11.0-arm64.dmg"
