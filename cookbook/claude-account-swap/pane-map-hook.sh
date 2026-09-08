#!/bin/bash
# Keep the transcript path and the owning Claude process together in the pane map.
set -o pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 0
jq -c '{transcript_path, session_id}' |
    python3 "$script_dir/claude-account-swap.py" --record-hook
# A missing mapping disables swapping; a hook failure must not block a Claude turn.
exit 0
