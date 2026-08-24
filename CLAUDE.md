# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Custom Claude Code configuration distributed as a dotfiles repo. A few small
shell/Python scripts do all the work; there is no build system, package manager, or test
suite. End users install via `install.sh`, which symlinks the scripts into
`~/.claude/` and merges entries into `~/.claude/settings.json`.

- `statusline.sh` — the status-line renderer Claude Code invokes on every refresh.
- `hooks/worktree-tracker.sh` — a `PostToolUse`/`Bash` hook that tracks `git worktree add`.
- `hooks/notify.sh` — a `SessionStart` + `Stop` + `Notification` +
  `UserPromptSubmit` + `SessionEnd` + `PreToolUse(AskUserQuestion)` +
  `PostToolUse(AskUserQuestion)` hook that alerts you when Claude finishes or
  needs input, across six channels (iTerm2 tab color, tab-title glyph, bell,
  desktop notification, sound, Telegram push), and can start the local Telegram
  reply gateway.
  Configured by `~/.claude/notify.conf` (seeded from `notify.conf.example`).
- `hooks/telegram-reply.py` — one global, Channels-free Telegram long-poll
  gateway that routes forum-topic replies into the matching tmux/iTerm2 TUI.
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

`notify.sh` is wired to six events: `Stop` → **done** (🟢), `Notification` →
**wait** (🟡), `UserPromptSubmit` → **reset** (clears the iTerm2 tab color),
`SessionEnd` → **end** (clears decor + cleans up the forum topic),
`PreToolUse` *matched to `AskUserQuestion`* → **cache the question** (no alert),
and `PostToolUse` *matched to `AskUserQuestion`* → also **reset**.
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
- **`AskUserQuestion` waits surface the question, not the last reply.** The
  `wait` summary is built from the tool's `input.questions[]` — each `question`
  plus its `options[].label` (a `▸ question` / `• option` list) — because the
  choices live in the tool input, not in any assistant text. **The reliable
  source is `PreToolUse(AskUserQuestion)`**, which fires *before* the question
  renders and carries `.tool_input.questions[]` directly: that branch formats the
  block and caches it to a per-session file `~/.claude/.aq_summary_<session_id>`
  (same per-session-file pattern as the worktree tracker). The `Notification`
  (`wait`) handler then prefers that cache. This exists because the obvious
  approach — reading the last `AskUserQuestion` `tool_use` back from the
  transcript on `Notification` — hits a **flush race**: the assistant message
  carrying the tool_use often isn't written to `transcript_path` yet when the
  `Notification` hook reads it, so the scan finds the *previous* tool_use (e.g. an
  `Edit`) and the summary falls through to the pre-question text. That transcript
  scan is kept only as a fallback for installs that predate the PreToolUse hook.
  The cache is cleared on `reset` (answered question or new typed prompt) and on
  `end`, so a stale question can't attach to a later permission `Notification`.
  Other notifications fall through to the text-summary logic above untouched.
- **Answering an in-TUI question doesn't fire `UserPromptSubmit`.** So the amber
  set by the `AskUserQuestion` `Notification` would linger until the next
  `Stop`/typed prompt. The `PostToolUse(AskUserQuestion)` hook closes that gap:
  when the tool completes (you answered, Claude resumes) it runs the same
  **`reset`** as a typed prompt — clears the tab color, restarts the progress
  bar. A `tool_name` guard keeps it a no-op for any other `PostToolUse` even if
  the matcher is broadened. (Permission-prompt approvals share the same gap but
  aren't covered — their tool name varies; the amber there clears at the next
  `Stop`.)
- **A `Notification` is overloaded**: it fires for a real permission/decision
  prompt *and* for the idle "Claude is waiting for your input" nudge. The hook
  reclassifies the idle case (matched on that exact string in `.message`) into a
  low-key **`idle`** state that stops the progress bar and otherwise no-ops — no
  amber tab, no bell/desktop/Telegram. Only genuine decisions stay `wait` (amber).
  Unrecognized notifications default to `wait` (safe side — still surfaced).
