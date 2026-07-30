#!/usr/bin/env bash
set -euo pipefail

output_file="${MOCK_PS_OUTPUT_FILE:?MOCK_PS_OUTPUT_FILE is required}"

if [[ " $* " == *" pid=,command= "* ]]; then
  /bin/cat "$output_file"
else
  /usr/bin/sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' "$output_file"
fi
