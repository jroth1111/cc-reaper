#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# This hook inherits the Claude session's process group (PGID).
# Kill all processes in our group — catches ALL children including unknown
# third-party MCP servers, without needing pattern maintenance.
#
# WHITELIST: Long-running MCP servers shared across sessions are excluded.
MCP_WHITELIST="${CC_MCP_WHITELIST:-supabase|@stripe/mcp|context7|claude-mem|chroma-mcp}"
MCP_ORPHAN_PATTERN="npm exec @upstash|npm exec mcp-|npx.*mcp-server|node.*mcp-server|docker run .*mcp/|python.*mcp|uvx?.*mcp|worker-service\\.cjs|bun.*worker-service"

SESSION_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')

if [ -n "$SESSION_PGID" ] && [ "$SESSION_PGID" != "0" ] && [ "$SESSION_PGID" != "1" ]; then
 # Collect PIDs to kill (excluding this script, parent, and whitelisted)
 pids_to_kill=""
 while IFS= read -r pid; do
 [ -z "$pid" ] && continue
 pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
 if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
 continue
 fi
 pids_to_kill="$pids_to_kill $pid"
 done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$SESSION_PGID" -v me="$$" -v parent="$PPID" \
 '$2 == pgid && $1 != me && $1 != parent {print $1}')

 # Send SIGTERM first for graceful shutdown
 for pid in $pids_to_kill; do
 [ -n "$pid" ] && kill "$pid" 2>/dev/null
 done

 # Wait briefly then SIGKILL survivors
 sleep 2
 for pid in $pids_to_kill; do
 [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
 done
fi

# ─── Pattern-based fallback (PPID=1 only) ─────────────────────────────────────
# Only kill processes that are TRUE orphans (PPID=1) and match our patterns.
# This catches processes that escaped their process group via setsid().

# Collect orphan PIDs to kill
orphan_pids=""
while IFS= read -r pid; do
 [ -z "$pid" ] && continue
 pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
 echo "$pid_cmd" | grep -qE "$MCP_WHITELIST" && continue
 orphan_pids="$orphan_pids $pid"
done < <(ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|${MCP_ORPHAN_PATTERN}" | awk '{print $1}')

# Send SIGTERM
for pid in $orphan_pids; do
 [ -n "$pid" ] && kill "$pid" 2>/dev/null
done

# Wait then SIGKILL survivors
sleep 1
for pid in $orphan_pids; do
 [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
done

# ─── Caffeinate cleanup ───────────────────────────────────────────────────────
# Only kill orphaned caffeinate if spawned by Claude (check process tree)
# Claude's caffeinate will be in same session/tty as claude process

# Find claude sessions to get their TTY
claude_ttys=$(ps -eo tty,command | grep "[c]laude" | awk '{print $1}' | sort -u)

# Kill orphaned caffeinate only if it matches a claude TTY
for tty in $claude_ttys; do
 [ -z "$tty" ] || [ "$tty" = "??" ] && continue
 ps -eo pid,ppid,tty,command | awk -v tty="$tty" '$2 == 1 && $3 == tty' | grep "[c]affeinate" | awk '{print $1}' | while read pid; do
 [ -n "$pid" ] && kill "$pid" 2>/dev/null
 done
done

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