- **Focus-aware mute** (macOS) gates only the *local loud* channels
  (bell/desktop/sound) — never the silent title glyph or the remote Telegram
  push (you may be away with the terminal still frontmost). It uses one
  `osascript` frontmost-app query that **fails open** (Accessibility denied →
  empty → not muted).
- **Telegram** runs in a backgrounded subshell so neither the topic-create nor
  the send delays the prompt. With `NOTIFY_TG_FORUM=1` it maps one forum topic
  per session, cached in `~/.claude/.tg_topic_<session_id>` — the same
  per-session-file pattern as the worktree tracker. The cache file is **one JSON
  line** `{"thread":"…","title":"…"}` (read/written by field via jq + the
  `tg_cache_write` helper — robust to titles with quotes/CJK). With
  `NOTIFY_TG_TOPIC_TITLE=1` the topic is named after the session's `ai-title`
  (read from the transcript via `tg_topic_title`; falls back to `last-prompt`,
  then `project ⎇ branch`) and **renamed** (`editForumTopic`) whenever that title
  changes — because `ai-title` only appears a few turns after the topic is first
  created. `NOTIFY_TG_TOPIC_PIN=1` posts the project/branch/cwd/session context
  once on creation and pins it (`pinChatMessage`), keeping the title clean. Both
  need the bot to be a group admin (Manage Topics / Pin Messages).
- **Image mode (`NOTIFY_TG_IMAGE=1`)** renders the full reply to a PNG via
  `hooks/render-reply.py` (headless Chrome) and sends `sendPhoto`/`sendDocument`
  instead of the truncated text. Replies shorter than `NOTIFY_TG_IMAGE_MIN_CHARS`
  skip the render and go out as a *complete* text message (short replies stay
  quick/copyable; only long ones become images) — that threshold also caps those
  text sends, so the image branch is entered only when `summary_raw` exceeds it. Two traps are baked in here. **(1) curl `-F` vs
  `--form-string`.** `-F "caption=<value>"` treats a value beginning with `<` as
  *"read the field from this file"* (and `@` as *"attach this file"*), and the
  caption is HTML starting with `<b>` — so `-F` tried to open a file named after
  the caption and failed with **exit 26** (`CURLE_READ_ERROR`), the real reason
  image mode silently fell back to text. Every *literal* field is sent with
  `--form-string` (verbatim, no `<`/`@` magic); only the image stays `-F
  field=@file`. Don't "simplify" these back to `-F`. **(2) Non-silent failure.**
  The whole branch used to swallow stderr; it now logs each step (python path,
  render rc + stderr, curl exit code + response) to `~/.claude/notify-debug.log`
  under `NOTIFY_DEBUG=1`, and checks the response for `"ok":true` (not just curl's
  exit) so an API rejection is told apart from a network error. The renderer takes
  `--accent` (status colour: green done / amber wait, via
  `NOTIFY_TG_IMAGE_ACCENT_{DONE,WAIT}`), `--theme` (`dark`/`light`, CSS-variable
  palette), and `--meta` (a host · cwd · branch · time line under the header,
  `NOTIFY_TG_IMAGE_META`). Code blocks get a macOS-style title bar (traffic-light
  dots + language label); the language is recovered from the source fences
  (`fence_langs`) because codehilite drops it, and re-attached in source order
  (`decorate_code_blocks`, which no-ops on a count mismatch). `body{min-height:
  100vh}` makes Chrome's over-tall screenshot fill with the real bg colour so
  `autocrop` can trim it — without it a light theme shows a black tail.
  `--semantic` (`NOTIFY_TG_IMAGE_SEMANTIC`) colours by importance: status symbols
  (✓✗⚠), the value inside an inline `code` (`true`/`rc=0`→green, `false`/`error`→
  red), a small CN/EN keyword dictionary (with a `不/没/无/未` negative-lookbehind
  so 不成功 isn't greened), and `> [!WARNING]`/`[!TIP]`… alert cards. `semantic_html`
  runs AFTER stashing code blocks out (so source is never recoloured) and only on
  text nodes between tags (so output stays valid HTML); the alert pass splits one
  merged `<blockquote>` into multiple cards because markdown fuses adjacent `>`
  blocks. Objective signals are false-hit-free; the keyword dictionary is the one
  fuzzy part — keep it small and high-confidence.
- Two-way control is implemented by `hooks/telegram-reply.py`, not official
  Channels. `SessionStart` ensures one process owns the Telegram `getUpdates`
  long-poll stream; a file lock prevents duplicate pollers. The notify hook stores
  `thread → session → tty/tmux_pane` route metadata when it creates or refreshes a
  forum topic. Replies are injected with `tmux send-keys -l`, falling back to
  iTerm2 AppleScript. The gateway persists its update offset, requires
  `NOTIFY_TG_REPLY_ALLOW_FROM`, and fails closed when the allowlist is empty.

When adding a channel or event, keep the always-`exit 0`,
auto-skip-if-tool/config-missing discipline the other scripts follow.

The quota column shows only the **official** `rate_limits` percentages and
reset countdowns. Estimated money figures (🔥 spent / 💰 left, backed by
`ccusage` + a learned per-window budget) used to be appended here but were
**removed on purpose**: ccusage only sees this machine's
`~/.claude/projects/**/*.jsonl`, so on a subscription used from more than one
machine the learned scale shrank to that machine's share and the $ amounts
were systematically wrong. Don't re-add a ccusage-derived money estimate
without solving the multi-machine problem (e.g. a manually pinned budget);
the official `used_percentage` is account-level and needs no local data.
`install.sh` cleans up the feature's old state files (`~/.claude/.cost_cache`,
`.cost_cache.lock`, `.quota_budget`) on upgrade.

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

