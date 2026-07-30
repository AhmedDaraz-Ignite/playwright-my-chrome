#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$repo_root/skills/playwright-my-chrome/scripts/playwright-my-chrome.sh"
store_token="$repo_root/skills/playwright-my-chrome/scripts/store-extension-token.sh"
mock_dir="$repo_root/tests/mocks"
case_dir=""
output=""
status=0
passed=0

cleanup_case() {
  if [[ -n "$case_dir" && -d "$case_dir" ]]; then
    /usr/bin/find "$case_dir" -depth -delete
  fi
  case_dir=""
}

trap cleanup_case EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  [[ "$status" == "$expected" ]] ||
    fail "expected status $expected, got $status; output: $output"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] ||
    fail "expected output to contain '$needle'; output: $haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] ||
    fail "output unexpectedly contained '$needle'"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  /usr/bin/grep -Fq -- "$needle" "$file" ||
    fail "expected $file to contain '$needle'"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if /usr/bin/grep -Fq -- "$needle" "$file"; then
    fail "$file unexpectedly contained '$needle'"
  fi
}

run_capture() {
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
}

setup_case() {
  cleanup_case
  case_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/playwright-my-chrome-test.XXXXXX")"
  /bin/chmod 700 "$case_dir"
  /bin/mkdir "$case_dir/home"
  /bin/chmod 700 "$case_dir/home"

  export HOME="$case_dir/home"
  export PLAYWRIGHT_MY_CHROME_TEST_MODE=1
  export PLAYWRIGHT_MY_CHROME_CLI="$mock_dir/mock-playwright-cli.sh"
  export PLAYWRIGHT_MY_CHROME_NODE
  PLAYWRIGHT_MY_CHROME_NODE="$(command -v node)"
  export PLAYWRIGHT_MY_CHROME_RUNTIME_DIR="$case_dir/runtime"
  export PLAYWRIGHT_MY_CHROME_EXECUTABLE="/Applications/Test Chrome.app/Contents/MacOS/Test Chrome"
  export PLAYWRIGHT_MY_CHROME_TEST_SECURITY_BIN="$mock_dir/mock-security.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_PS_BIN="$mock_dir/mock-ps.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_PBPASTE_BIN="$mock_dir/mock-pbpaste.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_PBCOPY_BIN="$mock_dir/mock-pbcopy.sh"
  export MOCK_CLI_LOG="$case_dir/cli.log"
  export MOCK_SECURITY_LOG="$case_dir/security.log"
  export MOCK_SESSION_STATE_FILE="$case_dir/session.state"
  export MOCK_PS_OUTPUT_FILE="$case_dir/ps.out"
  export MOCK_KEYCHAIN_TOKEN_FILE="$case_dir/keychain-token"
  export MOCK_CLIPBOARD_FILE="$case_dir/clipboard"
  export MOCK_ATTACH_PID_FILE="$case_dir/attach.pid"
  export MOCK_TAB_LIST_PID_FILE="$case_dir/tab-list.pid"
  export MOCK_CLI_VERSION="0.1.17"
  export MOCK_ATTACH_MODE="stable"
  export MOCK_DETACH_MODE="stable"
  export MOCK_TAB_LIST_MODE="stable"
  export MOCK_CHANGE_PID_ON_LIST_ALL="0"
  unset PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS

  : >"$MOCK_CLI_LOG"
  : >"$MOCK_SECURITY_LOG"
  : >"$MOCK_SESSION_STATE_FILE"
  : >"$MOCK_PS_OUTPUT_FILE"
  : >"$MOCK_CLIPBOARD_FILE"
  printf '%s\n' "TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" \
    >"$MOCK_KEYCHAIN_TOKEN_FILE"
}

set_normal_chrome() {
  local pid="${1:-111}"
  printf '%s %s\n' "$pid" "$PLAYWRIGHT_MY_CHROME_EXECUTABLE" \
    >"$MOCK_PS_OUTPUT_FILE"
}

set_multiple_normal_chrome() {
  printf '111 %s\n222 %s\n' \
    "$PLAYWRIGHT_MY_CHROME_EXECUTABLE" \
    "$PLAYWRIGHT_MY_CHROME_EXECUTABLE" \
    >"$MOCK_PS_OUTPUT_FILE"
}

pass_test() {
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$1"
}

test_missing_chrome_refuses_before_token_read() {
  setup_case
  run_capture "$wrapper" connect
  assert_status 5
  assert_contains "$output" "No browser was launched"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "missing-Chrome path read the Keychain token"
  pass_test "missing Chrome refuses before token read or attachment"
}

