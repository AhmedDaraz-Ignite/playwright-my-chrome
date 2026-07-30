#!/usr/bin/env bash
set -euo pipefail
umask 077

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
session_name="${PLAYWRIGHT_ACTIVE_CHROME_SESSION:-activechrome}"
keychain_service="${PLAYWRIGHT_ACTIVE_CHROME_KEYCHAIN_SERVICE:-playwright-active-chrome.extension-token}"
keychain_account="${PLAYWRIGHT_ACTIVE_CHROME_KEYCHAIN_ACCOUNT:-$(/usr/bin/id -un)}"
test_mode="${PLAYWRIGHT_ACTIVE_CHROME_TEST_MODE:-0}"
security_bin="/usr/bin/security"
extension_connect_url="chrome-extension://mmlmfjhmonkocbjadbfplnigmagldckm/connect.html"
chrome_executable="${PLAYWRIGHT_ACTIVE_CHROME_EXECUTABLE:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ps_bin="/bin/ps"
supported_cli_version="0.1.17"
attach_timeout_attempts=600
default_runtime_dir="$HOME/Library/Caches/playwright-active-chrome"
runtime_dir="${PLAYWRIGHT_ACTIVE_CHROME_RUNTIME_DIR:-$default_runtime_dir}"
while [[ "$runtime_dir" != "/" && "$runtime_dir" == */ ]]; do
  runtime_dir="${runtime_dir%/}"
done
lock_dir="$runtime_dir/ensure.lock"
sanitize_marker="$runtime_dir/needs-sanitize"
output_path_file="$runtime_dir/session-output-path"
token_rotation_baseline_file="$runtime_dir/token-rotation-baseline.sha256"
token_rotation_chrome_pid_file="$runtime_dir/token-rotation-chrome.pid"
runtime_claim="$runtime_dir/.playwright-active-chrome-runtime"
lock_held=0
bounded_child_pid=""
attachment_requires_recovery=0
listed_tabs=""

if [[ "$test_mode" == "1" ]]; then
  security_bin="${PLAYWRIGHT_ACTIVE_CHROME_TEST_SECURITY_BIN:-$security_bin}"
  ps_bin="${PLAYWRIGHT_ACTIVE_CHROME_TEST_PS_BIN:-$ps_bin}"
  attach_timeout_attempts="${PLAYWRIGHT_ACTIVE_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS:-$attach_timeout_attempts}"
elif [[ "$test_mode" != "0" ]]; then
  echo "ERROR: PLAYWRIGHT_ACTIVE_CHROME_TEST_MODE must be 0 or 1." >&2
  exit 1
fi
die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$attach_timeout_attempts" =~ ^[1-9][0-9]*$ ]] ||
  die "The attach timeout must be a positive number of 100ms attempts."
