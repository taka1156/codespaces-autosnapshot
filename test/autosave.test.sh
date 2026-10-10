#!/usr/bin/env bash
#
# autosave.sh のテスト(外部ツール不要の素のbash)
#
# 実行: bash test/autosave.test.sh
#
# 仕組み:
#   - test_ で始まる関数が1テスト。関数名の _ を空白にした文字列がテスト名になる
#   - 各テストはサブシェルで実行され、毎回まっさらな一時リポジトリとbareリモートを使う
#   - テストは並列で実行する(TEST_JOBS=1 で直列。既定は 6)
#   - 失敗は assert_* が exit 1 するか、set -e によるコマンド失敗で検出する
#   - Linux / Codespaces / WSL2 で実行(Windowsネイティブ不可)。GNU timeout を使う

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.devcontainer/autosave.sh"
export AUTOSAVE_EXCLUDE_FILE="$ROOT/.devcontainer/autosave.ignore"
export GIT_CONFIG_GLOBAL=/dev/null          # 実行環境のgit設定に影響されない
export GIT_CONFIG_SYSTEM=/dev/null

# 前提: 除外ファイルが無いとルールが何も適用されず、紛らわしい失敗になるため先に確認する
if [ ! -f "$AUTOSAVE_EXCLUDE_FILE" ]; then
  echo "ERROR: exclude file not found: $AUTOSAVE_EXCLUDE_FILE" >&2
  echo "       .devcontainer/autosave.ignore をリポジトリに追加してください" >&2
  exit 2
fi

# ---------------------------------------------------------------- helpers ---

fail() { echo "assertion failed: $*" >&2; exit 1; }

assert_eq()    { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_has()   { printf '%s\n' "$1" | grep -qxF -- "$2" || fail "'$2' not found in:"$'\n'"$1"; }
assert_lacks() { ! printf '%s\n' "$1" | grep -qxF -- "$2" || fail "'$2' should not be present in:"$'\n'"$1"; }
assert_lacks_re() { ! printf '%s\n' "$1" | grep -qE -- "$2" || fail "pattern '$2' should not match:"$'\n'"$1"; }

setup() {
  TMP="$(mktemp -d)"
  # 失敗時もバックグラウンドプロセスを残さない(trap内の失敗が set -e で終了コードに影響しないよう || true)
  trap '[ -n "${LOOP_PID:-}" ] && kill "$LOOP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
  REMOTE="$TMP/remote.git"
  WORK="$TMP/work"
  export AUTOSAVE_STATUS_FILE="$TMP/status.json"

  # Local bare repo acting as "GitHub". The hook logs every ref update.
  git init --bare -q "$REMOTE"
  cat > "$REMOTE/hooks/post-receive" <<'EOF'
#!/bin/sh
while read -r old new ref; do
  echo "$ref" >> "$PWD/received.log"
done
EOF
  chmod +x "$REMOTE/hooks/post-receive"

  git clone -q "$REMOTE" "$WORK" 2>/dev/null
  cd "$WORK"
  git config user.name tester
  git config user.email tester@example.com
  git checkout -q -b feature/x
  echo a > a.txt
  git add a.txt
  git commit -q -m init
  git push -q -u origin feature/x 2>/dev/null
}

# autosave.sh を1回だけ実行し、終了コードを RC、出力(stdout+stderr)を OUT に入れる
run_autosave() {
  RC=0
  OUT=$(AUTOSAVE_ONCE=1 bash "$SCRIPT" "$WORK" 2>&1) || RC=$?
}

# リモートの wip/feature/x に含まれるファイル一覧
wip_files() { git --git-dir="$REMOTE" ls-tree -r --name-only refs/heads/wip/feature/x; }
wip_refs()  { git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/heads/wip/; }

# ループ動作のテスト用: 短い間隔で autosave.sh をバックグラウンド起動する
#   loop_start <MAX_INTERVAL> <CHANGE_THRESHOLD> [MIN_INTERVAL(default 0)]
loop_start() {
  env AUTOSAVE_POLL=1 AUTOSAVE_MIN_INTERVAL="${3:-0}" AUTOSAVE_MAX_INTERVAL="$1" \
      AUTOSAVE_CHANGE_THRESHOLD="$2" bash "$SCRIPT" "$WORK" >/dev/null 2>&1 &
  LOOP_PID=$!
}
loop_stop() { kill "$LOOP_PID" 2>/dev/null || true; wait "$LOOP_PID" 2>/dev/null || true; }

# ステータスファイルの値を取り出す(例: status_field event)
status_field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}[,}].*/\1/p" "$AUTOSAVE_STATUS_FILE" | head -n1; }

