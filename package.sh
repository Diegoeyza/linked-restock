#!/usr/bin/env bash
# Build shareable bundles into dist/:
#   linked-restock-<version>.zip   REFramework mod (flat) + install notes
#   LinkedRestock-<version>.zip    REFramework mod, game-folder layout (Nexus/Vortex)
set -euo pipefail
cd "$(dirname "$0")"

command -v zip >/dev/null || { echo "error: 'zip' is required" >&2; exit 1; }

LUA="reframework/linked_restock.lua"
[ -f "$LUA" ] || { echo "error: $LUA not found, nothing to package" >&2; exit 1; }

MOD_VERSION="$(sed -n 's/^local VERSION = "\([^"]*\)".*/\1/p' "$LUA" | head -1)"
[ -n "$MOD_VERSION" ] || { echo "error: VERSION not found in $LUA" >&2; exit 1; }

DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# 1) Flat bundle: the Lua file + install notes.
mkdir -p "$DIST/flat"
cp "$LUA" "$DIST/flat/linked_restock.lua"
cp reframework/INSTALL.txt "$DIST/flat/INSTALL.txt"
( cd "$DIST/flat" \
    && zip -q "../linked-restock-${MOD_VERSION}.zip" linked_restock.lua INSTALL.txt )
rm -rf "$DIST/flat"

# 2) Nexus/Vortex bundle: laid out for the game folder so it extracts straight
#    into <game>\ (reframework\autorun\linked_restock.lua) or installs via
#    Vortex/Fluffy. The probe and the tests are deliberately NOT packaged.
mkdir -p "$DIST/nexus/reframework/autorun"
cp "$LUA" "$DIST/nexus/reframework/autorun/linked_restock.lua"
cp packaging/nexus/README.txt "$DIST/nexus/README.txt"
( cd "$DIST/nexus" && zip -q -r "../LinkedRestock-${MOD_VERSION}.zip" . )
rm -rf "$DIST/nexus"

echo "Built into $DIST/:"
ls -1 "$DIST"