test_ambiguous_chrome_refuses_before_token_read() {
  setup_case
  set_multiple_normal_chrome
  run_capture "$wrapper" connect
  assert_status 5
  assert_contains "$output" "Multiple normal Google Chrome main processes"
  assert_contains "$output" "browser ownership is ambiguous"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "ambiguous-Chrome path read the Keychain token"
  pass_test "multiple normal Chrome processes refuse before token read"
}

test_successful_connect_uses_stable_existing_chrome() {
  setup_case
  set_normal_chrome 111
  run_capture "$wrapper" connect
  assert_status 0
  assert_contains "$output" "ready (attached session 'mychrome')"
  assert_not_contains "$output" "TEST_ONLY_TOKEN"
  assert_file_contains "$MOCK_CLI_LOG" "--json attach"
  assert_file_contains "$MOCK_CLI_LOG" "attach-token-present"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "bootstrap sanitation marker remained after successful attachment"
  pass_test "stable existing Chrome attaches without exposing the token"
}

test_pid_change_during_attach_fails_closed() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="pid-change"
  run_capture "$wrapper" connect
  assert_status 6
  assert_contains "$output" "SECURITY: Chrome changed"
  assert_contains "$output" "token-rotation procedure"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  pass_test "Chrome PID change during attachment detaches and fails closed"
}

test_added_pid_during_attach_fails_closed() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="add-pid"
  run_capture "$wrapper" connect
  assert_status 6
  assert_contains "$output" "SECURITY: Chrome changed"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  pass_test "an added Chrome PID during attachment fails closed"
}

test_process_token_during_attach_fails_closed() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="process-token"
  run_capture "$wrapper" connect
  assert_status 6
  assert_contains "$output" "SECURITY: Chrome changed or retained"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  pass_test "persistent process token detaches and requires rotation"
}

test_pid_change_before_attach_never_invokes_attach() {
  setup_case
  set_normal_chrome 111
  export MOCK_CHANGE_PID_ON_LIST_ALL="1"
  run_capture "$wrapper" connect
  assert_status 5
  assert_contains "$output" "changed before Playwright could attach"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  pass_test "pre-attach PID change never invokes Playwright attachment"
}

test_failed_attach_suppresses_token_and_scrubs_artifacts() {
  local token=""

  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="fail"
  token="$(<"$MOCK_KEYCHAIN_TOKEN_FILE")"
  run_capture "$wrapper" connect
  assert_status 22
  assert_not_contains "$output" "$token"
  assert_contains "$output" "Bootstrap details were suppressed"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "failed attach left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "failed attach left output metadata"
  [[ -z "$(/usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" \
    -maxdepth 1 -name 'session-output.*' -print -quit)" ]] ||
    fail "failed attach left a bootstrap directory"
  pass_test "failed attachment hides token-bearing output and scrubs artifacts"
}

test_hung_attach_is_terminated_and_scrubbed() {
  local attach_pid=""

  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="hang"
  export PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS=2
  run_capture "$wrapper" connect
  assert_status 124
  assert_contains "$output" "attachment timed out"
  assert_contains "$output" "token-rotation procedure"
  [[ -s "$MOCK_ATTACH_PID_FILE" ]] ||
    fail "hung attach did not record its child PID"
  attach_pid="$(<"$MOCK_ATTACH_PID_FILE")"
  if kill -0 "$attach_pid" 2>/dev/null; then
    fail "timed-out attach child $attach_pid is still running"
  fi
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "timed-out attach left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "timed-out attach left output metadata"
  pass_test "hung attachment is terminated, detached, and scrubbed"
}

test_hung_attach_reports_detach_failure() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="hang"
  export MOCK_DETACH_MODE="fail"
  export PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS=2
  run_capture "$wrapper" connect
  assert_status 124
  assert_contains "$output" "Automatic session detachment failed (status 23)"
  assert_contains "$output" "Treat the session as connected"
  assert_not_contains "$output" "session was detached"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "detach-failure path left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "detach-failure path left output metadata"
  pass_test "timeout reports failed detachment without claiming success"
}