[[ -n "$session_name" ]] || die "The active-Chrome session name cannot be empty."
[[ -n "$keychain_service" ]] || die "The Keychain service cannot be empty."
[[ -n "$keychain_account" ]] || die "The Keychain account cannot be empty."
[[ -n "$runtime_dir" ]] || die "The active-Chrome runtime directory cannot be empty."
[[ "$runtime_dir" == /* ]] ||
  die "The active-Chrome runtime directory must be an absolute path."
[[ "$runtime_dir" != "/" && "$runtime_dir" != "$HOME" ]] ||
  die "Refusing to use a broad directory as the active-Chrome runtime."
[[ "$security_bin" == /* && -x "$security_bin" ]] ||
  die "The configured macOS Keychain executable is unavailable."
[[ "$chrome_executable" == /* ]] ||
  die "The configured Google Chrome executable must be an absolute path."
if [[ "$test_mode" != "1" && ! -x "$chrome_executable" ]]; then
  die "Google Chrome is unavailable at: $chrome_executable"
fi
[[ "$ps_bin" == /* && -x "$ps_bin" ]] ||
  die "The configured process-list executable is unavailable."

resolve_cli() {
  local candidate=""
  local candidate_base=""
  local candidate_dir=""
  local best=""

  if [[ -n "${PLAYWRIGHT_ACTIVE_CHROME_CLI:-}" ]]; then
    candidate="$PLAYWRIGHT_ACTIVE_CHROME_CLI"
    [[ "$candidate" == /* ]] || {
      echo "Configured Playwright CLI path must be absolute: $candidate" >&2
      return 1
    }
    [[ -x "$candidate" ]] || {
      echo "Configured Playwright CLI is not executable: $candidate" >&2
      return 1
    }
  else
    shopt -s nullglob
    for candidate in "$HOME"/.nvm/versions/node/*/bin/playwright-cli; do
      if [[ -z "$best" || "$candidate" -nt "$best" ]]; then
        best="$candidate"
      fi
    done
    shopt -u nullglob

    if [[ -n "$best" ]]; then
      candidate="$best"
    else
      for candidate in \
        "$HOME/.volta/bin/playwright-cli" \
        /opt/homebrew/bin/playwright-cli \
        /usr/local/bin/playwright-cli; do
        if [[ -x "$candidate" ]]; then
          break
        fi
        candidate=""
      done
    fi
  fi

  [[ -n "$candidate" && -x "$candidate" ]] || return 1
  if [[ "$candidate" != /* ]]; then
    candidate="$PWD/$candidate"
  fi

  candidate_dir="${candidate%/*}"
  candidate_base="${candidate##*/}"
  candidate_dir="$(cd -P "$candidate_dir" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$candidate_dir" "$candidate_base"
}

cli_bin="$(resolve_cli)" || {
  echo "Playwright CLI was not found." >&2
  echo "Configure PLAYWRIGHT_ACTIVE_CHROME_CLI with an absolute trusted executable." >&2
  echo "This skill never installs or upgrades the shared Playwright CLI." >&2
  exit 2
}

cli_dir="${cli_bin%/*}"
resolve_node() {
  local best=""
  local candidate=""

  if [[ -n "${PLAYWRIGHT_ACTIVE_CHROME_NODE:-}" ]]; then
    candidate="$PLAYWRIGHT_ACTIVE_CHROME_NODE"
    [[ "$candidate" == /* && -x "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -x "$cli_dir/node" ]]; then
    printf '%s\n' "$cli_dir/node"
    return 0
  fi

  shopt -s nullglob
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node; do
    if [[ -z "$best" || "$candidate" -nt "$best" ]]; then
      best="$candidate"
    fi
  done
  shopt -u nullglob

  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
    return 0
  fi

  for candidate in \
    "$HOME/.volta/bin/node" \
    /opt/homebrew/bin/node \
    /usr/local/bin/node; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

json_node="$(resolve_node)" ||
  die "Node.js was not found in a trusted absolute location."
cli_shebang=""
IFS= read -r cli_shebang <"$cli_bin" || true
if [[ "$cli_shebang" == "#!"*"node"* ]]; then
  cli_command=("$json_node" "$cli_bin")
else
  cli_command=("$cli_bin")
fi
unset cli_shebang

if [[ -L "$runtime_dir" ]]; then
  die "The active-Chrome runtime cannot be a symbolic link: $runtime_dir"
fi
if [[ -e "$runtime_dir" && ! -d "$runtime_dir" ]]; then
  die "The active-Chrome runtime is not a directory: $runtime_dir"
fi
if [[ ! -d "$runtime_dir" ]] && ! /bin/mkdir -p "$runtime_dir"; then
  die "Could not create the private Playwright runtime: $runtime_dir"
fi
[[ -O "$runtime_dir" ]] ||
  die "The private Playwright runtime is not owned by the current user."
[[ "$(/usr/bin/stat -f '%Lp' "$runtime_dir")" == "700" ]] ||
  die "The private Playwright runtime must have mode 0700: $runtime_dir"

if [[ -L "$runtime_claim" ]]; then
  die "The active-Chrome runtime claim cannot be a symbolic link."
fi
if [[ -e "$runtime_claim" && ! -f "$runtime_claim" ]]; then
  die "The active-Chrome runtime claim is not a regular file."
fi
if [[ ! -f "$runtime_claim" ]]; then
  if [[ "$runtime_dir" != "$default_runtime_dir" ]] &&
    [[ -n "$(/usr/bin/find "$runtime_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "Refusing to claim a non-empty custom runtime directory."
  fi
  printf '%s\n' "playwright-active-chrome-runtime-v1" >"$runtime_claim" ||
    die "Could not claim the private Playwright runtime."
fi
[[ -O "$runtime_claim" ]] ||
  die "The active-Chrome runtime claim is not owned by the current user."
[[ "$(/usr/bin/stat -f '%Lp' "$runtime_claim")" == "600" ]] ||
  die "The active-Chrome runtime claim must have mode 0600."
IFS= read -r runtime_claim_value <"$runtime_claim" ||
  die "Could not read the active-Chrome runtime claim."
[[ "$runtime_claim_value" == "playwright-active-chrome-runtime-v1" ]] ||
  die "The active-Chrome runtime claim is invalid."
unset runtime_claim_value

if [[ -L "$runtime_dir/.playwright" ]]; then
  die "The Playwright workspace marker cannot be a symbolic link."
fi
if [[ -e "$runtime_dir/.playwright" && ! -d "$runtime_dir/.playwright" ]]; then
  die "The Playwright workspace marker is not a directory."
fi
if [[ ! -d "$runtime_dir/.playwright" ]] &&
  ! /bin/mkdir "$runtime_dir/.playwright"; then
  die "Could not create the private Playwright workspace."
fi
[[ -O "$runtime_dir/.playwright" ]] ||
  die "The private Playwright workspace is not owned by the current user."
[[ "$(/usr/bin/stat -f '%Lp' "$runtime_dir/.playwright")" == "700" ]] ||
  die "The private Playwright workspace must have mode 0700."

# All secret-bearing processing below uses resolved executables plus trusted
# macOS system utilities rather than caller-controlled PATH shims.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# Playwright CLI keys daemon sessions by the nearest .playwright workspace.
# The private marker above makes activechrome stable across repositories and
# isolated from ordinary unscoped Playwright CLI invocations.
run_cli() {
  (
    cd "$runtime_dir"
    NO_UPDATE_NOTIFIER=1 "${cli_command[@]}" "$@"
  )
}

is_allowed_state_file() {
  case "$1" in
    "$output_path_file"|"$sanitize_marker"|"$token_rotation_baseline_file"|"$token_rotation_chrome_pid_file")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

private_state_file_is_valid() {
  local file="$1"

  is_allowed_state_file "$file" || return 1
  [[ -f "$file" && ! -L "$file" && -O "$file" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$file")" == "600" ]]
}

write_private_state_file() {
  local target="$1"
  local value="$2"
  local temporary=""

  is_allowed_state_file "$target" || return 1
  temporary="$(/usr/bin/mktemp "$runtime_dir/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" >"$temporary"; then
    /bin/rm -f "$temporary"
    return 1
  fi
  if ! "$json_node" -e '
    const fs = require("fs");
    fs.renameSync(process.argv[1], process.argv[2]);
  ' "$temporary" "$target"; then
    /bin/rm -f "$temporary"
    return 1
  fi
  private_state_file_is_valid "$target"
}

remove_private_state_file() {
  local target="$1"

  is_allowed_state_file "$target" || return 1
  /bin/rm -f "$target"
}

current_cli_version() {
  run_cli_bounded 80 --version 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

require_supported_cli() {
  local version=""

  if ! version="$(current_cli_version)"; then
    version=""
  fi
  if [[ "$version" == "$supported_cli_version" ]]; then
    return 0
  fi

  echo "Unsupported Playwright CLI version: ${version:-unknown}" >&2
  echo "This release requires @playwright/cli $supported_cli_version." >&2
  echo "See the repository README for installation instructions." >&2
  echo "No browser command was attempted." >&2
  return 2
}

run_cli_redacted() {
  local statuses=()

  set +e
  run_cli "$@" 2>&1 |
    sed -E \
      "s#(${extension_connect_url//./\\.})\\?[^\\\")[:space:]]*#\\1?<redacted>#g"
  statuses=("${PIPESTATUS[@]}")
  set -e
  return "${statuses[0]}"
}

terminate_bounded_process() {
  local attempt=0
  local child_pid="$1"
  local descendant_pid=""
  local descendant_pids=""
  local running=0

  [[ "$child_pid" =~ ^[0-9]+$ ]] || return 0
  descendant_pids="$(/usr/bin/pgrep -P "$child_pid" 2>/dev/null || true)"
  for descendant_pid in $descendant_pids; do
    [[ "$descendant_pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$descendant_pid" 2>/dev/null || true
  done
  kill -TERM "$child_pid" 2>/dev/null || true

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    running=0
    kill -0 "$child_pid" 2>/dev/null && running=1
    for descendant_pid in $descendant_pids; do
      [[ "$descendant_pid" =~ ^[0-9]+$ ]] || continue
      kill -0 "$descendant_pid" 2>/dev/null && running=1
    done
    (( running == 0 )) && break
    sleep 0.1
  done

  for descendant_pid in $descendant_pids; do
    [[ "$descendant_pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$descendant_pid" 2>/dev/null; then
      kill -KILL "$descendant_pid" 2>/dev/null || true
    fi
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  wait "$child_pid" 2>/dev/null || true
}

terminate_active_bounded_child() {
  local child_pid="$bounded_child_pid"

  bounded_child_pid=""
  terminate_bounded_process "$child_pid"
}

run_cli_bounded_impl() {
  local attempt=0
  local child_pid=""
  local max_attempts="${2:?missing timeout attempts}"
  local output_file="$1"
  local status=0
  shift 2

  if [[ -n "$output_file" ]]; then
    (
      cd "$runtime_dir"
      exec env NO_UPDATE_NOTIFIER=1 "${cli_command[@]}" "$@"
    ) >"$output_file" 2>&1 &
  else
    (
      cd "$runtime_dir"
      exec env NO_UPDATE_NOTIFIER=1 "${cli_command[@]}" "$@"
    ) &
  fi
  child_pid=$!
  bounded_child_pid="$child_pid"

  while kill -0 "$child_pid" 2>/dev/null; do
    if (( attempt >= max_attempts )); then
      terminate_active_bounded_child
      return 124
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done

  if wait "$child_pid"; then
    status=0
  else
    status=$?
  fi
  bounded_child_pid=""
  return "$status"
}

run_cli_bounded() {
  local max_attempts="${1:?missing timeout attempts}"
  shift

  run_cli_bounded_impl "" "$max_attempts" "$@"
}

run_cli_bounded_to_file() {
  local max_attempts="${2:?missing timeout attempts}"
  local output_file="${1:?missing output file}"
  shift 2

  [[ "$output_file" == /* ]] || return 1
  run_cli_bounded_impl "$output_file" "$max_attempts" "$@"
}

read_token() {
  local token=""

  if [[ ! -x "$security_bin" ]]; then
    echo "macOS Keychain command 'security' is unavailable." >&2
    return 1
  fi

  token="$(
    "$security_bin" find-generic-password \
      -a "$keychain_account" \
      -s "$keychain_service" \
      -w 2>/dev/null || true
  )"

  if [[ ! "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]]; then
    echo "Playwright Extension token is missing or invalid in macOS Keychain." >&2
    echo "Regenerate and copy it in the extension, then run:" >&2
    echo "  $skill_dir/scripts/store-extension-token.sh" >&2
    return 1
  fi

  printf '%s' "$token"
}

token_is_stored() {
  [[ -x "$security_bin" ]] &&
    "$security_bin" find-generic-password \
      -a "$keychain_account" \
      -s "$keychain_service" >/dev/null 2>&1
}

current_token_digest() {
  local digest=""
  local token=""

  token="$(read_token)" || return 1
  digest="$(
    printf '%s' "$token" |
      /usr/bin/shasum -a 256 |
      awk '{ print $1 }'
  )"
  unset token
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

rotation_state() {
  local baseline=""
  local chrome_count=0
  local chrome_pid=""
  local chrome_pids=""
  local current=""
  local regeneration_pid=""
  local process_state=""

  if [[ ! -e "$token_rotation_baseline_file" &&
    ! -L "$token_rotation_baseline_file" ]]; then
    printf '%s\n' "not-started"
    return 0
  fi
  if ! private_state_file_is_valid "$token_rotation_baseline_file"; then
    printf '%s\n' "invalid-baseline"
    return 0
  fi
  IFS= read -r baseline <"$token_rotation_baseline_file" || {
    printf '%s\n' "invalid-baseline"
    return 0
  }
  if [[ ! "$baseline" =~ ^[a-f0-9]{64}$ ]]; then
    printf '%s\n' "invalid-baseline"
    return 0
  fi
  current="$(current_token_digest 2>/dev/null)" || {
    printf '%s\n' "token-missing"
    return 0
  }
  if [[ "$current" == "$baseline" ]]; then
    printf '%s\n' "pending"
    return 0
  fi
  if [[ ! -e "$token_rotation_chrome_pid_file" &&
    ! -L "$token_rotation_chrome_pid_file" ]]; then
    printf '%s\n' "regenerated-unmarked"
    return 0
  fi
  if ! private_state_file_is_valid "$token_rotation_chrome_pid_file"; then
    printf '%s\n' "invalid-regeneration-marker"
    return 0
  fi
  IFS= read -r regeneration_pid <"$token_rotation_chrome_pid_file" || {
    printf '%s\n' "invalid-regeneration-marker"
    return 0
  }
  if [[ ! "$regeneration_pid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "invalid-regeneration-marker"
    return 0
  fi
  process_state="$(persistent_extension_token_state)"
  if [[ "$process_state" != "absent" ]]; then
    printf '%s\n' "rotated-process-exposed"
    return 0
  fi
  chrome_pids="$(normal_chrome_pids)"
  chrome_count="$(printf '%s\n' "$chrome_pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( chrome_count == 0 )); then
    printf '%s\n' "awaiting-reopen"
  elif (( chrome_count > 1 )); then
    printf '%s\n' "ambiguous-chrome"
  else
    chrome_pid="$chrome_pids"
    if [[ "$chrome_pid" == "$regeneration_pid" ]]; then
      printf '%s\n' "awaiting-restart"
    else
      printf '%s\n' "verified"
    fi
  fi
}

rotation_metadata_state() {
  if [[ ! -e "$token_rotation_baseline_file" &&
    ! -L "$token_rotation_baseline_file" ]]; then
    printf '%s\n' "not started"
    return 0
  fi
  if ! private_state_file_is_valid "$token_rotation_baseline_file"; then
    printf '%s\n' "invalid private baseline"
    return 0
  fi
  if [[ -e "$token_rotation_chrome_pid_file" ||
    -L "$token_rotation_chrome_pid_file" ]] &&
    ! private_state_file_is_valid "$token_rotation_chrome_pid_file"; then
    printf '%s\n' "invalid private regeneration marker"
    return 0
  fi
  printf '%s\n' "in progress (run rotation-status to verify)"
}

begin_token_rotation() {
  local digest=""

  if [[ "$(persistent_extension_token_state)" != "absent" ]]; then
    echo "A token-bearing Chrome process is still running." >&2
    echo "Disconnect and fully close Chrome before beginning rotation." >&2
    return 1
  fi
  digest="$(current_token_digest)" || return 1
  if ! write_private_state_file "$token_rotation_baseline_file" "$digest"; then
    echo "Could not record the private token-rotation baseline." >&2
    return 1
  fi
  unset digest
  remove_private_state_file "$token_rotation_chrome_pid_file" || return 1
  echo "Token-rotation baseline recorded privately."
  echo "Regenerate and copy the extension token, then run store-extension-token.sh."
}

mark_token_regenerated() {
  local baseline=""
  local chrome_pid=""
  local current=""

  private_state_file_is_valid "$token_rotation_baseline_file" || {
    echo "Token rotation has not been started." >&2
    return 1
  }
  IFS= read -r baseline <"$token_rotation_baseline_file" || return 1
  current="$(current_token_digest)" || return 1
  if [[ "$current" == "$baseline" ]]; then
    echo "The stored extension token has not changed." >&2
    return 1
  fi
  chrome_pid="$(require_running_normal_chrome)" || return $?
  if ! write_private_state_file "$token_rotation_chrome_pid_file" "$chrome_pid"; then
    echo "Could not record the post-regeneration Chrome process." >&2
    return 1
  fi
  echo "Regenerated token recorded for Chrome pid $chrome_pid."
  echo "Fully restart Chrome manually; rotation remains incomplete until its pid changes."
}

token_rotation_status() {
  local state=""

  state="$(rotation_state)"
  echo "Playwright Extension token rotation"
  case "$state" in
    not-started)
      echo "rotation: not started"
      ;;
    pending)
      echo "rotation: pending (stored token has not changed)"
      ;;
    regenerated-unmarked)
      echo "rotation: regenerated token must be marked before restart"
      ;;
    awaiting-restart)
      echo "rotation: awaiting Chrome restart after regeneration"
      ;;
    awaiting-reopen)
      echo "rotation: awaiting Chrome reopen after regeneration"
      ;;
    ambiguous-chrome)
      echo "rotation: incomplete (multiple normal Chrome main processes are running)"
      ;;
    verified)
      echo "rotation: VERIFIED (token changed; Chrome restarted; process token absent)"
      if ! remove_private_state_file "$token_rotation_baseline_file" ||
        ! remove_private_state_file "$token_rotation_chrome_pid_file"; then
        echo "Could not clear completed token-rotation metadata." >&2
        return 1
      fi
      ;;
    rotated-process-exposed)
      echo "rotation: incomplete (stored token changed; process token exposed)"
      ;;
    token-missing)
      echo "rotation: incomplete (replacement token is not stored)"
      ;;
    invalid-baseline)
      echo "rotation: invalid private baseline"
      ;;
    invalid-regeneration-marker)
      echo "rotation: invalid private regeneration marker"
      ;;
    *)
      echo "rotation: unknown"
      return 1
      ;;
  esac
}

normal_chrome_pids() {
  "$ps_bin" -axo pid=,command= |
    awk -v executable="$chrome_executable" '
      {
        pid = $1
        $1 = ""
        sub(/^[[:space:]]+/, "")
        command = $0
        if (index(command, executable) != 1)
          next
        if (command ~ /--user-data-dir=/)
          next
        if (command ~ /--remote-debugging-(pipe|port)/)
          next
        if (command ~ /--headless([=[:space:]]|$)/)
          next
        if (command ~ /--enable-automation([=[:space:]]|$)/)
          next
        if (command ~ /--test-type=webdriver([=[:space:]]|$)/)
          next
        if (command ~ /--no-startup-window([=[:space:]]|$)/)
          next
        print pid
      }
    ' |
    /usr/bin/sort -n -u
}

normal_chrome_pid() {
  normal_chrome_pids | awk 'NR == 1 { print; exit }'
}

require_running_normal_chrome() {
  local count=0
  local pid=""
  local pids=""

  pids="$(normal_chrome_pids)"
  count="$(printf '%s\n' "$pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( count == 1 )); then
    pid="$pids"
    printf '%s\n' "$pid"
    return 0
  fi
  if (( count > 1 )); then
    echo "Multiple normal Google Chrome main processes are running." >&2
    echo "No extension connection was attempted because browser ownership is ambiguous." >&2
    echo "Fully quit the extra Chrome instances, then run 'connect' again." >&2
    return 5
  fi

  echo "Normal user Chrome is not already running." >&2
  echo "No browser was launched and no extension connection was attempted." >&2
  echo "Open Google Chrome manually in the signed-in profile, then run 'connect' again." >&2
  return 5
}

persistent_extension_token_state() {
  if "$ps_bin" -axo command= |
    awk -v executable="$chrome_executable" -v connect_url="$extension_connect_url" '
      index($0, executable) == 1 &&
      index($0, connect_url) > 0 &&
      $0 ~ /[?&]token=[A-Za-z0-9_-]+/ {
        found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '; then
    printf '%s\n' "exposed"
  else
    printf '%s\n' "absent"
  fi
}

session_state_once() {
  local payload=""

  if ! payload="$(run_cli_bounded 80 --json list 2>/dev/null)"; then
    printf '%s\n' "unavailable"
    return 0
  fi

  printf '%s' "$payload" |
    "$json_node" -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", chunk => input += chunk);
      process.stdin.on("end", () => {
        try {
          const payload = JSON.parse(input);
          const browser = (payload.browsers || []).find(
            item => item.name === process.argv[1]
          );
          if (!browser) {
            process.stdout.write("missing\n");
          } else if (
            browser.status === "open" &&
            browser.attached === true &&
            browser.compatible !== false
          ) {
            process.stdout.write("ready\n");
          } else {
            process.stdout.write("stale\n");
          }
        } catch {
          process.stdout.write("unavailable\n");
        }
      });
    ' "$session_name"
}

session_state() {
  local attempt=0
  local state=""

  while (( attempt < 3 )); do
    state="$(session_state_once)"
    if [[ "$state" != "unavailable" ]]; then
      printf '%s\n' "$state"
      return 0
    fi
    attempt=$((attempt + 1))
    (( attempt < 3 )) && sleep 0.1
  done

  printf '%s\n' "unavailable"
}

conflicting_attached_chrome_sessions() {
  local payload=""
  local result=""

  payload="$(run_cli_bounded 80 --json list --all 2>/dev/null)" || return 2
  result="$(
    printf '%s' "$payload" |
      "$json_node" -e '
        let input = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => input += chunk);
        process.stdin.on("end", () => {
          try {
            const payload = JSON.parse(input);
            const conflicts = (payload.browsers || []).filter(browser =>
              browser.status === "open" &&
              browser.attached === true &&
              !(
                browser.workspace === process.argv[2] &&
                browser.name === process.argv[1]
              ) &&
              (
                browser.name === process.argv[1] ||
                browser.browserType === "chrome"
              )
            );
            process.stdout.write(
              conflicts
                .map(browser =>
                  browser.name + " (" + browser.workspace + ")"
                )
                .join("\n")
            );
          } catch {
            process.exitCode = 2;
          }
        });
      ' "$session_name" "$runtime_dir"
  )" || return 2

  printf '%s' "$result"
}

list_tabs() {
  local attempt=0
  local tabs=""

  while (( attempt < 3 )); do
    if tabs="$(
      run_cli_bounded 80 --raw -s="$session_name" tab-list 2>/dev/null
    )"; then
      printf '%s\n' "$tabs"
      return 0
    fi
    attempt=$((attempt + 1))
    (( attempt < 3 )) && sleep 0.1
  done

  return 1
}

list_tabs_guarded() {
  local attempt=0
  local output_file="${1:?missing guarded tab output file}"
  local output_dir="${output_file%/*}"

  [[ "$output_file" == "$output_dir/tabs.log" ]] || return 1
  output_directory_is_valid "$output_dir" || return 1
  listed_tabs=""
  while (( attempt < 3 )); do
    if run_cli_bounded_to_file "$output_file" 80 --raw \
      -s="$session_name" tab-list; then
      listed_tabs="$(<"$output_file")"
      return 0
    fi
    attempt=$((attempt + 1))
    (( attempt < 3 )) && sleep 0.1
  done

  return 1
}

helper_tab_line() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      {
        # Playwright renders each tab as Markdown. Inspect only the final URL
        # field so a hostile page title containing the helper URL cannot be
        # mistaken for the extension helper.
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url == needle || index(url, needle "?") == 1) {
          print
          exit
        }
      }
    '
}

non_helper_tab_index() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      $1 == "-" && $2 ~ /^[0-9]+:$/ {
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url != needle && index(url, needle "?") != 1) {
          sub(/:$/, "", $2)
          print $2
          exit
        }
      }
    '
}

has_current_non_helper_tab() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      $1 == "-" && $2 ~ /^[0-9]+:$/ && index($0, "(current)") {
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url != needle && index(url, needle "?") != 1)
          found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '
}

has_non_helper_tab() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      $1 == "-" && $2 ~ /^[0-9]+:$/ {
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url != needle && index(url, needle "?") != 1)
          found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '
}

known_output_dir() {
  local base=""
  local directory=""

  if [[ ! -e "$output_path_file" && ! -L "$output_path_file" ]]; then
    return 1
  fi
  private_state_file_is_valid "$output_path_file" || return 2
  exec 3<"$output_path_file"
  IFS= read -r directory <&3 || {
    exec 3<&-
    return 2
  }
  if IFS= read -r <&3; then
    exec 3<&-
    return 2
  fi
  exec 3<&-
  base="${directory#"$runtime_dir"/}"
  [[ "$directory" == "$runtime_dir/$base" ]] || return 2
  [[ "$base" != */* ]] || return 2
  [[ "$base" =~ ^session-output\.[A-Za-z0-9]{6}$ ]] || return 2
  printf '%s\n' "$directory"
}

output_directory_is_valid() {
  local base=""
  local directory="$1"

  base="${directory#"$runtime_dir"/}"
  [[ "$directory" == "$runtime_dir/$base" ]] || return 1
  [[ "$base" != */* ]] || return 1
  [[ "$base" =~ ^session-output\.[A-Za-z0-9]{6}$ ]] || return 1
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$directory")" == "700" ]]
}

scrub_directory() {
  local directory="$1"
  local remaining=""

  [[ -n "$directory" ]] || return 1
  if [[ ! -e "$directory" && ! -L "$directory" ]]; then
    return 0
  fi
  output_directory_is_valid "$directory" || return 1
  if ! /usr/bin/find "$directory" -depth -mindepth 1 -delete 2>/dev/null; then
    return 1
  fi
  remaining="$(/usr/bin/find "$directory" -mindepth 1 -print -quit 2>/dev/null)" ||
    return 1
  [[ -z "$remaining" ]]
}

scrub_known_output() {
  local directory=""
  local status=0

  directory="$(known_output_dir)" || status=$?
  if (( status == 1 )); then
    return 0
  elif (( status != 0 )); then
    echo "Private Playwright output metadata is invalid; refusing cleanup." >&2
    return 1
  fi
  scrub_directory "$directory"
}

remove_known_output() {
  local directory=""
  local status=0

  directory="$(known_output_dir)" || status=$?
  if (( status == 1 )); then
    remove_private_state_file "$sanitize_marker" || return 1
    return 0
  elif (( status != 0 )); then
    echo "Private Playwright output metadata is invalid; refusing cleanup." >&2
    return 1
  fi
  scrub_directory "$directory" || return 1
  if [[ -d "$directory" ]] && ! rmdir "$directory" 2>/dev/null; then
    return 1
  fi
  remove_private_state_file "$output_path_file" || return 1
  remove_private_state_file "$sanitize_marker" || return 1
}

sanitize_bootstrap_tab() {
  local initial_tabs="$1"
  local guarded_output_file="${2:-}"
  local attempt=0
  local helper_line=""
  local non_helper_index=""
  local tabs="$initial_tabs"

  helper_line="$(helper_tab_line "$tabs")"
  if [[ -z "$helper_line" ]]; then
    echo "Playwright's required extension helper tab is unavailable." >&2
    echo "The owned session cannot be considered persistent." >&2
    return 1
  fi

  # connect.html owns the extension heartbeat and cannot be evaluated,
  # navigated, or closed through this relay. Keep it untouched in the
  # background and ensure a normal controlled tab has focus.
  if has_current_non_helper_tab "$tabs"; then
    return 0
  fi

  if has_non_helper_tab "$tabs"; then
    non_helper_index="$(non_helper_tab_index "$tabs")"
    if [[ -z "$non_helper_index" ]] ||
      ! run_cli_bounded 80 --raw -s="$session_name" \
        tab-select "$non_helper_index" >/dev/null 2>&1; then
      echo "Playwright attached, but could not foreground a controlled tab." >&2
      return 1
    fi
  else
    if ! run_cli_bounded 80 --raw -s="$session_name" tab-new \
      >/dev/null 2>&1; then
      echo "Playwright attached, but could not create a safe foreground tab." >&2
      return 1
    fi
  fi

  attempt=0
  while (( attempt < 30 )); do
    if [[ -n "$guarded_output_file" ]]; then
      list_tabs_guarded "$guarded_output_file" || return 1
      tabs="$listed_tabs"
    else
      tabs="$(list_tabs)" || return 1
    fi
    if [[ -n "$(helper_tab_line "$tabs")" ]] &&
      has_current_non_helper_tab "$tabs"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done

  echo "Playwright attached, but its foreground tab did not become current." >&2
  return 1
}

finalize_sanitation() {
  local guarded_output_file="${2:-}"
  local marker_exists=0
  local sanitize_status=0
  local scrub_status=0
  local tabs="$1"

  if [[ -e "$sanitize_marker" || -L "$sanitize_marker" ]]; then
    private_state_file_is_valid "$sanitize_marker" || {
      echo "The Playwright sanitation marker is invalid." >&2
      return 1
    }
    marker_exists=1
  fi

  if [[ -n "$(helper_tab_line "$tabs")" && "$marker_exists" == "0" ]]; then
    if ! write_private_state_file "$sanitize_marker" "pending"; then
      echo "Could not mark the Playwright helper tab for sanitation." >&2
      return 1
    fi
    marker_exists=1
  fi

  sanitize_bootstrap_tab "$tabs" "$guarded_output_file" ||
    sanitize_status=$?

  if (( marker_exists == 1 )); then
    if ! scrub_known_output; then
      echo "Could not securely scrub Playwright bootstrap artifacts." >&2
      scrub_status=1
    fi
    if (( sanitize_status == 0 && scrub_status == 0 )); then
      if ! remove_private_state_file "$sanitize_marker"; then
        echo "Could not clear the Playwright sanitation marker." >&2
        scrub_status=1
      fi
    fi
  fi

  if (( sanitize_status != 0 )); then
    return "$sanitize_status"
  fi
  return "$scrub_status"
}

lock_directory_is_valid() {
  [[ -d "$lock_dir" && ! -L "$lock_dir" && -O "$lock_dir" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$lock_dir")" == "700" ]]
}

lock_pid_file_is_valid() {
  local pid_file="$lock_dir/pid"

  [[ -f "$pid_file" && ! -L "$pid_file" && -O "$pid_file" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$pid_file")" == "600" ]]
}

remove_lock_safely() {
  local pid_file="$lock_dir/pid"

  lock_directory_is_valid || return 1
  if [[ -e "$pid_file" || -L "$pid_file" ]]; then
    lock_pid_file_is_valid || return 1
    /bin/rm -f "$pid_file" || return 1
  fi
  /bin/rmdir "$lock_dir" 2>/dev/null
}

release_lock() {
  if (( lock_held == 1 )); then
    if ! remove_lock_safely; then
      echo "WARNING: Could not safely remove the active-Chrome lock." >&2
    fi
    lock_held=0
  fi
}

acquire_lock() {
  local attempts=0
  local owner=""
  local ownerless_attempts=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    if ! lock_directory_is_valid; then
      echo "The active-Chrome lock path is not a private owned directory." >&2
      echo "Refusing to read or remove it." >&2
      return 1
    fi
    owner=""
    if [[ -e "$lock_dir/pid" || -L "$lock_dir/pid" ]]; then
      if ! lock_pid_file_is_valid; then
        echo "The active-Chrome lock PID file is not a private owned regular file." >&2
        echo "Refusing to read or remove it." >&2
        return 1
      fi
      read -r owner <"$lock_dir/pid" || owner=""
    fi

    if [[ -n "$owner" && "$owner" =~ ^[0-9]+$ ]]; then
      ownerless_attempts=0
      if ! kill -0 "$owner" 2>/dev/null; then
        if ! remove_lock_safely; then
          echo "Could not safely remove a stale active-Chrome lock." >&2
          return 1
        fi
        continue
      fi
    else
      ownerless_attempts=$((ownerless_attempts + 1))
      if (( ownerless_attempts >= 20 )); then
        if ! remove_lock_safely; then
          echo "Could not safely remove an ownerless active-Chrome lock." >&2
          return 1
        fi
        ownerless_attempts=0
        continue
      fi
    fi

    if (( attempts >= 200 )); then
      echo "Timed out waiting for another active-Chrome connection attempt." >&2
      return 1
    fi

    attempts=$((attempts + 1))
    sleep 0.1
  done

  if ! lock_directory_is_valid; then
    echo "The newly created active-Chrome lock is invalid." >&2
    return 1
  fi
  if ! printf '%s\n' "$$" >"$lock_dir/pid"; then
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  if ! lock_pid_file_is_valid; then
    /bin/rm -f "$lock_dir/pid"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  lock_held=1
}

cleanup_on_exit() {
  local attachment_recovery=0

  if (( attachment_requires_recovery == 1 )); then
    attachment_recovery=1
    attachment_requires_recovery=0
    unset PLAYWRIGHT_MCP_EXTENSION_TOKEN
    unset token 2>/dev/null || true
  fi
  terminate_active_bounded_child
  if (( attachment_recovery == 1 )); then
    echo "SECURITY: Attachment was interrupted; running targeted recovery." >&2
    detach_failed_attachment || true
    if ! remove_known_output; then
      echo "WARNING: Interrupted attachment artifacts still require cleanup." >&2
    fi
  fi
  release_lock
  if [[ -e "$sanitize_marker" || -L "$sanitize_marker" ]]; then
    if ! private_state_file_is_valid "$sanitize_marker" ||
      ! scrub_known_output; then
      echo "WARNING: Playwright bootstrap artifacts still require cleanup." >&2
    fi
  fi
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -e "$sanitize_marker" || -L "$sanitize_marker" ]]; then
  if ! private_state_file_is_valid "$sanitize_marker" ||
    ! scrub_known_output; then
    die "Could not securely scrub pending Playwright bootstrap artifacts."
  fi
fi

assert_no_attached_chrome_conflict() {
  local conflicts=""

  if ! conflicts="$(conflicting_attached_chrome_sessions)"; then
    echo "Could not inspect other Playwright workspaces safely." >&2
    echo "No attachment was attempted." >&2
    return 1
  fi
  if [[ -n "$conflicts" ]]; then
    echo "Another workspace already owns a potentially conflicting attached Chrome session:" >&2
    printf '  %s\n' "$conflicts" >&2
    echo "Disconnect that session before attaching this shared wrapper." >&2
    return 1
  fi
}

detach_failed_attachment() {
  local status=0

  run_cli_bounded 80 -s="$session_name" detach >/dev/null 2>&1 || status=$?
  if (( status == 0 )); then
    echo "The named Playwright session was detached." >&2
    return 0
  fi

  echo "SECURITY: Automatic session detachment failed (status $status)." >&2
  echo "Treat the session as connected; fully quit Chrome and rotate the token." >&2
  return "$status"
}

attach_session() {
  local attach_config=""
  local attach_log=""
  local attach_output_dir=""
  local attach_status=0
  local chrome_pids_after=""
  local chrome_pids_before=""
  local chrome_pids_current=""
  local cleanup_status=0
  local detach_status=0
  local process_token_state=""
  local tabs=""
  local tabs_output=""
  local token=""

  chrome_pids_before="$(require_running_normal_chrome)" || return $?
  assert_no_attached_chrome_conflict || return 1
  token="$(read_token)" || return 3
  if ! attach_output_dir="$(mktemp -d "$runtime_dir/session-output.XXXXXX")"; then
    unset token
    echo "Could not create a private Playwright bootstrap directory." >&2
    return 1
  fi
  attach_config="$attach_output_dir/cli.config.json"
  attach_log="$attach_output_dir/attach.log"
  tabs_output="$attach_output_dir/tabs.log"

  if ! write_private_state_file "$output_path_file" "$attach_output_dir"; then
    rmdir "$attach_output_dir" 2>/dev/null || true
    unset token
    return 1
  fi
  if ! write_private_state_file "$sanitize_marker" "pending"; then
    remove_known_output || true
    unset token
    echo "Could not mark the Playwright bootstrap for sanitation." >&2
    return 1
  fi

  if ! "$json_node" -e '
    const fs = require("fs");
    fs.writeFileSync(
      process.argv[1],
      JSON.stringify({ outputDir: process.argv[2] })
    );
  ' "$attach_config" "$attach_output_dir"; then
    if ! remove_known_output; then
      echo "Could not securely remove the failed bootstrap directory." >&2
    fi
    unset token
    echo "Could not create the private Playwright bootstrap configuration." >&2
    return 1
  fi

  chrome_pids_current="$(normal_chrome_pids)"
  if [[ -z "$chrome_pids_current" ||
    "$chrome_pids_current" != "$chrome_pids_before" ]]; then
    unset token
    if ! remove_known_output; then
      echo "Could not securely remove the aborted bootstrap artifacts." >&2
    fi
    echo "Normal Chrome changed before Playwright could attach." >&2
    echo "No extension connection was attempted. Reopen Chrome manually and retry." >&2
    return 5
  fi

  attachment_requires_recovery=1
  PLAYWRIGHT_MCP_EXTENSION_TOKEN="$token" \
    run_cli_bounded_to_file "$attach_log" "$attach_timeout_attempts" --json attach \
      --session="$session_name" \
      --extension=chrome \
      --config="$attach_config" || attach_status=$?
  unset token

  if (( attach_status != 0 )); then
    detach_failed_attachment || detach_status=$?
    if ! remove_known_output; then
      cleanup_status=1
      echo "Could not securely remove the failed bootstrap artifacts." >&2
      return 1
    fi
    if (( detach_status == 0 && cleanup_status == 0 )); then
      attachment_requires_recovery=0
    fi
    if (( attach_status == 124 )); then
      echo "Playwright attachment timed out after 60 seconds." >&2
      echo "Termination was issued to the exact CLI child and its direct descendants." >&2
      echo "Private bootstrap artifacts were removed." >&2
      echo "Complete the token-rotation procedure before reconnecting." >&2
    else
      echo "Playwright could not attach to the active Chrome profile." >&2
      echo "Bootstrap details were suppressed because they may contain the extension token." >&2
      if (( detach_status != 0 )); then
        echo "Complete the token-rotation procedure before reconnecting." >&2
      fi
    fi
    return "$attach_status"
  fi

  chrome_pids_after="$(normal_chrome_pids)"
  process_token_state="$(persistent_extension_token_state)"
  if [[ -z "$chrome_pids_after" ||
    "$chrome_pids_after" != "$chrome_pids_before" ||
    "$process_token_state" != "absent" ]]; then
    detach_failed_attachment || detach_status=$?
    if ! remove_known_output; then
      cleanup_status=1
      echo "Could not securely remove Playwright's aborted bootstrap output." >&2
    fi
    if (( detach_status == 0 && cleanup_status == 0 )); then
      attachment_requires_recovery=0
    fi
    echo "SECURITY: Chrome changed or retained the extension token during attachment." >&2
    if (( detach_status == 0 )); then
      echo "No page command was attempted after detachment." >&2
    else
      echo "No page command was attempted, but the session may remain connected." >&2
    fi
    echo "Fully quit Chrome and complete the token-rotation procedure before reconnecting." >&2
    return 6
  fi

  if ! scrub_known_output; then
    echo "Could not securely scrub Playwright's initial bootstrap output." >&2
    return 1
  fi

  if ! list_tabs_guarded "$tabs_output"; then
    echo "Playwright attached, but the active Chrome session did not become ready." >&2
    return 1
  fi
  tabs="$listed_tabs"

  finalize_sanitation "$tabs" "$tabs_output" || attach_status=$?
  if (( attach_status == 0 )); then
    attachment_requires_recovery=0
  fi
  return "$attach_status"
}

ensure_session() {
  local allow_attach="${2:-false}"
  local attach_status=0
  local quiet="${1:-false}"
  local result="reused"
  local state=""
  local tabs=""

  acquire_lock || return 1
  state="$(session_state)"

  case "$state" in
    ready)
      if ! tabs="$(list_tabs)"; then
        echo "The active Chrome session could not be probed after three attempts." >&2
        echo "No reconnect was attempted; run 'doctor' and retry." >&2
        release_lock
        return 1
      fi
      attach_status=0
      finalize_sanitation "$tabs" || attach_status=$?
      if (( attach_status != 0 )); then
        release_lock
        return "$attach_status"
      fi
      ;;
    missing)
      if [[ "$allow_attach" != "true" ]]; then
        echo "No Playwright Active Chrome session is currently owned by this skill." >&2
        echo "No attachment was attempted, so another extension client remains untouched." >&2
        echo "After explicit approval to take the exclusive Playwright Extension connection, run:" >&2
        echo "  $skill_dir/scripts/playwright-cli-active.sh connect" >&2
        release_lock
        return 4
      fi
      attach_status=0
      attach_session || attach_status=$?
      if (( attach_status != 0 )); then
        release_lock
        return "$attach_status"
      fi
      result="attached"
      ;;
    stale)
      if [[ "$allow_attach" != "true" ]]; then
        echo "The owned Playwright Active Chrome session is stale." >&2
        echo "No replacement was attempted, so another extension client remains untouched." >&2
        echo "After explicit approval to take the exclusive Playwright Extension connection, run:" >&2
        echo "  $skill_dir/scripts/playwright-cli-active.sh connect" >&2
        release_lock
        return 4
      fi
      attach_status=0
      attach_session || attach_status=$?
      if (( attach_status != 0 )); then
        release_lock
        return "$attach_status"
      fi
      result="replaced stale"
      ;;
    unavailable)
      echo "Playwright session state remained unavailable after three attempts." >&2
      echo "No reconnect was attempted; run 'doctor' and retry." >&2
      release_lock
      return 1
      ;;
    *)
      echo "Unexpected Playwright session state: $state" >&2
      release_lock
      return 1
      ;;
  esac

  release_lock
  if [[ "$quiet" != "true" ]]; then
    echo "Playwright Active Chrome is ready ($result session '$session_name')."
  fi
}

disconnect_session() {
  local after_pids=""
  local before_pids=""
  local display_pids=""
  local status=0

  before_pids="$(normal_chrome_pids)"
  run_cli_bounded 80 -s="$session_name" detach || status=$?
  if (( status == 0 )); then
    if ! remove_known_output; then
      echo "Detached, but could not remove the private session output." >&2
      return 1
    fi
    after_pids="$(normal_chrome_pids)"
    display_pids="$(printf '%s\n' "$after_pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ -n "$before_pids" && "$before_pids" == "$after_pids" ]]; then
      echo "Detached Playwright session '$session_name'; normal Chrome remains running (pid $display_pids)."
    elif [[ -n "$after_pids" ]]; then
      echo "Detached Playwright session '$session_name'; normal Chrome remains running (pid $display_pids)."
    else
      echo "Detached Playwright session '$session_name'; normal Chrome is no longer running." >&2
      return 1
    fi
  fi
  return "$status"
}

doctor() {
  local chrome_count=0
  local chrome_pid=""
  local chrome_pids=""
  local compatibility="unsupported"
  local process_token_state=""
  local rotation=""
  local state=""
  local token_state="missing"
  local version=""

  version="$(current_cli_version || true)"
  [[ -n "$version" ]] || version="unknown"
  if [[ "$version" == "$supported_cli_version" ]]; then
    compatibility="supported"
    state="$(session_state)"
  else
    state="not checked (unsupported CLI)"
  fi
  token_is_stored && token_state="stored"
  chrome_pids="$(normal_chrome_pids)"
  chrome_count="$(printf '%s\n' "$chrome_pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( chrome_count == 1 )); then
    chrome_pid="$chrome_pids"
  fi
  process_token_state="$(persistent_extension_token_state)"
  rotation="$(rotation_metadata_state)"

  echo "Playwright Active Chrome"
  echo "cli:       $cli_bin"
  echo "version:   $version"
  echo "compatibility: $compatibility (requires $supported_cli_version)"
  echo "token:     $token_state"
  echo "session:   $state"
  if (( chrome_count == 1 )); then
    echo "chrome:    running (normal user Chrome, pid $chrome_pid)"
  elif (( chrome_count > 1 )); then
    echo "chrome:    ambiguous (multiple normal Chrome main processes)"
  else
    echo "chrome:    missing (connect will refuse to launch it)"
  fi
  echo "process-token: $process_token_state"
  echo "rotation:  $rotation"
  echo "workspace: $runtime_dir"
}

cleanup_plan() {
  local payload=""

  if ! payload="$(run_cli_bounded 80 --json list --all 2>/dev/null)"; then
    echo "Could not inspect Playwright sessions safely." >&2
    return 1
  fi

  printf '%s' "$payload" |
    "$json_node" -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", chunk => input += chunk);
      process.stdin.on("end", () => {
        let payload;
        try {
          payload = JSON.parse(input);
        } catch {
          process.stderr.write("Could not parse Playwright session inventory.\n");
          process.exitCode = 1;
          return;
        }

        const browsers = (payload.browsers || []).filter(browser =>
          browser.status === "open"
        );
        process.stdout.write("Targeted Playwright cleanup plan\n");
        if (!browsers.length)
          process.stdout.write("active sessions: none\n");
        for (const browser of browsers) {
          const action = browser.attached === true ? "detach" : "close";
          process.stdout.write(
            "session: " + browser.name + "\n" +
            "workspace: " + browser.workspace + "\n" +
            "safe action: from the owning workspace, run playwright-cli -s=" +
              browser.name + " " + action + "\n"
          );
        }
        process.stdout.write("global close-all: blocked by this skill\n");
        process.stdout.write("global kill-all: blocked by this skill\n");
        process.stdout.write("non-CLI Chrome: close through its owning test or automation tool\n");
      });
    '
}

safety_audit() {
  local chrome_count=0
  local chrome_pid=""
  local chrome_pids=""
  local process_token_state=""

  chrome_pids="$(normal_chrome_pids)"
  chrome_count="$(printf '%s\n' "$chrome_pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( chrome_count == 1 )); then
    chrome_pid="$chrome_pids"
  fi
  process_token_state="$(persistent_extension_token_state)"

  echo "Playwright Active Chrome safeguards"
  if (( chrome_count == 1 )); then
    echo "1. running-Chrome preflight: PASS (normal Chrome pid $chrome_pid)"
  elif (( chrome_count > 1 )); then
    echo "1. running-Chrome preflight: BLOCKED (multiple normal Chrome main processes)"
  else
    echo "1. running-Chrome preflight: BLOCKED (normal Chrome missing)"
  fi
  echo "2. missing-Chrome behavior: ENFORCED (connect exits before token read or attach)"
  echo "3. browser launch commands: BLOCKED (open/show/install/attach are unavailable)"
  echo "4. disconnect behavior: DETACH ONLY (external Chrome is never closed)"
  echo "5. cleanup policy: TARGETED ONLY (close-all and kill-all are blocked)"
  if [[ "$process_token_state" == "absent" ]]; then
    echo "6. persistent process token: PASS (absent)"
  else
    echo "6. persistent process token: ACTION REQUIRED (restart Chrome and rotate token)"
  fi
  echo "7. attach process continuity: ENFORCED (complete Chrome PID set must remain unchanged)"
}

record_explicit_session() {
  local value="$1"

  [[ -n "$value" ]] || die "A session option was provided without a value."
  if [[ -n "$explicit_session" && "$explicit_session" != "$value" ]]; then
    die "Conflicting session options were provided."
  fi
  explicit_session="$value"
}

wrapper_command_has_extras() {
  local argument=""
  local command_seen=0

  for argument in "${forward_args[@]}"; do
    if (( command_seen == 0 )) && [[ "$argument" == "$command_name" ]]; then
      command_seen=1
      continue
    fi
    case "$argument" in
      --json|--raw)
        ;;
      *)
        return 0
        ;;
    esac
  done
  return 1
}

original_args=("$@")
forward_args=()
command_name=""
explicit_session=""
help_requested=0
options_ended=0
version_requested=0

argument_index=0
while (( argument_index < ${#original_args[@]} )); do
  argument="${original_args[$argument_index]}"
  if (( options_ended == 1 )); then
    forward_args+=("$argument")
    if [[ -z "$command_name" ]]; then
      command_name="$argument"
    fi
    argument_index=$((argument_index + 1))
    continue
  fi
  case "$argument" in
    --)
      options_ended=1
      forward_args+=("$argument")
      ;;
    -s|--session)
      argument_index=$((argument_index + 1))
      (( argument_index < ${#original_args[@]} )) ||
        die "A session option was provided without a value."
      record_explicit_session "${original_args[$argument_index]}"
      ;;
    -s=*|--session=*)
      record_explicit_session "${argument#*=}"
      ;;
    --help|-h)
      help_requested=1
      forward_args+=("$argument")
      ;;
    --version|-v)
      version_requested=1
      forward_args+=("$argument")
      ;;
    *)
      forward_args+=("$argument")
      if [[ -z "$command_name" && "$argument" != -* ]]; then
        command_name="$argument"
      fi
      ;;
  esac
  argument_index=$((argument_index + 1))
done

if [[ -n "$explicit_session" && "$explicit_session" != "$session_name" ]]; then
  die "This wrapper only controls session '$session_name', not '$explicit_session'."
fi

if (( help_requested == 1 || version_requested == 1 )); then
  run_cli "${forward_args[@]}"
  exit $?
fi

case "$command_name" in
  "")
    run_cli --help
    ;;
  doctor|status)
    wrapper_command_has_extras &&
      die "'$command_name' does not accept browser-command arguments."
    doctor
    ;;
  begin-token-rotation)
    wrapper_command_has_extras &&
      die "'begin-token-rotation' does not accept browser-command arguments."
    begin_token_rotation
    ;;
  mark-token-regenerated)
    wrapper_command_has_extras &&
      die "'mark-token-regenerated' does not accept browser-command arguments."
    mark_token_regenerated
    ;;
  rotation-status)
    wrapper_command_has_extras &&
      die "'rotation-status' does not accept browser-command arguments."
    token_rotation_status
    ;;
  safety-audit)
    wrapper_command_has_extras &&
      die "'safety-audit' does not accept browser-command arguments."
    safety_audit
    ;;
  cleanup-plan)
    wrapper_command_has_extras &&
      die "'cleanup-plan' does not accept browser-command arguments."
    require_supported_cli
    cleanup_plan
    ;;
  ensure)
    wrapper_command_has_extras &&
      die "'ensure' does not accept browser-command arguments."
    require_supported_cli
    ensure_session false false
    ;;
  connect)
    wrapper_command_has_extras &&
      die "'connect' does not accept browser-command arguments."
    require_supported_cli
    ensure_session false true
    ;;
  attach)
    die "'attach' is disabled. Use 'connect' only after explicit approval to take the exclusive extension connection."
    ;;
  disconnect|detach|close)
    wrapper_command_has_extras &&
      die "'$command_name' does not accept browser-command arguments."
    require_supported_cli
    disconnect_session
    ;;
  open)
    die "'open' would replace active Chrome. Use 'goto <url>' instead."
    ;;
  close-all|kill-all|delete-data|install|install-browser|show)
    die "'$command_name' is outside this active-Chrome wrapper's safe scope."
    ;;
  list)
    require_supported_cli
    run_cli "${forward_args[@]}"
    ;;
  *)
    require_supported_cli
    ensure_session true false
    run_cli_redacted -s="$session_name" "${forward_args[@]}"
    ;;
esac
