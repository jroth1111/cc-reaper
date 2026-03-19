#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_HELPERS="$SCRIPT_DIR/../shell/claude-cleanup-runtime.bash"
[ -f "$RUNTIME_HELPERS" ] || RUNTIME_HELPERS="$HOME/.cc-reaper/claude-cleanup-runtime.bash"
# shellcheck disable=SC1090
source "$RUNTIME_HELPERS"

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# This hook inherits the Claude session's process group (PGID).
# Only Claude-managed descendants are reaped so normal user-launched background
# work is not killed just because it shares ancestry with the session.

SESSION_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
ccr_record_session_snapshot "$SESSION_PGID" 2>/dev/null || true

if [ -n "$SESSION_PGID" ] && [ "$SESSION_PGID" != "0" ] && [ "$SESSION_PGID" != "1" ]; then
 _claude_pgid_kill "$SESSION_PGID"
fi

# ─── Ledger-based fallback (PPID=1 only) ──────────────────────────────────────
# Only kill processes that are TRUE orphans (PPID=1) and were previously
# recorded as descendants of a real Claude session.

ccr_prune_snapshots
orphan_pids=""
while IFS=$'\t' read -r pid _pgid pid_cmd; do
 [ -z "$pid" ] && continue
 _claude_is_managed_cmd "$pid_cmd" || continue
 orphan_pids="$orphan_pids $pid"
done < <(ccr_known_orphan_pids)

# Send SIGTERM
for pid in $orphan_pids; do
 [ -n "$pid" ] && kill "$pid" 2>/dev/null
done

# Wait then SIGKILL survivors
sleep 1
for pid in $orphan_pids; do
 [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
done

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
