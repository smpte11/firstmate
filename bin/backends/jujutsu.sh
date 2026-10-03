#!/usr/bin/env bash
# bin/backends/jujutsu.sh - the Jujutsu (jj) workspace backend adapter.
#
# Jujutsu owns both the task worktree (via workspaces) and the terminal
# endpoint. This adapter provides the backend interface for managing
# jujutsu workspaces as firstmate worktrees.
#
# Unlike Git worktrees which are tied to branches, jj workspaces are
# independent and each gets its own working-copy commit. Multiple workspaces
# can coexist freely with no restrictions.
#
# Jujutsu is colocated with Git - it works on top of existing Git repos.
# See: https://github.com/martinvonz/jj
#
# Target string shape: the Jujutsu workspace name that can be resolved to a
# worktree path via `jj workspace list`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

# Jujutsu workspace state tracking
# Workspace names are simple identifiers; paths are where they live on disk
FM_JUJUTSU_WORKSPACE_NAME=""
FM_JUJUTSU_WORKSPACE_PATH=""

fm_backend_jujutsu_tool_check() {
  command -v jj >/dev/null 2>&1 || { echo "error: backend=jujutsu selected but the 'jj' CLI is not installed" >&2; return 1; }
  # Verify jj is at least a minimal version that supports workspaces
  local version
  version=$(jj --version 2>/dev/null | head -1 || true)
  [ -n "$version" ] || { echo "error: backend=jujutsu selected but 'jj --version' failed" >&2; return 1; }
  # Workspaces were added in jj 0.14.0; we don't enforce a minimum but warn on old versions
  if ! echo "$version" | grep -qP '[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "warning: could not parse jj version from '$version'; assuming workspaces are supported" >&2
  fi
}

fm_backend_jujutsu_runtime_check() {
  fm_backend_jujutsu_tool_check || return 1
  # Verify we can communicate with jj in the current repo context
  local out
  out=$(jj status 2>/dev/null) || {
    echo "error: backend=jujutsu selected but 'jj status' failed; ensure jj is properly initialized in the repo" >&2
    return 1
  }
  return 0
}

# fm_backend_jujutsu_workspace_create: create a new jujutsu workspace for a task
# Returns: workspace_name\tworkspace_path\tterminal_handle (if applicable)
# For jujutsu, the terminal is managed separately (like orca), but we return
# the workspace info. The terminal handle is empty as jj doesn't manage terminals.
fm_backend_jujutsu_workspace_create() {  # <project-path> <name>
  local project=$1 name=$2 out wt_path wt_name
  fm_backend_jujutsu_tool_check || return 1
  
  # Ensure the project is a valid git repo with jj initialized
  if [ ! -d "$project/.git" ] && [ ! -d "$project/.jj" ]; then
    echo "error: jujutsu backend requires a git repo at $project" >&2
    return 1
  fi
  
  # Create the workspace directory if it doesn't exist
  # Jujutsu workspace add creates a new working copy at the specified path
  # Format: jj workspace add <name> <path>
  # The path should be a directory that doesn't exist yet
  local workspace_dir="$project/.fm-jujutsu-workspaces/$name"
  
  # Create the parent directory for workspaces
  mkdir -p "$project/.fm-jujutsu-workspaces" || return 1
  
  # Check if workspace already exists
  if [ -d "$workspace_dir" ]; then
    # Workspace already exists, return its info
    wt_path="$workspace_dir"
    wt_name="$name"
  else
    # Create new workspace using jj workspace add
    out=$(jj workspace add "$name" "$workspace_dir" 2>&1) || {
      echo "error: jj workspace add failed for $name at $workspace_dir: $out" >&2
      return 1
    }
    
    # Verify the workspace was created
    if [ ! -d "$workspace_dir" ]; then
      echo "error: jj workspace add did not create directory $workspace_dir" >&2
      return 1
    fi
    
    wt_path="$workspace_dir"
    wt_name="$name"
  fi
  
  # Jujutsu doesn't manage terminals, so terminal handle is empty
  # The terminal will be managed by the session backend (tmux/herdr/etc)
  printf '%s\t%s' "$wt_name" "$wt_path"
}

