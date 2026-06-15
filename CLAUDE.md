# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Custom Claude Code configuration distributed as a dotfiles repo. Three shell
files do all the work; there is no build system, package manager, or test
suite. End users install via `install.sh`, which symlinks the scripts into
`~/.claude/` and merges entries into `~/.claude/settings.json`.

- `statusline.sh` — the status-line renderer Claude Code invokes on every refresh.
- `hooks/worktree-tracker.sh` — a `PostToolUse`/`Bash` hook that tracks `git worktree add`.
- `hooks/notify.sh` — a `Stop` + `Notification` + `UserPromptSubmit` hook that
  alerts you when Claude finishes or needs input, across six channels (iTerm2 tab
  color, tab-title glyph, bell, desktop notification, sound, Telegram push).
  Configured by `~/.claude/notify.conf` (seeded from `notify.conf.example`).
- `install.sh` — idempotent installer (clone → symlink → merge settings → check deps).

## How the pieces talk to each other

Claude Code pipes a JSON blob to `statusline.sh` on stdin every refresh; the
script reads it with `jq`, builds colored columns, and prints 1–N rows. There
is no persistent process — everything is recomputed per render, so keep the
script fast.

The status line and the hook are coupled through a **per-session file**,
`~/.claude/.last_worktree_<session_id>`:

1. The hook fires after every `Bash` tool call. If the command contained a
   successful `git worktree add <path>`, it writes the new worktree's absolute
   path to that file (keyed by `session_id` from the hook's input JSON).
2. On the next render, `statusline.sh` reads the same file (using the
   `session_id` from *its* input JSON) and overrides `current_dir` with the
   saved path — because Claude Code's session CWD does not follow subprocess
   `cd`s into a freshly created worktree.

When changing the file path/format, both scripts must stay in sync.

`notify.sh` is wired to three events: `Stop` → **done** (🟢), `Notification` →
**wait** (🟡), `UserPromptSubmit` → **reset** (clears the iTerm2 tab color).
Channels are toggled *per state* via `notify.conf`. Notable details:

- **A Claude Code hook has no controlling terminal**, so `/dev/tty` can't be
  opened (confirmed: every event logged `tty_ok=0`). The terminal-escape channels
  (tab color, title, bell) therefore **climb the process tree** (`find_tty`,
  via `ps -o tty=/ppid=`) to the `claude` process, which still owns the pty
  (e.g. `/dev/ttys003`), and write the escape codes to that device. Do not
  "fix" this back to `/dev/tty`.
- **iTerm2 tab color (OSC 6)** is the reliable visual indicator: Claude Code only
  overwrites the *title* (OSC 0), never the tab color. The title glyph needs
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` to survive. The `reset` event clears the
  color so a colored tab means "unread output".
- The summary comes from `.last_assistant_message` (Stop). `Notification`'s
  payload lacks it, so the hook falls back to the **last assistant text in the
  transcript** (`tail -n 100 transcript_path | jq` over `.message.content[] |
  select(.type=="text")`), then to `.message`.
- **Focus-aware mute** (macOS) gates only the *local loud* channels
  (bell/desktop/sound) — never the silent title glyph or the remote Telegram
  push (you may be away with the terminal still frontmost). It uses one
  `osascript` frontmost-app query that **fails open** (Accessibility denied →
  empty → not muted).
- **Telegram** runs in a backgrounded subshell so neither the topic-create nor
  the send delays the prompt. With `NOTIFY_TG_FORUM=1` it maps one forum topic
  per session, cached in `~/.claude/.tg_topic_<session_id>` — the same
  per-session-file pattern as the worktree tracker.
- Two-way control (reply → new prompt) is intentionally **not** built here: a
  hook can't inject input into a running session. That's Claude Code's official
  `--channels` feature; don't add a `tmux send-keys` listener.

When adding a channel or event, keep the always-`exit 0`,
auto-skip-if-tool/config-missing discipline the other scripts follow.

Cost figures (`$A`/`$B`) are **not** in the statusline JSON — they come from
`ccusage` aggregating `~/.claude/projects/**/*.jsonl`. `statusline.sh` shells
out to a runner (`ccusage` binary → `bunx` → `npx`, first found wins), caches
the result in `~/.claude/.cost_cache` for 30s, and refreshes in the background
behind a `mkdir` lock (`~/.claude/.cost_cache.lock`) so renders stay instant.

## Testing changes manually

There is no test harness. Feed the scripts representative JSON on stdin.

```bash
# Render the status line with a sample payload (mirror the real schema).
echo '{
  "model": {"display_name": "Claude Opus 4.7"},
  "effort": {"level": "high"},
  "thinking": {"enabled": true},
  "workspace": {"project_dir": "'"$PWD"'", "current_dir": "'"$PWD"'"},
  "context_window": {"total_input_tokens": 15500, "context_window_size": 200000, "used_percentage": 8},
  "rate_limits": {
    "five_hour": {"used_percentage": 41, "resets_at": '"$(($(date +%s)+8100))"'},
    "seven_day": {"used_percentage": 9,  "resets_at": '"$(($(date +%s)+273600))"'}
  },
  "session_id": "test"
}' | ./statusline.sh

