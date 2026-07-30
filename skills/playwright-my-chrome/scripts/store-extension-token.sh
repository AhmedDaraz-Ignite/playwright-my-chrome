#!/usr/bin/env bash
set -euo pipefail
umask 077

keychain_service="${PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE:-playwright-my-chrome.extension-token}"
keychain_account="${PLAYWRIGHT_MY_CHROME_KEYCHAIN_ACCOUNT:-$(/usr/bin/id -un)}"
test_mode="${PLAYWRIGHT_MY_CHROME_TEST_MODE:-0}"
security_bin="/usr/bin/security"
pbpaste_bin="/usr/bin/pbpaste"
pbcopy_bin="/usr/bin/pbcopy"
source_mode="clipboard"
source_service=""
source_account="${PLAYWRIGHT_MY_CHROME_MIGRATION_ACCOUNT:-$keychain_account}"
clipboard_value=""
token_value=""

if [[ "$test_mode" == "1" ]]; then
  security_bin="${PLAYWRIGHT_MY_CHROME_TEST_SECURITY_BIN:-$security_bin}"
  pbpaste_bin="${PLAYWRIGHT_MY_CHROME_TEST_PBPASTE_BIN:-$pbpaste_bin}"
  pbcopy_bin="${PLAYWRIGHT_MY_CHROME_TEST_PBCOPY_BIN:-$pbcopy_bin}"
elif [[ "$test_mode" != "0" ]]; then
  echo "ERROR: PLAYWRIGHT_MY_CHROME_TEST_MODE must be 0 or 1." >&2
  exit 2
fi

usage() {
  cat <<'EOF'
Usage:
  store-extension-token.sh
  store-extension-token.sh --migrate-from-service SERVICE

With no arguments, read the copied Playwright Extension token from the macOS
clipboard, store it in Keychain, and clear the clipboard. Migration copies an
existing Keychain token into this skill's configured service without printing
the token or deleting the source entry.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ -n "$keychain_service" ]] || die "The target Keychain service cannot be empty."
[[ -n "$keychain_account" ]] || die "The target Keychain account cannot be empty."

case "${1:-}" in
  "")
    (( $# == 0 )) || die "Unexpected arguments."
    ;;
  --migrate-from-service)
    (( $# == 2 )) || die "--migrate-from-service requires exactly one service name."
    source_mode="keychain"
    source_service="$2"
    [[ -n "$source_service" ]] || die "The source Keychain service cannot be empty."
    [[ -n "$source_account" ]] || die "The source Keychain account cannot be empty."
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "Unknown option: $1"
    ;;
esac

[[ "$security_bin" == /* && -x "$security_bin" ]] ||
  die "macOS Keychain command 'security' is unavailable."

if [[ "$source_mode" == "clipboard" ]]; then
  [[ "$pbpaste_bin" == /* && -x "$pbpaste_bin" ]] ||
    die "macOS clipboard command 'pbpaste' is unavailable."
  [[ "$pbcopy_bin" == /* && -x "$pbcopy_bin" ]] ||
    die "macOS clipboard command 'pbcopy' is unavailable."
  clipboard_value="$("$pbpaste_bin")"
  token_value="$clipboard_value"
else
  if ! token_value="$(
    "$security_bin" find-generic-password \
      -a "$source_account" \
      -s "$source_service" \
      -w 2>/dev/null
  )"; then
    die "No readable Playwright Extension token exists in the source Keychain service."
  fi
fi

case "$token_value" in
  PLAYWRIGHT_MCP_EXTENSION_TOKEN=*)
    token_value="${token_value#PLAYWRIGHT_MCP_EXTENSION_TOKEN=}"
    ;;
esac

token_value="${token_value//[[:space:]]/}"

if [[ ! "$token_value" =~ ^[A-Za-z0-9_-]{32,128}$ ]]; then
  if [[ "$source_mode" == "clipboard" ]]; then
    die "Clipboard does not contain a valid Playwright Extension token."
  fi
  die "Source Keychain item does not contain a valid Playwright Extension token."
fi

if ! printf '%s\n%s\n' "$token_value" "$token_value" |
  "$security_bin" add-generic-password \
    -U \
    -a "$keychain_account" \
    -s "$keychain_service" \
    -l "Playwright My Chrome Extension Token" \
    -w >/dev/null 2>&1; then
  die "Could not store the Playwright Extension token in macOS Keychain."
fi

if [[ "$source_mode" == "clipboard" ]]; then
  printf '' | "$pbcopy_bin"
fi
unset clipboard_value token_value

if [[ "$source_mode" == "clipboard" ]]; then
  echo "Playwright Extension token stored in macOS Keychain; clipboard cleared."
else
  echo "Playwright Extension token copied to the configured Keychain service."
fi