# fm_backend_jujutsu_workspace_remove: remove a jujutsu workspace
# Note: This removes the workspace directory, not just the jj workspace registration
# as jj doesn't have a separate "remove workspace" command that cleans up the files
fm_backend_jujutsu_workspace_remove() {  # <workspace-name> <project-path>
  local workspace_name=$1 project=$2 workspace_dir
  
  [ -n "$workspace_name" ] || { echo "error: missing jujutsu workspace name; cannot remove workspace" >&2; return 1; }
  [ -n "$project" ] || { echo "error: missing project path; cannot remove workspace" >&2; return 1; }
  
  workspace_dir="$project/.fm-jujutsu-workspaces/$workspace_name"
  
  # First, try to remove via jj if possible
  # Note: jj doesn't have a direct workspace remove command in all versions
  # We'll just remove the directory
  
  if [ -d "$workspace_dir" ]; then
    # Clean up any jj-specific files
    # Remove .jj directory if it exists in the workspace
    if [ -d "$workspace_dir/.jj" ]; then
      rm -rf "$workspace_dir/.jj" || {
        echo "warning: could not remove .jj directory from $workspace_dir" >&2
      }
    fi
    
    # Remove the workspace directory
    rm -rf "$workspace_dir" || {
      echo "error: could not remove jujutsu workspace directory $workspace_dir" >&2
      return 1
    }
  fi
  
  # Also try to remove from jj's workspace tracking if the command exists
  if command -v jj >/dev/null 2>&1; then
    # jj workspace remove is available in newer versions
    jj workspace remove "$workspace_name" "$workspace_dir" 2>/dev/null || true
  fi
  
  return 0
}

# fm_backend_jujutsu_workspace_path: resolve workspace path from name
fm_backend_jujutsu_workspace_path() {  # <workspace-name> <project-path>
  local workspace_name=$1 project=$2 workspace_dir
  
  [ -n "$workspace_name" ] || { echo "error: missing jujutsu workspace name" >&2; return 1; }
  [ -n "$project" ] || { echo "error: missing project path" >&2; return 1; }
  
  workspace_dir="$project/.fm-jujutsu-workspaces/$workspace_name"
  
  if [ -d "$workspace_dir" ]; then
    printf '%s' "$workspace_dir"
    return 0
  fi
  
  # Try to find it via jj workspace list
  local out line
  out=$(jj workspace list 2>/dev/null) || return 1
  
  while IFS= read -r line; do
    # jj workspace list output format varies; try to match by name
    if echo "$line" | grep -q "$workspace_name"; then
      # Extract the path from the line
      # Format is typically: <name> <path> or <name> at <path>
      local path
      path=$(echo "$line" | sed -n 's/.* \([^ ]*\/.*\)/\1/p' | head -1)
      if [ -n "$path" ] && [ -d "$path" ]; then
        printf '%s' "$path"
        return 0
      fi
    fi
  done <<< "$out"
  
  echo "error: could not resolve path for jujutsu workspace '$workspace_name'" >&2
  return 1
}

# fm_backend_jujutsu_workspace_list: list all workspaces for a project
fm_backend_jujutsu_workspace_list() {  # <project-path>
  local project=$1
  
  [ -n "$project" ] || { echo "error: missing project path" >&2; return 1; }
  
  # List workspaces in the .fm-jujutsu-workspaces directory
  if [ -d "$project/.fm-jujutsu-workspaces" ]; then
    find "$project/.fm-jujutsu-workspaces" -maxdepth 1 -type d ! -name '.fm-jujutsu-workspaces' -printf '%f\n' 2>/dev/null || true
  fi
  
  # Also try jj workspace list
  if command -v jj >/dev/null 2>&1; then
    jj workspace list 2>/dev/null | awk '{print $1}' || true
  fi
}