# 指定秒数のあいだステータスファイルを観察し、現れた通知(id)の種類数を返す
distinct_events() {
  local end=$((SECONDS + $1))
  while [ "$SECONDS" -lt "$end" ]; do
    [ -f "$AUTOSAVE_STATUS_FILE" ] && sed -n 's/.*"id":"\([0-9]*\)".*/\1/p' "$AUTOSAVE_STATUS_FILE"
    sleep 0.3
  done | sort -u | wc -l
}

# wip/feature/x への push 回数(post-receive フックのログから数える)
push_count() {
  local n
  n=$(grep -c 'refs/heads/wip/feature/x' "$REMOTE/received.log" 2>/dev/null || true)
  echo "${n:-0}"
}

# ------------------------------------------------------------------ tests ---

test_untracked_files_are_backed_up() {
  echo new > new.txt
  mkdir -p sub/dir && echo deep > sub/dir/deep.txt

  run_autosave
  assert_eq "$RC" 0

  files="$(wip_files)"
  assert_has "$files" "new.txt"
  assert_has "$files" "sub/dir/deep.txt"
}

test_autosave_ignore_targets_are_excluded() {
  echo "SECRET=1" > .env
  echo "SECRET=1" > .env.local
  echo "SAMPLE=" > .env.example
  echo "key" > id_rsa
  echo "key" > server.pem
  mkdir -p node_modules/pkg __pycache__
  echo x > node_modules/pkg/index.js
  echo x > __pycache__/a.pyc
  echo keep > keep.txt

  run_autosave
  assert_eq "$RC" 0

  files="$(wip_files)"
  assert_has   "$files" "keep.txt"
  assert_has   "$files" ".env.example"          # !.env.example で例外的に含まれる
  assert_lacks "$files" ".env"
  assert_lacks "$files" ".env.local"
  assert_lacks "$files" "id_rsa"
  assert_lacks "$files" "server.pem"
  assert_lacks_re "$files" '^node_modules/'
  assert_lacks_re "$files" '^__pycache__/'
}

test_gitignore_targets_are_excluded() {
  echo '*.tmpx' > .gitignore
  git add .gitignore
  git commit -q -m "add gitignore"
  echo x > foo.tmpx
  echo y > bar.txt

  run_autosave
  assert_eq "$RC" 0

  files="$(wip_files)"
  assert_has   "$files" "bar.txt"
  assert_lacks "$files" "foo.tmpx"
}

test_working_tree_index_head_and_stash_are_untouched() {
  echo b >> a.txt                       # tracked + modified (unstaged)
  echo s > staged.txt
  git add staged.txt                    # staged
  echo u > untracked.txt                # untracked

  before="$(git status --porcelain; git diff --cached; git diff; git stash list; git rev-parse HEAD)"
  run_autosave
  assert_eq "$RC" 0
  after="$(git status --porcelain; git diff --cached; git diff; git stash list; git rev-parse HEAD)"

  assert_eq "$after" "$before"
}

test_modified_tracked_file_content_is_backed_up() {
  echo modified > a.txt

  run_autosave
  assert_eq "$RC" 0

  assert_eq "$(git --git-dir="$REMOTE" show refs/heads/wip/feature/x:a.txt)" "modified"
  # wip commit's parent is the current HEAD
  assert_eq "$(git --git-dir="$REMOTE" rev-parse refs/heads/wip/feature/x^)" "$(git rev-parse HEAD)"
}

test_unpushed_commit_is_protected_even_when_tree_is_clean() {
  echo c > c.txt
  git add c.txt
  git commit -q -m "local only"

  run_autosave
  assert_eq "$RC" 0

  assert_eq "$(git --git-dir="$REMOTE" rev-parse refs/heads/wip/feature/x)" "$(git rev-parse HEAD)"
}

