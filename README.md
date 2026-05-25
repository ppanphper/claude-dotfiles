# claude-dotfiles

Custom [Claude Code](https://claude.com/claude-code) configuration. Currently
ships a status line that surfaces the things the built-in UI doesn't: absolute
token counts, subscription quota usage, git branch & worktree, and which
subdirectory of a project the session is operating in.

## Status line

A single status row at the bottom of Claude Code that shows:

```
Claude Opus 4.7 [high] 💭 | 🤖 code-reviewer | myproject/src | 🌿 main ⎇ feature-x | ctx: 15.5k/200k (8%) | free: 5h 59% / 7d 91%
```

Each column is color-coded in your terminal. Columns with no data are
auto-hidden (e.g. no `🤖 agent` outside of `--agent` sessions, no `🌿 branch`
in non-git directories).

A minimal session, just after launching in a non-git directory:

```
Claude Sonnet 4.6 | myproject | ctx: n/a | free: n/a
```

> Screenshot of an actual session (drop a PNG into the repo and reference it
> here): _todo._

### What each column shows

| Column                       | Source                                                                                                    | Notes                                                                                                                              |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `Model [effort] 💭`          | `.model.display_name`, `.effort.level`, `.thinking.enabled`                                               | `[effort]` hidden if the model doesn't support reasoning effort. 💭 only when extended thinking is on.                             |
| `🤖 agent`                   | `.agent.name`                                                                                             | Only when running with `--agent` or inside a subagent.                                                                             |
| `project[/subdir]`           | `.workspace.project_dir` + `.workspace.current_dir`                                                       | If you `cd` into a subdirectory of the project, shows `project/relative/path`.                                                     |
| `🌿 branch [⎇ worktree]`     | `git branch --show-current` + `.workspace.git_worktree`                                                   | Hidden in non-git directories. The `⎇ worktree` suffix appears only when the current directory is inside a linked git worktree.   |
| `ctx: in/total (X%)`         | `.context_window.total_input_tokens` / `.context_window_size` / `.context_window.used_percentage`         | Shows absolute token counts plus percent. Falls back to `ctx: n/a` before the first API response.                                  |
| `free: 5h X% / 7d Y%`        | `100 − .rate_limits.five_hour.used_percentage` / `100 − .rate_limits.seven_day.used_percentage`           | Remaining percentage of Claude.ai's 5-hour and 7-day rate-limit windows. Only available for Pro/Max subscribers after the first response. `n/a` for API-key users. |

### Worktree auto-tracking

A `PostToolUse` hook on the `Bash` tool watches for successful `git worktree
add <path>` invocations and writes the new worktree's absolute path to
`~/.claude/.last_worktree_<session_id>`. The status line then displays that
directory and its branch instead of the original session CWD — useful when
you ask Claude to create a new worktree and continue working there, since
Claude Code's session CWD doesn't follow subprocess `cd`s.

Known limits (by design, to keep the hook robust):

- Only `git worktree add` is matched — not arbitrary `cd`, `git clone`, or
  scaffolders like `cargo new`.
- Paths containing shell variables (`$VAR`) or command substitution
  (`` `…` ``, `$(…)`) are skipped.
- Subshells like `(git worktree add ...)` are not detected.
- If you ask Claude to create a worktree but keep working in the original
  directory, the status line will point at the new worktree until you
  reset. To reset the current session's tracker:

  ```bash
  rm ~/.claude/.last_worktree_*
  ```

State is per-session (keyed by `session_id`), so concurrent Claude sessions
don't interfere with each other.

## Install

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash
```

The installer:

1. Verifies `git` and `jq` are present. If `jq` is missing it auto-detects
   your package manager and installs it (`brew`, `apt`, `dnf`, `yum`,
   `pacman`, `zypper`, `apk`; macOS falls back to MacPorts if Homebrew isn't
   installed).
2. Clones this repo to `~/claude-dotfiles` (or `$CLAUDE_DOTFILES_DIR` if set).
3. Symlinks `~/.claude/statusline.sh` → the repo's `statusline.sh`. Any
   pre-existing file at that path is backed up to
   `~/.claude/statusline.sh.bak.<timestamp>`.
4. Symlinks `~/.claude/hooks/worktree-tracker.sh` → the repo's hook (same
   backup behavior).
5. Merges `statusLine` and a `PostToolUse` → `Bash` → `worktree-tracker.sh`
   entry into `~/.claude/settings.json`, preserving every other field and
   any other Bash hooks you've configured. The original file is backed up
   to `settings.json.bak.<timestamp>` before any change is written, and the
   new file is written atomically via `mktemp` + `mv`. Re-running the
   installer is idempotent — no duplicate entries are added.

Restart Claude Code to see the status line.

### Options

```bash
# Install the repo somewhere other than ~/claude-dotfiles
CLAUDE_DOTFILES_DIR=~/dev/claude-dotfiles \
  curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash

# Skip the jq auto-install (you'll install it manually)
SKIP_JQ_INSTALL=1 \
  curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash
```

### Manual install

If you'd rather not run a piped shell script:

```bash
git clone https://github.com/ppanphper/claude-dotfiles.git ~/claude-dotfiles
chmod +x ~/claude-dotfiles/statusline.sh ~/claude-dotfiles/hooks/worktree-tracker.sh
ln -s ~/claude-dotfiles/statusline.sh ~/.claude/statusline.sh
mkdir -p ~/.claude/hooks
ln -s ~/claude-dotfiles/hooks/worktree-tracker.sh ~/.claude/hooks/worktree-tracker.sh
```

Then add to `~/.claude/settings.json` (merge with whatever's already there):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/worktree-tracker.sh" }
        ]
      }
    ]
  }
}
```

## Update

```bash
cd ~/claude-dotfiles && git pull
```

Because the installed file is a symlink, the new version takes effect on the
next status-line refresh — no further action needed.

## Uninstall

```bash
rm ~/.claude/statusline.sh ~/.claude/hooks/worktree-tracker.sh
rm -f ~/.claude/.last_worktree_*
# Then either remove the "statusLine" + matching "hooks" entries from
# ~/.claude/settings.json, or restore from the settings.json.bak.<timestamp>
# the installer created.
rm -rf ~/claude-dotfiles
```

## Requirements

- `bash`
- `git`
- `jq` — used both by `install.sh` to merge `settings.json` safely and by
  `statusline.sh` itself to parse the JSON Claude Code pipes to it on every
  refresh. Auto-installed by `install.sh` unless `SKIP_JQ_INSTALL=1`.

Tested on macOS and Linux. Windows is not currently supported.
