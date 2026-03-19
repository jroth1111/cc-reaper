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

claude-cleanup() { _claude_exec claude-cleanup "$@"; }
claude-ram() { _claude_exec claude-ram "$@"; }
claude-sessions() { _claude_exec claude-sessions "$@"; }
claude-guard() { _claude_exec claude-guard "$@"; }
claude-disk() { _claude_exec claude-disk "$@"; }
claude-clean-disk() { _claude_exec claude-clean-disk "$@"; }