# fm_backend_jujutsu_capture: capture terminal output from a jujutsu-managed terminal
# Since jujutsu doesn't manage terminals, this delegates to the session backend
# For now, this is a no-op that returns empty; the actual capture happens
# via the session backend (tmux/herdr/zellij/cmux)
fm_backend_jujutsu_capture() {  # <terminal-id> <lines>
  local terminal=${1:-} lines=${2:-40}
  # Jujutsu doesn't manage terminals directly
  # This would be handled by the session backend
  printf ''
}

# fm_backend_jujutsu_send_text_line: send text to a jujutsu terminal
# Delegates to the session backend
fm_backend_jujutsu_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  # Jujutsu doesn't manage terminals directly
  # This would be handled by the session backend
  echo "error: jujutsu backend does not manage terminals; use session backend" >&2
  return 1
}

# fm_backend_jujutsu_send_literal: send literal text to a jujutsu terminal
fm_backend_jujutsu_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  echo "error: jujutsu backend does not manage terminals; use session backend" >&2
  return 1
}

# fm_backend_jujutsu_composer_capture: capture composer screen
# Since jujutsu doesn't manage terminals, this delegates to the session backend
fm_backend_jujutsu_composer_capture() {  # <terminal-id> [expected-label]
  # This would be handled by the session backend
  printf ''
}

# fm_backend_jujutsu_composer_caps: composer capabilities
fm_backend_jujutsu_composer_caps() {
  # Default capabilities; actual capabilities depend on the session backend
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_jujutsu_composer_state: composer state classification
fm_backend_jujutsu_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_jujutsu_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_jujutsu_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_jujutsu_send_key: send a key to a jujutsu terminal
fm_backend_jujutsu_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  echo "error: jujutsu backend does not manage terminals; use session backend" >&2
  return 1
}

# fm_backend_jujutsu_send_text_submit: submit text with retry
fm_backend_jujutsu_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  echo "error: jujutsu backend does not manage terminals; use session backend" >&2
  return 1
}

# fm_backend_jujutsu_kill: close a jujutsu terminal
# Since jujutsu doesn't manage terminals, this is a no-op
# The actual terminal cleanup is handled by the session backend
fm_backend_jujutsu_kill() {  # <terminal-id>
  # Jujutsu doesn't manage terminals
  # Terminal cleanup is handled by the session backend
  return 0
}

# fm_backend_jujutsu_agent_state: check if an agent is alive in a jujutsu workspace
# This checks the workspace directory for signs of agent activity
fm_backend_jujutsu_agent_state() {  # <worktree-path>
  local worktree=$1
  
  [ -d "$worktree" ] || { echo "missing"; return 0; }
  
  # Check for common agent markers
  # This is a placeholder; actual agent detection depends on the harness
  if [ -f "$worktree/.fm-agent-pid" ]; then
    local pid
    pid=$(cat "$worktree/.fm-agent-pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "alive"
      return 0
    fi
  fi
  
  # Check for recent activity
  if [ -f "$worktree/.fm-agent-heartbeat" ]; then
    local now mtime diff
    now=$(date +%s)
    mtime=$(stat -c %Y "$worktree/.fm-agent-heartbeat" 2>/dev/null || true)
    if [ -n "$mtime" ]; then
      diff=$((now - mtime))
      # Consider alive if heartbeat is within 30 seconds
      if [ "$diff" -lt 30 ]; then
        echo "alive"
        return 0
      fi
    fi
  fi
  
  echo "dead"
}

# fm_backend_jujutsu_remove_worktree: remove a jujutsu worktree/workspace
# This is an alias for workspace_remove for consistency with other backends
fm_backend_jujutsu_remove_worktree() {  # <workspace-name> <project-path>
  fm_backend_jujutsu_workspace_remove "$1" "$2"
}

# fm_backend_jujutsu_worktree_path: alias for workspace_path
fm_backend_jujutsu_worktree_path() {
  fm_backend_jujutsu_workspace_path "$1" "$2"
}
