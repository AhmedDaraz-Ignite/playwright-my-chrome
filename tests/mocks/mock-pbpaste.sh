#!/usr/bin/env bash
set -euo pipefail

/bin/cat "${MOCK_CLIPBOARD_FILE:?MOCK_CLIPBOARD_FILE is required}"
