#!/usr/bin/env bash
# Builds the "Autosave Notify" VS Code extension (extension/) into a .vsix file.
# Usage: bash scripts/build-vsix.sh <output.vsix>
# Development / CI only. It is not part of the template.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/extension"
OUT="${1:?usage: build-vsix.sh <output.vsix>}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/package.json" | head -n 1)"
[ -n "$VERSION" ] || { echo "version not found in $SRC/package.json" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/extension"
cp "$SRC/package.json" "$SRC/extension.js" "$WORK/extension/"

cat > "$WORK/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
XML

cat > "$WORK/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Language="en-US" Id="autosave-notify" Version="$VERSION" Publisher="local"/><DisplayName>Autosave Notify</DisplayName><Description xml:space="preserve">Pop-up notifications for autosave.sh backups</Description></Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets></PackageManifest>
XML

rm -f "$OUT"
python3 - "$WORK" "$OUT" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name in ["[Content_Types].xml", "extension.vsixmanifest"]:
        z.write(os.path.join(src, name), name)
    for name in ["package.json", "extension.js"]:
        z.write(os.path.join(src, "extension", name), "extension/" + name)
PY
echo "built $OUT (version $VERSION)"
