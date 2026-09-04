#!/usr/bin/env bash
# Regression test for fm-spawn.sh's pane-shell normalization
# (bin/fm-spawn.sh's spawn_ensure_posix_pane_shell).
#
# The pane runs the operator's login shell, while everything fm-spawn types
# into it is POSIX shell source: the GOTMPDIR export and the `$(...)`
# substitution inside every harness launch template. On a non-POSIX login shell
# (nushell, verified live at 0.113.1: it rejects `export` outright and never
# substitutes `$(...)`), the launch command reached the worker as its own
# uninterpolated text, so the agent's whole prompt was the literal
# `$('.../fm-operational-input.sh' encode launch-brief < '.../launch-brief.md')`
# and it never learned its task - while the spawn still printed a success line.
#
# The pane here is modelled rather than real: a fake tmux keeps a pane
# interpreter that starts non-POSIX, rejects every line it is given the way
# nushell does, and only switches to a real POSIX shell when it is handed a
# flagless, double-quoted `exec "<shell>" "<script>"` bridge - the one form that
# means the same thing in sh, bash, zsh, fish, and nushell. From then on it
# actually runs what it is typed, so the export and the launch command are
# executed for real and the harness records the argv it was launched with.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pane-shell)

# make_pane_fakebin <dir>: a fake tmux whose pane holds an interpreter state,
# plus a codex that records the argv it is launched with. Env knobs:
#   FM_FAKE_PANE_STATE      file holding the pane's current interpreter
#   FM_FAKE_PANE_REJECTED   lines the non-POSIX interpreter refused
#   FM_FAKE_PANE_RAN        lines a POSIX pane shell actually executed
#   FM_FAKE_PANE_BUFFER     unsubmitted literal input
#   FM_FAKE_PANE_NO_EXEC=1  the pane's shell cannot run the bridge either
make_pane_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u

pane_state() {
  local state=nonposix
  [ -r "$FM_FAKE_PANE_STATE" ] && state=$(cat "$FM_FAKE_PANE_STATE")
  printf '%s' "$state"
}

pane_feed() {  # <line>
  local line=$1 state shell script
  state=$(pane_state)
  if [ "$state" = nonposix ]; then
    if [[ $line =~ ^exec\ \"([^\"]+)\"\ \"([^\"]+)\"$ ]]; then
      shell=${BASH_REMATCH[1]}
      script=${BASH_REMATCH[2]}
      if [ "${FM_FAKE_PANE_NO_EXEC:-0}" != 1 ]; then
        printf '%s' "$shell" > "$FM_FAKE_PANE_STATE"
        "$shell" "$script" < /dev/null >> "$FM_FAKE_PANE_REJECTED" 2>&1 || true
        return 0
      fi
    fi
    # Exactly what nushell does with `export ...`: refuse the line, run nothing.
    printf 'Error: nu::parser::unexpected_keyword: %s\n' "$line" >> "$FM_FAKE_PANE_REJECTED"
    return 0
  fi
  printf '%s\n' "$line" >> "$FM_FAKE_PANE_RAN"
  "$state" -c "$line" < /dev/null >> "$FM_FAKE_PANE_RAN" 2>&1 || true
}

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) tail -n 20 "$FM_FAKE_PANE_REJECTED" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window|set-window-option) exit 0 ;;
  new-window) printf '@7\n'; exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_FAKE_PANE_BUFFER"
      exit 0
    fi
    if [ "${1:-}" = Enter ]; then
      if [ -s "$FM_FAKE_PANE_BUFFER" ]; then
        pane_feed "$(cat "$FM_FAKE_PANE_BUFFER")"
        : > "$FM_FAKE_PANE_BUFFER"
      fi
      exit 0
    fi
    pane_feed "${1:-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_CODEX_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/codex"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_pane_case <name> <id>: a home, a real project worktree, and the pane