test_interrupted_attach_terminates_child_and_recovers() {
  local attach_pid=""
  local output_file=""
  local wrapper_pid=""
  local wait_attempt=0

  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="hang"
  export PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS=600
  output_file="$case_dir/wrapper.out"
  "$wrapper" connect >"$output_file" 2>&1 &
  wrapper_pid=$!

  while [[ ! -s "$MOCK_ATTACH_PID_FILE" ]]; do
    if ! kill -0 "$wrapper_pid" 2>/dev/null; then
      output="$(<"$output_file")"
      fail "wrapper exited before interrupted-attach test could signal it: $output"
    fi
    wait_attempt=$((wait_attempt + 1))
    (( wait_attempt < 100 )) ||
      fail "timed out waiting for the mock attach child"
    sleep 0.05
  done

  attach_pid="$(<"$MOCK_ATTACH_PID_FILE")"
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 143
  assert_contains "$output" "Attachment was interrupted"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  assert_file_contains "$MOCK_CLI_LOG" "detach-token-absent"
  if kill -0 "$attach_pid" 2>/dev/null; then
    fail "interrupted attach child $attach_pid is still running"
  fi
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "interrupted attach left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "interrupted attach left output metadata"
  pass_test "interrupt terminates the token-bearing child and runs recovery"
}