test_same_content_is_not_pushed_repeatedly_in_loop_mode() {
  echo new > new.txt

  AUTOSAVE_ONCE=0 AUTOSAVE_POLL=1 AUTOSAVE_MIN_INTERVAL=0 AUTOSAVE_MAX_INTERVAL=1 \
    timeout 4 bash "$SCRIPT" "$WORK" || true

  assert_eq "$(grep -c 'refs/heads/wip/feature/x' "$REMOTE/received.log")" 1
}

test_detached_head_does_nothing() {
  git checkout -q --detach
  echo new > new.txt

  run_autosave
  assert_eq "$RC" 0
  assert_eq "$(wip_refs)" ""
}

test_tracked_file_is_included_even_if_it_matches_exclude_rules() {
  echo "TRACKED=1" > .env
  git add -f .env
  git commit -q -m "oops"
  echo "TRACKED=2" > .env

  run_autosave
  assert_eq "$RC" 0
  assert_has "$(wip_files)" ".env"
}

test_missing_exclude_file_still_works_and_warns() {
  echo new > new.txt

  RC=0
  OUT=$(AUTOSAVE_ONCE=1 AUTOSAVE_EXCLUDE_FILE=/nonexistent bash "$SCRIPT" "$WORK" 2>&1) || RC=$?

  assert_eq "$RC" 0
  case "$OUT" in *"exclude file not found"*) ;; *) fail "no warning in: $OUT" ;; esac
  assert_has "$(wip_files)" "new.txt"
}

test_push_failure_returns_exit_code_1() {
  echo new > new.txt
  git remote set-url origin "$TMP/does-not-exist.git"

  run_autosave
  assert_eq "$RC" 1
}

test_can_restore_from_fresh_clone() {
  echo modified > a.txt
  echo brand-new > new.txt

  run_autosave
  assert_eq "$RC" 0

  git clone -q "$REMOTE" "$TMP/restore" 2>/dev/null
  cd "$TMP/restore"
  git checkout -q feature/x
  git checkout -q origin/wip/feature/x -- .

  assert_eq "$(cat a.txt)" "modified"
  assert_eq "$(cat new.txt)" "brand-new"
}

# --- 変更量 / 経過時間の2軸判定(ループ動作。POLL=1秒で実行) ---

test_change_threshold_triggers_before_max_interval() {
  loop_start 1000 10                    # MAX=1000秒 でも、閾値(10行)を超えれば push
  seq 1 20 > big.txt                    # 20行
  sleep 4; loop_stop
  assert_eq "$(push_count)" 1
}

test_small_change_is_not_pushed_before_max_interval() {
  loop_start 1000 100                   # 閾値100行・MAX=1000秒
  seq 1 5 > small.txt                   # 5行
  sleep 4; loop_stop
  assert_eq "$(push_count)" 0
}

test_max_interval_pushes_even_a_small_change() {
  loop_start 3 1000                     # 閾値に届かなくても、3秒で push
  echo x > small.txt
  sleep 6; loop_stop
  assert_eq "$(push_count)" 1
}

test_min_interval_limits_push_frequency() {
  loop_start 1 1 1000                   # 条件は満たすが、最小間隔(1000秒)で抑止
  echo x > small.txt
  sleep 4; loop_stop
  assert_eq "$(push_count)" 0
}

test_threshold_is_measured_from_the_last_backup() {
  loop_start 1000 10
  seq 1 20 > big.txt
  sleep 4
  assert_eq "$(push_count)" 1           # 20行 → push

  seq 1 3 >> big.txt                    # 前回から +3行(閾値未満)
  sleep 3
  assert_eq "$(push_count)" 1           # push されない

  seq 1 20 >> big.txt                   # 前回から +23行(閾値以上)
  sleep 3; loop_stop
  assert_eq "$(push_count)" 2           # push される
}

test_file_deletion_is_detected() {
  loop_start 1000 1
  rm a.txt                              # 追跡済みファイルの削除(1行減)
  sleep 4; loop_stop
  assert_eq "$(push_count)" 1
  assert_lacks "$(wip_files)" "a.txt"
}