# model's own record files. Exports the case's paths for the runner below.
make_pane_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  FAKEBIN_DIR=$(make_pane_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise pane-shell normalization for $id."
  PANE_STATE="$case_dir/pane-state"
  PANE_REJECTED="$case_dir/pane-rejected"
  PANE_RAN="$case_dir/pane-ran"
  PANE_BUFFER="$case_dir/pane-buffer"
  CODEX_LOG="$case_dir/codex-argv"
  printf 'nonposix' > "$PANE_STATE"
  : > "$PANE_REJECTED"
  : > "$PANE_RAN"
  : > "$PANE_BUFFER"
  : > "$CODEX_LOG"
}

run_pane_spawn() {
  local id=$1
  FM_FAKE_PANE_STATE="$PANE_STATE" FM_FAKE_PANE_REJECTED="$PANE_REJECTED" \
    FM_FAKE_PANE_RAN="$PANE_RAN" FM_FAKE_PANE_BUFFER="$PANE_BUFFER" \
    FM_FAKE_CODEX_LOG="$CODEX_LOG" FM_BACKEND=tmux \
    FM_PANE_SHELL_POLLS="${FM_PANE_SHELL_POLLS:-6}" \
    FM_PANE_SHELL_POLL_INTERVAL="${FM_PANE_SHELL_POLL_INTERVAL:-0.1}" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# A non-POSIX pane is normalized, and every line typed after that is executed
# by the POSIX shell rather than refused: the GOTMPDIR export runs, and the
# launch command reaches the harness with its brief SUBSTITUTED instead of as
# the literal `$(...)` text the worker used to receive as its prompt.
test_non_posix_pane_is_normalized_and_runs_the_launch_source() {
  local id out status
  id='pane-shell-normalized-q1'
  make_pane_case normalized "$id"

  out=$(run_pane_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane is normalized"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep 'export GOTMPDIR=' "$PANE_RAN" \
    "the GOTMPDIR export never reached a POSIX pane shell"
  assert_no_grep 'export GOTMPDIR=' "$PANE_REJECTED" \
    "the GOTMPDIR export was typed into the non-POSIX shell that refuses it"
  assert_grep 'codex ' "$PANE_RAN" \
    "the launch command never reached a POSIX pane shell"
  assert_grep 'Exercise pane-shell normalization' "$CODEX_LOG" \
    "the harness did not receive its substituted brief"
  assert_no_grep 'encode launch-brief' "$CODEX_LOG" \
    "the harness received the uninterpolated launch text as its prompt"
  pass "a non-POSIX pane is normalized and the launch source it is typed executes"
}

# When the pane cannot be proved to run the required shell, the spawn refuses:
# no launch source is typed at it, no success line is printed, and the
# provisional task record is rolled back rather than left owning a worker that
# never got its instructions.
test_unprovable_pane_shell_aborts_the_spawn() {
  local id out status
  id='pane-shell-unprovable-q2'
  make_pane_case unprovable "$id"

  out=$(FM_FAKE_PANE_NO_EXEC=1 FM_PANE_SHELL_POLLS=2 \
    FM_PANE_SHELL_POLL_INTERVAL=0.05 run_pane_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a pane whose POSIX shell cannot be proved"
  assert_contains "$out" "could not be normalized onto POSIX shell" \
    "the refusal did not name the shell normalization failure"
  assert_contains "$out" "nu::parser::unexpected_keyword" \
    "the refusal did not report what the pane last showed"
  case "$out" in
    *"spawned $id"*) fail "an unprovable pane shell still reported a spawned task" ;;
  esac
  assert_no_grep 'export GOTMPDIR=' "$PANE_REJECTED" \
    "launch source was typed into a pane whose shell was never established"
  [ ! -s "$PANE_RAN" ] || fail "a pane that was never normalized still executed typed lines"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn left a task record behind"
  pass "a pane whose POSIX shell cannot be proved aborts the spawn with a diagnostic"
}

test_non_posix_pane_is_normalized_and_runs_the_launch_source
test_unprovable_pane_shell_aborts_the_spawn

echo "# all fm-spawn-pane-shell tests passed"
