# claude-dotfiles

Custom [Claude Code](https://claude.com/claude-code) configuration. Currently
ships a status line that surfaces the things the built-in UI doesn't: absolute
token counts, subscription quota usage and spend, git branch & worktree, and
which subdirectory of a project the session is operating in.

## Status line

A single status row at the bottom of Claude Code that shows:

```
Claude Opus 4.7 [high] 💭 | 🤖 code-reviewer | myproject/src | 🌿 main ⎇ feature-x | ctx: 15.5k/200k (8%) | free: 5h 59% (2h15m) $2.01 / 7d 91% (3d4h) $307
```

Each column is color-coded in your terminal. Columns with no data are
auto-hidden (e.g. no `🤖 agent` outside of `--agent` sessions, no `🌿 branch`
in non-git directories).

A minimal session, just after launching in a non-git directory:

```
Claude Sonnet 4.6 | myproject | ctx: n/a | free: n/a
```

### Responsive wrapping

The columns are **greedily wrapped** across as many rows as needed to fit your
terminal width, so nothing gets cut off in a narrow pane (e.g. an iTerm2 split
pane where several sessions share one window). On a wide terminal everything
stays on a single row as above; as the pane narrows the columns spill onto
additional rows:

```
Claude Opus 4.7 [high] 💭 | 🤖 code-reviewer
myproject/src | 🌿 main
ctx: 15.5k/200k (8%)
free: 5h 59% (2h15m) $2.01 / 7d 91% (3d4h) $307
/full/path/to/myproject/src
```

Wrapping uses the `$COLUMNS` value Claude Code exports before each render, which
**requires Claude Code v2.1.153 or later** (`tput`/`stty` can't see the width
because the status line's stdout is a pipe). On older versions the columns stay
on one row. Display widths account for ANSI colors (zero width) and CJK/emoji
(double width); column boundaries are never split, so a single very long column
(usually `free:`) may still overflow a very narrow pane.

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
| `free: 5h X% (Δ) $A / 7d Y% (Δ) $B` | `100 − .rate_limits.*.used_percentage` (+ `resets_at`); `$` amounts from [`ccusage`](https://github.com/ryoppippi/ccusage) | Remaining percentage of Claude.ai's 5-hour and 7-day rate-limit windows, with time until each resets in parentheses (`2h15m`, `3d4h`, `now`) and the spend so far in that window appended in green. The dollar figures come from `ccusage` (the statusline JSON carries no cost data): `$A` is the active 5-hour billing block, `$B` is the last 7 days. They're cached for 30s and refreshed in the background, so renders stay instant. Quota %/countdown need Pro/Max after the first response (`n/a` for API-key users); the `$` amounts need a JS runtime to run `ccusage` — a global `ccusage` binary, `bunx` (bun), or `npx` (node), whichever is found — and are simply omitted if none is available. |

### Worktree auto-tracking

A `PostToolUse` hook on the `Bash` tool watches for successful `git worktree
add <path>` invocations and writes the new worktree's absolute path to
`~/.claude/.last_worktree_<session_id>`. The status line then displays that
directory and its branch instead of the original session CWD — useful when
you ask Claude to create a new worktree and continue working there, since
Claude Code's session CWD doesn't follow subprocess `cd`s.

Known limits (by design, to keep the hook robust):

- Only `git worktree add` is matched — not arbitrary `cd`, `git clone`, or
  scaffolders like `cargo new`. A leading `rtk ` wrapper is stripped first, so
  commands rewritten by RTK's `rtk hook claude` PreToolUse hook
  (`git worktree add …` → `rtk git worktree add …`) still match.
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

## Done / waiting notifications

A `hooks/notify.sh` hook fires on three Claude Code events and alerts you so you
don't have to babysit the terminal:

- **`Stop`** — Claude finished a turn → state **done** (🟢 by default)
- **`Notification`** — Claude needs your input or a permission confirmation →
  state **waiting** (🟡 by default)
- **`UserPromptSubmit`** — you sent a prompt → state **reset** (clears the tab
  color, so a colored tab always means "has output you haven't acted on", and
  starts the animated "processing" progress bar — see below)

Each state alerts through up to six channels, every one of which is toggled
independently and auto-skipped if the tool/config it needs isn't present:

| Channel | How | macOS | Linux |
| --- | --- | --- | --- |
| **iTerm2 tab color** | OSC 6 — colors the *tab* (green done / amber waiting); Claude Code's own title writes don't clobber it | ✅ iTerm2 | — |
| **Tab-title glyph** | OSC 0 title — Claude Code overwrites it unless you set `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` | ✅ | ✅ |
| **Terminal bell** | `\a` | ✅ | ✅ |
| **Desktop notification** | `terminal-notifier` → `osascript` / `notify-send` | ✅ | needs `notify-send` |
| **Sound** | `afplay` / `paplay` / `canberra-gtk-play` | ✅ | needs PulseAudio/canberra |
| **Telegram push** | `curl` to the Bot API — remote alerts on your phone, optionally one forum topic per session | ✅ | ✅ |

The first three channels write terminal escape codes, but **a Claude Code hook
has no controlling terminal** — `/dev/tty` can't be opened. So the hook walks up
the process tree to the `claude` process, which still owns the pty (e.g.
`/dev/ttys003`), and writes the escape codes straight to that device. The tab
color (OSC 6) is the most useful of these: it persists per-tab, survives Claude
Code's title writes, and is cleared on your next prompt — so a glance across your
iTerm2 tabs shows which sessions have unread output. Desktop and Telegram
messages carry the git branch and a one-line summary (the last assistant message
on `Stop`; for a waiting `Notification`, the last assistant text read from the
session transcript).

On iTerm2 3.6.x+ the hook also shows an **animated "processing" progress bar** on
the tab (OSC 9;4 indeterminate) — it starts when you submit a prompt and clears
when the turn ends or Claude needs you, so a glance shows which tabs are still
working. It's auto-detected via `TERM_FEATURES` and silently skipped elsewhere;
turn it off with `NOTIFY_PROGRESS=0`. Note there's **no "tab gained focus" event**
in Claude Code, so the tab color clears on your *next prompt*, not on focus —
a hook can't be triggered by you clicking back onto the tab.

### Defaults and configuration

By default the **done** state is *quiet* (no bell/popup on every reply while
you're watching) and the **waiting** state is *loud* (bell + desktop popup).
Everything is configured in `~/.claude/notify.conf` (a `KEY=value` shell file the
installer seeds from [`notify.conf.example`](notify.conf.example) and never
overwrites on update). You can flip any channel per state, set iTerm2 tab colors,
pick sounds, or set `NOTIFY_ENABLED=0` to mute everything:

```bash
# ~/.claude/notify.conf
NOTIFY_DONE_TABCOLOR="40 200 80"   # green iTerm2 tab when a turn finishes
NOTIFY_WAIT_TABCOLOR="230 180 40"  # amber tab when Claude needs you
NOTIFY_DONE_DESKTOP=1              # also pop a desktop notification on done
NOTIFY_WAIT_SOUND=1                # play a sound when Claude needs input
```

Claude Code also has a built-in notifier (`preferredNotifChannel` in
`settings.json`, e.g. `"terminal_bell"` or `"iterm2_with_bell"`). It runs
*alongside* this hook, so enable one or the other to avoid a double bell.

### Focus-aware mute (macOS)

`NOTIFY_FOCUS_MUTE=1` (on by default) suppresses the **local loud** channels
(bell / desktop / sound) when a terminal is already the frontmost app — so you
don't get pinged while you're watching Claude work. The silent tab glyph and the
remote Telegram push still fire (you may have walked away with the terminal up).
It detects the frontmost app via `osascript`, which needs Accessibility
permission for your terminal (**System Settings → Privacy & Security →
Accessibility**); if that's denied it fails open and you still get notified.
`NOTIFY_TERMINAL_APPS` lists which app names count as "a terminal" — add yours if
it's missing.

### Telegram push (get pinged away from your desk)

Set a bot token + chat id in `~/.claude/notify.conf` and the **waiting** state
(by default) pushes to your phone:

```bash
# ~/.claude/notify.conf
NOTIFY_TG_BOT_TOKEN="123456:ABC-your-bot-token"   # from @BotFather
NOTIFY_TG_CHAT_ID="-1001234567890"                 # your chat / group id
NOTIFY_TG_FORUM=1                                   # one forum topic per session
NOTIFY_DONE_TG=1                                    # also push on completion
```

With `NOTIFY_TG_FORUM=1`, each Claude session gets its **own forum topic** (the
chat must be a forum supergroup and the bot an admin with *Manage Topics*), named
`project ⎇ branch · <short session id>` — the suffix keeps two sessions of the
same project/branch as distinct topics. The topic id is cached in
`~/.claude/.tg_topic_<session_id>` (mirroring the worktree-tracker's per-session
file pattern) so subsequent messages reuse the same topic. "done" pushes are sent
silently (`disable_notification`), "waiting" pushes ring.

When the session ends, the **`SessionEnd`** hook cleans the topic up so they don't
pile up: `NOTIFY_TG_TOPIC_CLEANUP=close` (default) archives it into the group's
"closed" list keeping the history, `delete` removes it entirely, `cache` only
drops the local cache file, `off` does nothing. (Note: `Stop` is *per-turn*, not
end-of-session — cleaning up there would delete the topic mid-conversation, so
this is wired to `SessionEnd` instead.)

Telegram messages are sent with `parse_mode=HTML`: the assistant's markdown
(`**bold**`, `` `code` ``, `#` headings, `-` bullets) is converted to real
formatting instead of showing the raw symbols, and markdown tables collapse to
readable `a · b` rows. The converter HTML-escapes first and only inserts balanced
tags, so the message is always valid HTML (it falls back to plain text if
Telegram ever rejects it). `NOTIFY_TG_SUMMARY_MAX` sets the Telegram length
budget separately from the shorter desktop/title one.

### Two-way control (reply in Telegram to drive the session)

This hook is **outbound only** — it can't turn a Telegram reply into the next
prompt, because a hook can't inject input into a running Claude Code session.
That's exactly what Claude Code's official **Channels** feature does, and it's
genuinely bidirectional. The installer's guided Telegram setup wires it up for
you (installs the `telegram@claude-plugins-official` plugin, writes its token and
an `access.json` allowlist so you skip pairing, and offers a `claude-tg` alias).
Then start a two-way session with:

```bash
claude-tg   # = claude --channels plugin:telegram@claude-plugins-official
```

The flag is **per session** — only sessions launched with it bridge to Telegram,
and a reply drives *that* session. DM the bot or reply to its messages in the
group to send the next prompt. (Requires Claude Code v2.1.80+, a claude.ai
Pro/Max plan or Console API key, and the `bun` runtime — the installer offers to
install `bun` if it's missing.) Avoid building a `tmux send-keys` listener for
this — it's fragile and Channels is the supported path.

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
4. Symlinks `~/.claude/hooks/worktree-tracker.sh` and
   `~/.claude/hooks/notify.sh` → the repo's hooks (same backup behavior), and
   seeds `~/.claude/notify.conf` from `notify.conf.example` if you don't already
   have one (your existing config is never overwritten).
5. Merges `statusLine`, a `PostToolUse` → `Bash` → `worktree-tracker.sh` entry,
   and `Stop` + `Notification` + `UserPromptSubmit` + `SessionEnd` → `notify.sh`
   entries into
   `~/.claude/settings.json`, preserving every other field and any other hooks
   you've configured. The original file is backed up
   to `settings.json.bak.<timestamp>` before any change is written, and the
   new file is written atomically via `mktemp` + `mv`. Re-running the
   installer is idempotent — no duplicate entries are added.
6. Checks for a ccusage runner (`ccusage`, `bunx`, or `npx`) that powers the
   `$` spend figures. `npx` ships with Node.js, which most machines already
   have, so this usually just passes. If none is found it prints how to enable
   the figures and continues — pass `INSTALL_BUN=1` to also auto-install `bun`
   (the figures stay hidden meanwhile; everything else works).
7. **When run in a terminal** (not piped), offers a guided Telegram setup:
   validates your bot token, auto-detects the chat id, writes the push config to
   `notify.conf`, and — if you opt into two-way replies — installs the official
   Telegram plugin, installs `bun` if needed, writes its token + an `access.json`
   allowlist (so you skip pairing), and offers to add a `claude-tg` alias. Run
   `bash ~/claude-dotfiles/install.sh` from a terminal to reach this step; under
   `curl | bash` it's skipped (stdin isn't a TTY) and the installer says so. Opt
   out with `SKIP_TELEGRAM_SETUP=1`.

Restart Claude Code to see the status line. **The whole setup — status line,
hooks, and Telegram push/two-way — is reproducible on a new machine by running
the installer in a terminal.**

### Options

```bash
# Install the repo somewhere other than ~/claude-dotfiles
CLAUDE_DOTFILES_DIR=~/dev/claude-dotfiles \
  curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash

# Skip the jq auto-install (you'll install it manually)
SKIP_JQ_INSTALL=1 \
  curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash

# Auto-install bun when no ccusage runner (ccusage/bunx/npx) is found, so the
# $ spend figures work out of the box (by default the installer only warns;
# Node.js is on most machines already, so npx usually covers it)
INSTALL_BUN=1 \
  curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash
```

### Manual install

If you'd rather not run a piped shell script:

```bash
git clone https://github.com/ppanphper/claude-dotfiles.git ~/claude-dotfiles
chmod +x ~/claude-dotfiles/statusline.sh ~/claude-dotfiles/hooks/*.sh
ln -s ~/claude-dotfiles/statusline.sh ~/.claude/statusline.sh
mkdir -p ~/.claude/hooks
ln -s ~/claude-dotfiles/hooks/worktree-tracker.sh ~/.claude/hooks/worktree-tracker.sh
ln -s ~/claude-dotfiles/hooks/notify.sh ~/.claude/hooks/notify.sh
cp -n ~/claude-dotfiles/notify.conf.example ~/.claude/notify.conf   # optional, for tweaks
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
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
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
rm ~/.claude/statusline.sh ~/.claude/hooks/worktree-tracker.sh ~/.claude/hooks/notify.sh
rm -f ~/.claude/.last_worktree_* ~/.claude/.tg_topic_* ~/.claude/notify.conf
# Then either remove the "statusLine" + matching "hooks" entries (PostToolUse,
# Stop, Notification, UserPromptSubmit) from ~/.claude/settings.json, or restore
# from the settings.json.bak.<timestamp> the installer created.
rm -rf ~/claude-dotfiles
```

## Requirements

- `bash`
- `git`
- `jq` — used both by `install.sh` to merge `settings.json` safely and by
  `statusline.sh` itself to parse the JSON Claude Code pipes to it on every
  refresh. Auto-installed by `install.sh` unless `SKIP_JQ_INSTALL=1`.
- [`ccusage`](https://github.com/ryoppippi/ccusage) + a JS runtime — _optional_,
  only for the `$` spend figures appended to the `free` column. The status line
  uses the first of these it finds on your `PATH`: a globally-installed
  `ccusage` binary, `bunx` (bun), or `npx` (node); the latter two fetch
  `ccusage` on demand. It always runs with cached pricing (`--offline`, no
  network). If none of the three is available, the spend figures are silently
  omitted and everything else keeps working. Since `npx` ships with Node.js
  (already on most machines), `install.sh` doesn't install a runtime by default
  — pass `INSTALL_BUN=1` to auto-install `bun` if no runner is found.
- Desktop-notification / sound tools — _optional_, only for those notification
  channels. macOS desktop popups use `terminal-notifier` (else the built-in
  `osascript`); Linux uses `notify-send`. Sounds use `afplay` (macOS) or
  `paplay`/`canberra-gtk-play` (Linux). Telegram push uses `curl` (ubiquitous).
  Focus-aware mute uses `osascript` (macOS, needs Accessibility permission). Any
  that's missing is silently skipped; the tab-title glyph and bell work
  everywhere with no extra tools.
- `perl` — _optional_, used to measure column display widths precisely (CJK and
  emoji count as two cells) when wrapping. Present by default on macOS and most
  Linux distributions. If it's missing, a pure-bash approximation is used that
  handles ASCII and the status line's emoji; very wide CJK directory names may
  then wrap slightly early.
- Claude Code **v2.1.153+** for responsive wrapping (it exports `$COLUMNS`).
  Earlier versions render everything on a single row.

Tested on macOS and Linux. Windows is not currently supported.
