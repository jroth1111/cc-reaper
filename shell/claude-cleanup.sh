# cc-reaper shell wrapper
# Source this file from ~/.zshrc or ~/.bashrc. The implementation runs under bash.

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _CLAUDE_WRAPPER_SOURCE="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _CLAUDE_WRAPPER_SOURCE="${(%):-%x}"
else
  _CLAUDE_WRAPPER_SOURCE="$0"
fi

_claude_runtime_path() {
  local dir
  dir=$(cd "$(dirname "$_CLAUDE_WRAPPER_SOURCE")" 2>/dev/null && pwd)
  echo "$dir/claude-cleanup-runtime.bash"
}

_claude_exec() {
  local fn=$1
  shift

  local runtime
  runtime=$(_claude_runtime_path)
  if [ ! -f "$runtime" ]; then
    echo "cc-reaper: runtime helper not found at $runtime" >&2
    return 1
  fi

  bash -c 'runtime=$1; fn=$2; shift 2; source "$runtime"; "$fn" "$@"' bash "$runtime" "$fn" "$@"
}

_claude_real_binary() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    whence -p claude 2>/dev/null
  else
    type -P claude 2>/dev/null
  fi
}

_claude_node_options() {
  local current node_cap
  current=${NODE_OPTIONS:-}

  if [ "${CC_REAPER_AUTO_NODE_OPTIONS:-1}" = "0" ]; then
    echo "$current"
    return
  fi

  if echo "$current" | grep -q -- '--max-old-space-size'; then
    echo "$current"
    return
  fi

  node_cap=${CC_NODE_MAX_OLD_SPACE_MB:-8192}
  if ! echo "$node_cap" | grep -qE '^[0-9]+$'; then
    echo "$current"
    return
  fi

  if [ -n "$current" ]; then
    echo "$current --max-old-space-size=$node_cap"
  else
    echo "--max-old-space-size=$node_cap"
  fi
}

claude-cleanup() { _claude_exec claude-cleanup "$@"; }
claude-ram() { _claude_exec claude-ram "$@"; }
claude-sessions() { _claude_exec claude-sessions "$@"; }
claude-guard() { _claude_exec claude-guard "$@"; }
claude-disk() { _claude_exec claude-disk "$@"; }
claude-clean-disk() { _claude_exec claude-clean-disk "$@"; }
claude-health() { _claude_exec claude-health "$@"; }
claude-check-growthbook() { _claude_exec claude-check-growthbook "$@"; }
claude-check-zombies() { _claude_exec claude-check-zombies "$@"; }

claude() {
  local claude_bin node_options
  claude_bin=$(_claude_real_binary)

  if [ -z "$claude_bin" ]; then
    echo "cc-reaper: unable to locate the Claude binary on PATH" >&2
    return 127
  fi

  node_options=$(_claude_node_options)
  NODE_OPTIONS="$node_options" command "$claude_bin" "$@"
}