test_interrupted_post_attach_validation_recovers() {
  local child_pid=""
  local output_file=""
  local wrapper_pid=""
  local wait_attempt=0

  setup_case
  set_normal_chrome 111
  output_file="$case_dir/wrapper.out"
  export MOCK_TAB_LIST_MODE="hang"
  "$wrapper" connect >"$output_file" 2>&1 &
  wrapper_pid=$!

  while [[ ! -s "$MOCK_TAB_LIST_PID_FILE" ]]; do
    if ! kill -0 "$wrapper_pid" 2>/dev/null; then
      output="$(<"$output_file")"
      fail "wrapper exited before post-attach validation could be signaled: $output"
    fi
    wait_attempt=$((wait_attempt + 1))
    (( wait_attempt < 100 )) ||
      fail "timed out waiting for the post-attach validation pause"
    sleep 0.05
  done

  child_pid="$(<"$MOCK_TAB_LIST_PID_FILE")"
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 143
  assert_contains "$output" "Attachment was interrupted"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  assert_file_contains "$MOCK_CLI_LOG" "detach-token-absent"
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "interrupted post-attach validation child $child_pid is still running"
  fi
  [[ "$(<"$MOCK_SESSION_STATE_FILE")" == "missing" ]] ||
    fail "post-attach interrupt left the named session attached"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "post-attach interrupt left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "post-attach interrupt left output metadata"
  [[ -z "$(/usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" \
    -maxdepth 1 -name 'session-output.*' -print -quit)" ]] ||
    fail "post-attach interrupt left a bootstrap directory"
  pass_test "interrupt during post-attach validation detaches and scrubs"
}

test_unsupported_cli_version_blocks_browser_commands() {
  setup_case
  set_normal_chrome 111
  export MOCK_CLI_VERSION="9.9.9"
  run_capture "$wrapper" connect
  assert_status 2
  assert_contains "$output" "requires @playwright/cli 0.1.17"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "unsupported CLI path read the Keychain token"
  pass_test "unsupported Playwright CLI version fails before browser access"
}

test_unsupported_cli_version_blocks_disconnect() {
  setup_case
  set_normal_chrome 111
  export MOCK_CLI_VERSION="9.9.9"
  run_capture "$wrapper" disconnect
  assert_status 2
  assert_contains "$output" "requires @playwright/cli 0.1.17"
  assert_file_not_contains "$MOCK_CLI_LOG" "detach"
  pass_test "unsupported Playwright CLI cannot detach the browser"
}

test_unsafe_commands_are_blocked_locally() {
  local command_name=""

  setup_case
  for command_name in open attach close-all kill-all install install-browser show; do
    run_capture "$wrapper" "$command_name"
    [[ "$status" != "0" ]] || fail "$command_name unexpectedly succeeded"
  done
  [[ ! -s "$MOCK_CLI_LOG" ]] ||
    fail "blocked commands reached the Playwright CLI"
  pass_test "browser launch and global cleanup commands are blocked"
}

test_symlink_lock_cannot_delete_outside_pid() {
  local outside_lock=""

  setup_case
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  outside_lock="$case_dir/outside-lock"
  /bin/mkdir "$outside_lock"
  /bin/chmod 700 "$outside_lock"
  printf '%s\n' "999999" >"$outside_lock/pid"
  /bin/chmod 600 "$outside_lock/pid"
  /bin/ln -s "$outside_lock" \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock"
  run_capture "$wrapper" ensure
  assert_status 1
  assert_contains "$output" "lock path is not a private owned directory"
  [[ "$(<"$outside_lock/pid")" == "999999" ]] ||
    fail "symlinked lock deleted or modified the outside PID file"
  pass_test "symlinked lock path cannot delete an outside PID file"
}

test_disconnect_preserves_normal_chrome_pid() {
  setup_case
  set_normal_chrome 111
  printf '%s\n' "ready" >"$MOCK_SESSION_STATE_FILE"
  run_capture "$wrapper" disconnect
  assert_status 0
  assert_contains "$output" "normal Chrome remains running (pid 111)"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  assert_file_contains "$MOCK_PS_OUTPUT_FILE" "111"
  pass_test "disconnect detaches without closing normal Chrome"
}

test_store_token_uses_keychain_and_clears_clipboard() {
  local token="TEST_ONLY_NEW_TOKEN_abcdefghijklmnopqrstuvwxyz123456"

  setup_case
  : >"$MOCK_KEYCHAIN_TOKEN_FILE"
  printf 'PLAYWRIGHT_MCP_EXTENSION_TOKEN=%s\n' "$token" >"$MOCK_CLIPBOARD_FILE"
  run_capture "$store_token"
  assert_status 0
  assert_contains "$output" "stored in macOS Keychain; clipboard cleared"
  assert_not_contains "$output" "$token"
  [[ "$(<"$MOCK_KEYCHAIN_TOKEN_FILE")" == "$token" ]] ||
    fail "mock Keychain did not receive the expected token"
  [[ ! -s "$MOCK_CLIPBOARD_FILE" ]] ||
    fail "clipboard was not cleared"
  pass_test "token setup stores without printing and clears the clipboard"
}

test_doctor_reports_version_compatibility() {
  setup_case
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  assert_contains "$output" "compatibility: supported (requires 0.1.17)"
  export MOCK_CLI_VERSION="9.9.9"
  : >"$MOCK_CLI_LOG"
  : >"$MOCK_SECURITY_LOG"
  run_capture "$wrapper" doctor
  assert_status 0
  assert_contains "$output" "compatibility: unsupported (requires 0.1.17)"
  assert_contains "$output" "session:   not checked (unsupported CLI)"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json list"
  assert_file_not_contains "$MOCK_SECURITY_LOG" "-w"
  pass_test "doctor reports supported and unsupported CLI versions"
}

test_traversal_metadata_cannot_escape_runtime() {
  local victim=""

  setup_case
  victim="$case_dir/victim"
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  /bin/mkdir "$victim"
  printf '%s\n' "keep" >"$victim/keep.txt"
  printf '%s\n' \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output.fake/../../victim" \
    >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path"
  printf '%s\n' "pending" \
    >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  /bin/chmod 600 \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  run_capture "$wrapper" safety-audit
  assert_status 1
  assert_contains "$output" "invalid; refusing cleanup"
  [[ "$(<"$victim/keep.txt")" == "keep" ]] ||
    fail "traversal-shaped metadata modified the outside victim"
  pass_test "cleanup rejects traversal-shaped output metadata"
}

test_symlink_metadata_cannot_modify_target() {
  local victim=""

  setup_case
  victim="$case_dir/victim.txt"
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  printf '%s\n' "keep" >"$victim"
  /bin/ln -s "$victim" \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path"
  printf '%s\n' "pending" \
    >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  /bin/chmod 600 "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  run_capture "$wrapper" safety-audit
  assert_status 1
  assert_contains "$output" "invalid; refusing cleanup"
  [[ "$(<"$victim")" == "keep" ]] ||
    fail "symlink metadata modified its target"
  pass_test "cleanup rejects symlink output metadata"
}

test_missing_chrome_refuses_before_token_read
test_ambiguous_chrome_refuses_before_token_read
test_successful_connect_uses_stable_existing_chrome
test_pid_change_during_attach_fails_closed
test_added_pid_during_attach_fails_closed
test_process_token_during_attach_fails_closed
test_pid_change_before_attach_never_invokes_attach
test_failed_attach_suppresses_token_and_scrubs_artifacts
test_hung_attach_is_terminated_and_scrubbed
test_hung_attach_reports_detach_failure
test_interrupted_attach_terminates_child_and_recovers
test_interrupted_post_attach_validation_recovers
test_unsupported_cli_version_blocks_browser_commands
test_unsupported_cli_version_blocks_disconnect
test_unsafe_commands_are_blocked_locally
test_symlink_lock_cannot_delete_outside_pid
test_disconnect_preserves_normal_chrome_pid
test_store_token_uses_keychain_and_clears_clipboard
test_doctor_reports_version_compatibility
test_traversal_metadata_cannot_escape_runtime
test_symlink_metadata_cannot_modify_target

cleanup_case
printf 'All %d behavior tests passed.\n' "$passed"
