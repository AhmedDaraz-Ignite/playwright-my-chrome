#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_SECURITY_LOG:?MOCK_SECURITY_LOG is required}"
token_file="${MOCK_KEYCHAIN_TOKEN_FILE:?MOCK_KEYCHAIN_TOKEN_FILE is required}"
command_name="${1:-}"

printf '%s\n' "$*" >>"$log_file"

case "$command_name" in
  find-generic-password)
    [[ -s "$token_file" ]] || exit 44
    if [[ " $* " == *" -w "* ]]; then
      /bin/cat "$token_file"
    fi
    ;;
  add-generic-password)
    IFS= read -r first_value
    IFS= read -r second_value
    [[ "$first_value" == "$second_value" ]] || exit 45
    printf '%s\n' "$first_value" >"$token_file"
    ;;
  delete-generic-password)
    : >"$token_file"
    ;;
  *)
    printf 'Unsupported mock security command: %s\n' "$command_name" >&2
    exit 46
    ;;
esac