# AskUserQuestion: PreToolUse caches the question, the next Notification(wait)
# uses that cache (no transcript flush race). The cache is cleared on reset/end.
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"test","cwd":"'"$PWD"'","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?","header":"Ship","options":[{"label":"Yes"},{"label":"No"}]}]}}' | ./hooks/notify.sh
cat ~/.claude/.aq_summary_test   # ▸ Ship it? / • Yes / • No
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"test","cwd":"'"$PWD"'"}' | ./hooks/notify.sh
test -f ~/.claude/.aq_summary_test && echo "BUG: cache lingered" || echo "cache cleared"

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
  missing `ctx`/quota fields render `n/a`, a missing `perl` falls back to a
  bash width approximation.
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
single `jq` program that sets `.statusLine`, seeds `.spinnerVerbs` *only if
absent* (`//=`, so a user's custom verbs are never clobbered), and appends the
hook to the existing `Bash` matcher under `.hooks.PostToolUse` *without* dropping
other fields or other Bash hooks the user already has. Preserve that property
when editing the merge.

`notify.conf` is **3-way-merged** on every upgrade, not just seeded once
(`sync_notify_conf`). On a fresh install the example is copied; on re-run the
latest `notify.conf.example` is laid down verbatim (so new keys + comments
appear), then the user's customizations are migrated into a trailing
`# >>> … migrated overrides >>>` block. The merge is 3-way against a baseline
snapshot, `~/.claude/.notify.conf.base` (= the template the conf was last
reconciled with): a value differing from the *old* default was user-set (carry
it); one equal to it is a stale default (adopt the *new* default). New keys the
user never had inherit the new default. The Telegram **managed block** is carried
verbatim and stays last (highest precedence). Migrated values are written
double-quoted (not `printf %q`, which byte-escapes emoji/CJK on bash 3.2). The
result is compared to the existing conf and only rewritten when it differs, so
re-runs don't churn backups. **First run after this shipped** has no baseline, so
it falls back to "carry anything ≠ new default" for that one run, then writes the
snapshot; every later run is exact.

Backups are **retained, not infinite**: `prune_backups` keeps the newest
`BACKUP_KEEP` (default 3; `0` keeps none) `<file>.bak.<epoch>` per base file and
deletes the rest. It runs last (after Telegram setup) so the current upgrade's
backups are the ones kept, relies on the fixed-width epoch suffix making a glob
already chronological, and is best-effort (never fails the install).
