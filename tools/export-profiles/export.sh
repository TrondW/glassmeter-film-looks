#!/bin/sh
# Re-export profiles/film-stocks.json from a GlassMeter checkout.
# Usage: tools/export-profiles/export.sh /path/to/GlassMeter
set -eu
APP="${1:?path to GlassMeter checkout}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O "$APP/GlassMeter/Models/FilmStock.swift" "$HERE/main.swift" -o "$TMP/export"
"$TMP/export" "$ROOT/profiles/film-stocks.json"
cp "$ROOT/profiles/film-stocks.json" "$ROOT/Sources/GlassFilmLooks/Resources/film-stocks.json"