# Test responsive wrapping at a given width (Claude Code exports $COLUMNS >= 2.1.153).
COLUMNS=60 ./statusline.sh < payload.json

# Exercise the notify hook (done vs waiting). Title/bell need a real tty to be
# visible; piping just confirms it exits 0 and emits no stray output.
printf '%s' '{"hook_event_name":"Stop","cwd":"'"$PWD"'"}' | ./hooks/notify.sh
printf '%s' '{"hook_event_name":"Notification","cwd":"'"$PWD"'","message":"Allow Bash?"}' | ./hooks/notify.sh
CLAUDE_NOTIFY_CONF=/tmp/n.conf ./hooks/notify.sh < payload.json   # test config overrides

# Exercise the worktree hook.
echo '{"tool_name":"Bash","session_id":"test","cwd":"'"$PWD"'","tool_input":{"command":"git worktree add ../foo -b feat/x"}}' \
  | ./hooks/worktree-tracker.sh
cat ~/.claude/.last_worktree_test   # should hold the resolved abs path (if ../foo exists)
rm -f ~/.claude/.last_worktree_test

shellcheck statusline.sh hooks/worktree-tracker.sh install.sh   # if installed
```

## Conventions that matter here

- **Portability.** Targets `bash` on macOS (BSD) and Linux (GNU). Platform
  branching keys off `$OSTYPE` (no probe commands): BSD uses `date -v` / `stat -f`,
  GNU uses `date -d` / `stat -c`. Keep both arms when touching date/stat logic.
- **Graceful degradation, never hard-fail.** Every optional input is guarded —
  missing `ctx`/quota fields render `n/a`, a missing ccusage runner just omits
  the `$` figures, a missing `perl` falls back to a bash width approximation.
  A render must never error or block. The hook always `exit 0`s; on any
  unparseable/unsafe input it silently no-ops and lets the JSON's `current_dir`
  stand.
- **Color handling.** ANSI codes are stored as real ESC bytes (`$'\033[..'`) so
  they can be both printed and *stripped* when measuring on-screen column widths
  for wrapping. Width math counts CJK/emoji as 2 cells and color/zero-width as 0;
  if you add a column or emoji, update the width logic (the `perl` measurer and
  the bash fallback's emoji list) or wrapping will miscount.
- **Hook safety is deliberately narrow.** The worktree hook only matches literal
  `git worktree add`, strips a leading `rtk ` wrapper (RTK rewrites `git …` →
  `rtk git …`), and skips paths with `$`/backticks, subshells, and quoted
  spaces. These limits are intentional — prefer a missed match over a wrong one.

## Installer invariants

`install.sh` must stay **idempotent** and **non-destructive**: re-running adds
no duplicates, backs up any file it replaces (`*.bak.<timestamp>`), and writes
`settings.json` atomically (`mktemp` + `mv`). The `settings.json` merge is a
single `jq` program that sets `.statusLine` and appends the hook to the existing
`Bash` matcher under `.hooks.PostToolUse` *without* dropping other fields or
other Bash hooks the user already has. Preserve that property when editing the merge.