# --- 通知(ステータスファイルへのイベント出力) ---

test_success_event_is_written_with_changed_lines() {
  seq 1 7 > new.txt
  run_autosave
  assert_eq "$RC" 0
  assert_eq "$(status_field event)" "success"
  assert_eq "$(status_field branch)" "feature/x"
  assert_eq "$(status_field changes)" "7"
}

test_failure_event_has_detail() {
  echo new > new.txt
  git remote set-url origin "$TMP/does-not-exist.git"
  run_autosave
  assert_eq "$RC" 1
  assert_eq "$(status_field event)" "failure"
  [ -n "$(status_field detail)" ] || fail "detail is empty"
}

test_pushing_unchanged_head_is_silent() {
  echo c > c.txt; git add c.txt; git commit -q -m "local only"
  run_autosave
  assert_eq "$RC" 0
  [ ! -f "$AUTOSAVE_STATUS_FILE" ] || fail "an event was written for an unchanged tree"
}

test_status_file_can_be_disabled() {
  echo new > new.txt
  RC=0
  AUTOSAVE_STATUS_FILE="" AUTOSAVE_ONCE=1 bash "$SCRIPT" "$WORK" >/dev/null 2>&1 || RC=$?
  assert_eq "$RC" 0
  [ ! -e "$TMP/status.json" ] || fail "status file was written although disabled"
}

test_failure_is_notified_only_once_within_repeat_interval() {
  git remote set-url origin "$TMP/does-not-exist.git"
  export AUTOSAVE_NOTIFY_REPEAT=1000
  loop_start 1 1
  echo x > small.txt
  n=$(distinct_events 6); loop_stop
  assert_eq "$n" 1
}

test_failure_is_notified_again_after_repeat_interval() {
  git remote set-url origin "$TMP/does-not-exist.git"
  export AUTOSAVE_NOTIFY_REPEAT=2
  loop_start 1 1
  echo x > small.txt
  n=$(distinct_events 8); loop_stop
  [ "$n" -ge 2 ] || fail "expected at least 2 failure notifications, got $n"
}

test_pending_warning_when_changes_stay_unbacked_up() {
  export AUTOSAVE_WARN_AFTER=2
  loop_start 1000 1000                  # 閾値にも最大間隔にも達しない = 保存されない
  echo x > small.txt
  sleep 6; loop_stop
  assert_eq "$(status_field event)" "pending"
  assert_eq "$(status_field changes)" "1"
}

test_pending_warning_by_changed_lines() {
  export AUTOSAVE_WARN_CHANGES=10
  loop_start 1000 1000
  seq 1 30 > big.txt
  sleep 4; loop_stop
  assert_eq "$(status_field event)" "pending"
}

test_pending_warning_is_not_sent_for_a_clean_tree() {
  export AUTOSAVE_WARN_AFTER=1
  loop_start 1000 1000
  sleep 5; loop_stop
  [ ! -f "$AUTOSAVE_STATUS_FILE" ] || fail "an event was written for a clean tree"
}

# ----------------------------------------------------------------- runner ---

# テストは互いに独立した一時ディレクトリで動くため、並列で実行する(同時実行数: TEST_JOBS、既定 6)。
# 時間を待つテスト(sleep)が多いので、直列だと1分以上かかる。
JOBS="${TEST_JOBS:-6}"
mapfile -t TESTS < <(declare -F | awk '{print $3}' | grep '^test_')
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

running=0
for fn in "${TESTS[@]}"; do
  # NOTE: if 条件の中に入れると set -e が無効になるため、サブシェルとして実行して終了コードを記録する
  ( ( set -e; setup; "$fn" ) >"$LOGDIR/$fn.log" 2>&1; echo $? >"$LOGDIR/$fn.rc" ) &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
done
wait

PASS=0
FAIL=0
for fn in "${TESTS[@]}"; do
  name="${fn#test_}"
  name="${name//_/ }"
  if [ "$(cat "$LOGDIR/$fn.rc" 2>/dev/null)" = "0" ]; then
    echo "ok   - $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $name"
    sed 's/^/         /' "$LOGDIR/$fn.log"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
