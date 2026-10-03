# Jujutsu Backend

Jujutsu (jj) is an experimental backend for firstmate that provides task worktrees
via [Jujutsu workspaces](https://github.com/martinvonz/jj/blob/main/docs/workspaces.md).

## Overview

Jujutsu is a Git-compatible version control system that introduces the concept of
workspaces - similar to Git worktrees but with key differences:

- **No branch dependency**: In Git, worktrees are tied to branches. In Jujutsu,
  workspaces are independent and each gets its own working-copy commit.
- **Multiple workstreams**: Multiple workspaces can coexist freely with no
  restrictions, making them ideal for parallel feature development.
- **Colocated with Git**: Jujutsu works on top of existing Git repos, so you can
  use both Git and Jujutsu commands in the same repository.

The jujutsu backend in firstmate leverages jj workspaces to provide isolated
worktrees for each task, while delegating terminal management to a session
backend (tmux, herdr, zellij, or cmux).

## Status

**EXPERIMENTAL** - The jujutsu backend is experimental and spawn-capable. It has
been added as a proof-of-concept to demonstrate how firstmate can integrate with
Jujutsu's workspace model.

## Requirements

- Jujutsu (`jj`) CLI installed and in PATH
- Git repository with Jujutsu initialized
- One of the supported session backends (tmux, herdr, zellij, cmux) for terminal
  management

## Setup

### Install Jujutsu

```bash
# Install jj from your package manager or from source
# See: https://github.com/martinvonz/jj#installation

# Verify installation
jj --version
```

### Initialize Jujutsu in your repository

```bash
cd /path/to/your/repo
jj init
```

This creates a `.jj` directory alongside your `.git` directory.

## Usage

### Select the jujutsu backend

You can select the jujutsu backend in several ways:

1. **Explicit per-task flag**:
   ```bash
   fm-spawn.sh <task-id> <project-dir> --backend jujutsu ...
   ```

2. **Environment variable**:
   ```bash
   export FM_BACKEND=jujutsu
   ```

3. **Configuration file**:
   ```bash
   echo "jujutsu" > config/backend
   ```

### Session Backend Selection

Since jujutsu doesn't manage terminals directly, you need to specify which session
backend to use for terminal management. By default, the jujutsu backend uses tmux.

You can override this by setting the `JUJUTSU_SESSION_BACKEND` environment variable:

```bash
# Use herdr for session management
export JUJUTSU_SESSION_BACKEND=herdr

# Or pass it as part of the spawn command
JUJUTSU_SESSION_BACKEND=zellij fm-spawn.sh <task-id> <project-dir> --backend jujutsu ...
```

Supported session backends: `tmux`, `herdr`, `zellij`, `cmux`

## Workspace Layout

When a task is spawned with the jujutsu backend:

1. A workspace directory is created at:
   `<project>/.fm-jujutsu-workspaces/<task-id>/`

2. A Jujutsu workspace is created with the name matching the task ID

3. The workspace is registered with Jujutsu via `jj workspace add`

4. A terminal session is created using the selected session backend

## Workspace Management

### Creating Workspaces

Workspaces are automatically created when tasks are spawned. The workspace name
matches the task ID, and the workspace path follows the pattern:
` <project>/.fm-jujutsu-workspaces/<task-id>/`

### Removing Workspaces

Workspaces are automatically removed when tasks are torn down via `fm-teardown.sh`.
The cleanup process:

1. Removes the workspace directory
2. Removes any Jujutsu-specific files (`.jj` directory)
3. Attempts to remove the workspace registration from Jujutsu (if supported)

### Listing Workspaces

You can list all jujutsu workspaces for a project:

```bash
# List workspaces in the .fm-jujutsu-workspaces directory
find <project>/.fm-jujutsu-workspaces -maxdepth 1 -type d

# Or use jj workspace list
cd <project>
jj workspace list
```

## Comparison with Other Backends

| Feature | jujutsu | orca | tmux/herdr/zellij/cmux |
|---------|---------|------|------------------------|
| Worktree management | Jujutsu workspaces | Orca worktrees | Treehouse |
| Terminal management | Delegated to session backend | Native | Native |
| Branch dependency | No - workspaces are independent | Yes | Yes (Git worktrees) |
| Git compatibility | Colocated with Git | Native | Native |

## Limitations

1. **Terminal Management**: Jujutsu doesn't manage terminals natively, so the
   backend delegates to a session backend. This means you need both jj and a
   session backend (tmux, herdr, etc.) installed.

2. **Workspace Cleanup**: While the backend attempts to clean up workspaces on
   teardown, some Jujutsu internal state may persist. This is a limitation of
   Jujutsu's current workspace implementation.

3. **Secondmate Spawns**: The jujutsu backend does not support secondmate spawns
   (persistent remote agents). This is consistent with the orca backend.

4. **Version Requirements**: The backend requires a version of Jujutsu that
   supports workspaces (0.14.0+). Older versions may not work correctly.

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FM_BACKEND` | Select the jujutsu backend | `tmux` |
| `JUJUTSU_SESSION_BACKEND` | Session backend for terminal management | `tmux` |

### Configuration File

Create `config/backend` with the content:
```
jujutsu
```

## Verification

The jujutsu backend has been designed to follow the same patterns as the existing
backends (particularly orca, which also owns its worktrees). The key verification
points are:

1. **Workspace Creation**: Workspaces are created successfully with `jj workspace add`
2. **Workspace Path Resolution**: Workspace paths can be resolved from names
3. **Workspace Cleanup**: Workspaces are cleaned up on teardown
4. **Terminal Delegation**: Terminal management is properly delegated to the session backend

## Troubleshooting

### "jj command not found"

Ensure Jujutsu is installed and in your PATH:
```bash
which jj
jj --version
```

### "jj workspace add failed"

Check that:
1. The project directory is a valid Git repository
2. Jujutsu is initialized in the repository (`jj init`)
3. You have write permissions in the project directory

### Workspace directory not created

Verify that the `.fm-jujutsu-workspaces` directory exists and is writable:
```bash
mkdir -p <project>/.fm-jujutsu-workspaces
chmod 755 <project>/.fm-jujutsu-workspaces
```

## Future Work

1. **Native Terminal Support**: If Jujutsu adds native terminal management,
   the backend could be updated to use it directly.

2. **Workspace Pooling**: Implement a workspace pooling mechanism similar to
   Treehouse's pool for better resource management.

3. **Durable Workspace Leases**: Add support for durable workspace leases to
   prevent workspace reassignment issues.

4. **Performance Optimization**: Optimize workspace creation and cleanup for
   better performance with many parallel tasks.

## See Also

- [Jujutsu Documentation](https://github.com/martinvonz/jj)
- [Jujutsu Workspaces](https://github.com/martinvonz/jj/blob/main/docs/workspaces.md)
- [Backend Design Document](data/fm-backend-design-d7/report.md)
- [Orca Backend](docs/orca-backend.md) - Similar backend that also owns worktrees
- [Configuration](docs/configuration.md) - Backend selection and configuration
