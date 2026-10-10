#!/usr/bin/env bash
#
# scripts/build-vsix.sh と .devcontainer/autosave-notify/install.sh のテスト
# 実際のVS Codeの代わりに、偽の `code` コマンドとローカルファイル(file://)を使う。
#
# 実行: bash test/install.test.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-vsix.sh"
INSTALL="$ROOT/.devcontainer/autosave-notify/install.sh"

fail() { echo "assertion failed: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "'$2' not found in: $1" ;; esac; }

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin"
  # 偽の code: --list-extensions は $T/installed の内容を返し、--install-extension は受け取ったファイルを保存する
  cat > "$T/bin/code" <<'EOF'
#!/bin/bash
case "$1" in
  --list-extensions) cat "$FAKE_DIR/installed" 2>/dev/null; exit 0 ;;
  --install-extension) cp "$2" "$FAKE_DIR/received.vsix"; echo "local.autosave-notify" > "$FAKE_DIR/installed"; exit 0 ;;
esac
EOF
  chmod +x "$T/bin/code"
  export FAKE_DIR="$T"
  bash "$BUILD" "$T/ext.vsix" >/dev/null
}

run_install() {  # run_install <url> [args...]
  local url="$1"; shift
  RC=0
  OUT=$(PATH="$T/bin:$PATH" AUTOSAVE_NOTIFY_VSIX_URL="$url" bash "$INSTALL" "$@" 2>&1) || RC=$?
}

# ------------------------------------------------------------------ tests ---

test_build_creates_a_valid_vsix() {
  python3 - "$T/ext.vsix" "$ROOT/extension/package.json" <<'PY'
import json, sys, zipfile
import xml.dom.minidom as minidom
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
for n in ["[Content_Types].xml", "extension.vsixmanifest", "extension/package.json", "extension/extension.js"]:
    assert n in names, f"missing {n}: {sorted(names)}"
minidom.parseString(z.read("extension.vsixmanifest"))
minidom.parseString(z.read("[Content_Types].xml"))
version = json.load(open(sys.argv[2]))["version"]
assert f'Version="{version}"'.encode() in z.read("extension.vsixmanifest"), "manifest version mismatch"
assert json.loads(z.read("extension/package.json"))["version"] == version
PY
}

test_install_downloads_and_installs_the_extension() {
  run_install "file://$T/ext.vsix"
  assert_eq "$RC" 0
  [ -f "$T/received.vsix" ] || fail "extension was not installed: $OUT"
  cmp -s "$T/ext.vsix" "$T/received.vsix" || fail "installed file differs from the downloaded file"
  assert_contains "$OUT" "installed"
}

test_install_is_skipped_when_already_installed() {
  echo "local.autosave-notify" > "$T/installed"
  run_install "file://$T/ext.vsix"
  assert_eq "$RC" 0
  [ ! -f "$T/received.vsix" ] || fail "installed again although already installed"
  assert_contains "$OUT" "already installed"
}

test_force_reinstalls() {
  echo "local.autosave-notify" > "$T/installed"
  run_install "file://$T/ext.vsix" --force
  assert_eq "$RC" 0
  [ -f "$T/received.vsix" ] || fail "--force did not reinstall"
}

test_failed_download_does_not_fail_the_codespace() {
  run_install "file://$T/does-not-exist.vsix"
  assert_eq "$RC" 0
  assert_contains "$OUT" "could not download"
  [ ! -f "$T/received.vsix" ] || fail "something was installed"
}

test_non_vsix_download_is_rejected() {
  echo "<html>Not Found</html>" > "$T/page.html"
  run_install "file://$T/page.html"
  assert_eq "$RC" 0
  assert_contains "$OUT" "could not download"
  [ ! -f "$T/received.vsix" ] || fail "an HTML page was installed"
}

test_missing_code_command_only_prints_a_hint() {
  RC=0
  OUT=$(env -i PATH=/usr/bin:/bin AUTOSAVE_NOTIFY_VSIX_URL="file://$T/ext.vsix" bash "$INSTALL" 2>&1) || RC=$?
  assert_eq "$RC" 0
  assert_contains "$OUT" "'code' command was not found"
}

# ----------------------------------------------------------------- runner ---

PASS=0
FAIL=0
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
  name="${fn#test_}"; name="${name//_/ }"
  log="$(mktemp)"
  ( set -e; setup; "$fn" ) >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   - $name"; PASS=$((PASS + 1))
  else
    echo "FAIL - $name"; sed 's/^/         /' "$log"; FAIL=$((FAIL + 1))
  fi
  rm -f "$log"
done
echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
