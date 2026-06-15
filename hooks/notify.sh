#!/usr/bin/env bash
# Notify hook for Claude Code. Wire to three events in settings.json:
#   - Stop             → Claude finished a turn        (state "done", green tab)
#   - Notification     → Claude needs input/permission (state "wait", amber tab)
#   - UserPromptSubmit → you sent a prompt             (state "reset", clears tab)
#   - SessionEnd       → the session ended             (state "end", topic cleanup)
#
# UserPromptSubmit also starts an iTerm2 OSC 9;4 "indeterminate" progress bar (an
# animated bar on the tab) that signals "processing"; Stop/Notification clear it.
# SessionEnd closes/deletes this session's Telegram forum topic (NOTIFY_TG_TOPIC_CLEANUP).
#
# Channels (per-state, each auto-skipped when its tool/config/terminal is
# missing; the script always exits 0):
#   1. iTerm2 tab color   OSC 6   — persistent per-tab done/waiting indicator
#   2. tab-title glyph    OSC 0   — Claude Code overwrites it unless you set
#                                   CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
#   3. terminal bell      \a
#   4. desktop notify     iTerm2 → OSC 9 (NATIVE, click jumps to the tab);
#                         else terminal-notifier→osascript (mac) / notify-send
#   5. sound              afplay (mac) / paplay|canberra (linux)
#   6. Telegram push      curl to the Bot API (remote; one topic/session)
#
# A Claude Code hook has NO controlling terminal, so /dev/tty can't be opened.
# Channels 1-3 (and the OSC 9 notification) therefore climb the process tree to
# the `claude` process, which still owns the pty (e.g. /dev/ttys003), and write
# the escape codes to that device. Everything iTerm2-specific (OSC 6 tab color,
# OSC 9 notification) is gated on $TERM_PROGRAM = iTerm.app, so other terminals
# just fall back to the desktop/sound/Telegram channels — no garbage emitted.
#
# Defaults below; override in ~/.claude/notify.conf (see notify.conf.example).

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

ESC=$'\033'; BEL=$'\007'

j() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
event=$(j '.hook_event_name')
cwd=$(j '.cwd')
session_id=$(j '.session_id')

case "$event" in
  Stop)             state="done" ;;
  Notification)     state="wait" ;;
  UserPromptSubmit) state="reset" ;;
  SessionEnd)       state="end" ;;
  *) exit 0 ;;
esac

# Find the terminal device by climbing the process tree to the first ancestor
# that owns a tty (this hook's own process has none). macOS: ttysNNN; Linux:
# pts/N. Echoes e.g. /dev/ttys003, or nothing.
find_tty() {
  local pid="$$" t p i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    [ -n "$pid" ] && [ "$pid" != "0" ] || break
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$t" in
      ''|'?'|'??') ;;
      *) printf '/dev/%s\n' "$t"; return 0 ;;
    esac
    p=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    pid="$p"
  done
}
TTYDEV=$(find_tty)
tty_ok=0
[ -n "$TTYDEV" ] && [ -w "$TTYDEV" ] && tty_ok=1
[ "$TERM_PROGRAM" = "iTerm.app" ] && IS_ITERM=1 || IS_ITERM=0

# Write raw bytes (no escape interpretation of the payload) to the terminal.
tw() { [ "$tty_ok" = "1" ] && { printf '%s' "$1" > "$TTYDEV"; } 2>/dev/null; }

# Drive the iTerm2 OSC 9;4 progress bar ($1: "3"=indeterminate, "0"=hide). Only
# emits on an iTerm2 that advertises progress-bar support ("P" in TERM_FEATURES,
# iTerm2 3.6.x+) — older iTerm2 would otherwise show "4;3" as notification text.
prog() {
  [ "$NOTIFY_PROGRESS" = "1" ] && [ "$IS_ITERM" = "1" ] && [ "$tty_ok" = "1" ] || return 0
  case "$TERM_FEATURES" in *P*) tw "${ESC}]9;4;$1${BEL}" ;; esac
}

# Convert a small subset of Markdown (the shape Claude's summaries take) to
# Telegram-safe HTML for parse_mode=HTML. HTML-escapes first, then inserts only
# balanced tags, so the output is valid HTML even on malformed/truncated input.
# Newlines are preserved; works on both BSD (macOS) and GNU sed.
md2tg_html() {
  sed -E \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/`([^`]+)`/<code>\1<\/code>/g' \
    -e 's/\*\*([^*]+)\*\*/<b>\1<\/b>/g' \
    -e 's/^[[:space:]]*#{1,6}[[:space:]]+(.*)$/<b>\1<\/b>/' \
    -e 's/^([[:space:]]*)[-*][[:space:]]+/\1• /' \
    -e '/^[[:space:]:|-]*-{3,}[[:space:]:|-]*$/d' \
    -e 's/^[[:space:]]*[|][[:space:]]*//' \
    -e 's/[[:space:]]*[|][[:space:]]*$//' \
    -e 's/[[:space:]]*[|][[:space:]]*/ · /g'
}

# --- defaults (override in ~/.claude/notify.conf) ----------------------------
NOTIFY_ENABLED=1

NOTIFY_DONE_TITLE=0; NOTIFY_DONE_BELL=0; NOTIFY_DONE_DESKTOP=0; NOTIFY_DONE_SOUND=0; NOTIFY_DONE_TG=0
NOTIFY_WAIT_TITLE=0; NOTIFY_WAIT_BELL=1; NOTIFY_WAIT_DESKTOP=1; NOTIFY_WAIT_SOUND=0; NOTIFY_WAIT_TG=1

NOTIFY_LABEL_DONE="Claude done"
NOTIFY_LABEL_WAIT="Claude waiting"
NOTIFY_GLYPH_DONE="🟢"
NOTIFY_GLYPH_WAIT="🟡"

NOTIFY_DONE_TABCOLOR=""
NOTIFY_WAIT_TABCOLOR=""
NOTIFY_TABCOLOR_RESET=1

# Animated "processing" progress bar on the tab (iTerm2 OSC 9;4 indeterminate).
# Starts when you submit a prompt, stops when the turn ends or Claude needs you.
# iTerm2 3.6.x+ only (auto-detected); silently ignored on every other terminal.
NOTIFY_PROGRESS=1

# iTerm2 native notification (OSC 9): clicking it jumps to the tab. 1=use it on
# iTerm2 in place of terminal-notifier/osascript. iTerm2 decides visibility
# per-session, so this path isn't gated by focus-mute.
NOTIFY_DESKTOP_OSC9=1

NOTIFY_SOUND_DONE=""
NOTIFY_SOUND_WAIT=""
NOTIFY_SUMMARY=1
NOTIFY_SUMMARY_MAX=200
# Telegram renders an HTML-formatted message and can hold more than a desktop
# popup, so it gets its own (usually larger) summary budget.
NOTIFY_TG_SUMMARY_MAX=600
# Render the FULL reply to an image (no truncation, web-quality layout) and send
# that instead of the text message. Needs python3 + headless Chrome (auto-falls
# back to the text message if either is missing). See hooks/render-reply.py.
NOTIFY_TG_IMAGE=0
NOTIFY_TG_IMAGE_WIDTH=760

NOTIFY_FOCUS_MUTE=1
NOTIFY_TERMINAL_APPS="Terminal iTerm2 Ghostty kitty WezTerm Alacritty Warp Code Hyper Tabby rio"

NOTIFY_TG_BOT_TOKEN=""
NOTIFY_TG_CHAT_ID=""
NOTIFY_TG_FORUM=0
# What to do with a session's forum topic when the session ends (SessionEnd):
#   close  = archive it (keeps history, folds into the "closed" list) [default]
#   delete = remove the topic and all its messages (irreversible)
#   cache  = only delete the local ~/.claude/.tg_topic_<id> file, leave the topic
#   off    = do nothing
NOTIFY_TG_TOPIC_CLEANUP=close

NOTIFY_DEBUG=0

CONF="${CLAUDE_NOTIFY_CONF:-$HOME/.claude/notify.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

[ "$NOTIFY_ENABLED" = "1" ] || exit 0

# --- reset: prompt submitted → clear the tab color, start the progress bar ----
# This is the "you're now typing / driving the session again" event, so it
# clears the amber/green left from the previous turn AND starts the animated
# processing indicator that runs until the next Stop/Notification.
if [ "$state" = "reset" ]; then
  [ "$NOTIFY_TABCOLOR_RESET" = "1" ] && [ "$IS_ITERM" = "1" ] && \
    tw "${ESC}]6;1;bg;*;default${BEL}"
  prog 3
  exit 0
fi

# --- end: session is over → clean up this session's forum topic ---------------
# Mapped from SessionEnd. "close" archives the topic (keeps history), "delete"
# removes it entirely, "cache" only drops the local cache file. The API call is
# backgrounded so exiting Claude Code never blocks on the network.
if [ "$state" = "end" ]; then
  [ "$NOTIFY_TG_TOPIC_CLEANUP" = "off" ] && exit 0
  tf="$HOME/.claude/.tg_topic_${session_id}"
  if [ "$NOTIFY_TG_FORUM" = "1" ] && [ -n "$session_id" ] && [ -f "$tf" ]; then
    thread=$(head -n1 "$tf" 2>/dev/null)
    if [ -n "$thread" ] && [ "$NOTIFY_TG_TOPIC_CLEANUP" != "cache" ] \
       && [ -n "$NOTIFY_TG_BOT_TOKEN" ] && [ -n "$NOTIFY_TG_CHAT_ID" ] \
       && command -v curl >/dev/null 2>&1; then
      meth="closeForumTopic"; [ "$NOTIFY_TG_TOPIC_CLEANUP" = "delete" ] && meth="deleteForumTopic"
      ( curl -fsS -m 10 "https://api.telegram.org/bot${NOTIFY_TG_BOT_TOKEN}/${meth}" \
          --data-urlencode "chat_id=${NOTIFY_TG_CHAT_ID}" \
          --data-urlencode "message_thread_id=${thread}" >/dev/null 2>&1 ) >/dev/null 2>&1 &
    fi
    rm -f "$tf" 2>/dev/null
  fi
  exit 0
fi

# --- summary source (Stop carries it; Notification needs the transcript) -----
summary_raw=$(j '.last_assistant_message')
transcript=$(j '.transcript_path')
if [ -z "$summary_raw" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  summary_raw=$(tail -n 100 "$transcript" 2>/dev/null | jq -rs '
    [ .[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text ] | last // empty
  ' 2>/dev/null)
fi
[ -n "$summary_raw" ] || summary_raw=$(j '.message')
[ -n "$cwd" ] || cwd="$PWD"
project=$(basename "$cwd")

if [ "$state" = "done" ]; then
  glyph="$NOTIFY_GLYPH_DONE"; sound="$NOTIFY_SOUND_DONE"; title_text="$NOTIFY_LABEL_DONE"
  do_title="$NOTIFY_DONE_TITLE"; do_bell="$NOTIFY_DONE_BELL"; do_desktop="$NOTIFY_DONE_DESKTOP"
  do_sound="$NOTIFY_DONE_SOUND"; do_tg="$NOTIFY_DONE_TG"; tabcolor="$NOTIFY_DONE_TABCOLOR"
else
  glyph="$NOTIFY_GLYPH_WAIT"; sound="$NOTIFY_SOUND_WAIT"; title_text="$NOTIFY_LABEL_WAIT"
  do_title="$NOTIFY_WAIT_TITLE"; do_bell="$NOTIFY_WAIT_BELL"; do_desktop="$NOTIFY_WAIT_DESKTOP"
  do_sound="$NOTIFY_WAIT_SOUND"; do_tg="$NOTIFY_WAIT_TG"; tabcolor="$NOTIFY_WAIT_TABCOLOR"
fi

branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
label="$project"; [ -n "$branch" ] && label="$project ⎇ $branch"
summary=""
if [ "$NOTIFY_SUMMARY" = "1" ] && [ -n "$summary_raw" ]; then
  # One-line, de-noised text for the desktop popup / title (drop **bold** and
  # `code` markers so they don't show literally). Telegram gets richer HTML below.
  summary=$(printf '%s' "$summary_raw" | tr '\n\r\t' '   ' | sed -E 's/\*\*//g; s/`//g')
  [ "${#summary}" -gt "$NOTIFY_SUMMARY_MAX" ] && summary="${summary:0:$NOTIFY_SUMMARY_MAX}…"
fi
headline="$title_text · $label"
body="$headline"; [ -n "$summary" ] && body="$headline"$'\n'"$summary"
notif_line="$glyph $headline"; [ -n "$summary" ] && notif_line="$notif_line — $summary"

case "$OSTYPE" in
  darwin*|*bsd*) PLAT="mac" ;;
  *)             PLAT="linux" ;;
esac

# --- stop the processing progress bar: the turn ended or Claude needs you -----
prog 0

# --- channel 2: tab title (any terminal; silent; ignores focus-mute) ---------
[ "$do_title" = "1" ] && tw "${ESC}]0;${glyph} ${title_text} · ${project}${BEL}"

# --- channel 1: iTerm2 tab color (iTerm2 only; silent; ignores focus-mute) ---
tabcolor_done=0
if [ -n "$tabcolor" ] && [ "$IS_ITERM" = "1" ] && [ "$tty_ok" = "1" ]; then
  # shellcheck disable=SC2086
  set -- $tabcolor; r="${1:-0}"; g="${2:-0}"; b="${3:-0}"
  tw "${ESC}]6;1;bg;red;brightness;${r}${BEL}${ESC}]6;1;bg;green;brightness;${g}${BEL}${ESC}]6;1;bg;blue;brightness;${b}${BEL}"
  tabcolor_done=1
fi

# --- focus-aware mute (mac): are you already looking at a terminal? ----------
muted=0
if [ "$NOTIFY_FOCUS_MUTE" = "1" ] && [ "$PLAT" = "mac" ] \
   && { [ "$do_bell" = "1" ] || [ "$do_desktop" = "1" ] || [ "$do_sound" = "1" ]; } \
   && command -v osascript >/dev/null 2>&1; then
  front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
  [ -n "$front" ] && case " $NOTIFY_TERMINAL_APPS " in *" $front "*) muted=1 ;; esac
fi

# --- channel 3: bell (local, honors focus-mute) ------------------------------
[ "$do_bell" = "1" ] && [ "$muted" = "0" ] && tw "$BEL"

# --- channel 4: desktop notification -----------------------------------------
# iTerm2: native OSC 9 (click jumps to the tab; iTerm2 gates visibility itself,
# so not subject to focus-mute). Other terminals: GUI notifier, focus-muted.
desktop_done=0
if [ "$do_desktop" = "1" ]; then
  if [ "$IS_ITERM" = "1" ] && [ "$tty_ok" = "1" ] && [ "$NOTIFY_DESKTOP_OSC9" = "1" ]; then
    tw "${ESC}]9;${notif_line}${BEL}"; desktop_done=1
  elif [ "$muted" = "0" ]; then
    if [ "$PLAT" = "mac" ]; then
      if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "$headline" -message "${summary:-$project}" \
          -group "claude-$project" -activate com.googlecode.iterm2 >/dev/null 2>&1
      elif command -v osascript >/dev/null 2>&1; then
        st="${headline//\\/}"; st="${st//\"/\'}"
        sm="${summary:-$project}"; sm="${sm//\\/}"; sm="${sm//\"/\'}"
        osascript -e "display notification \"$sm\" with title \"$st\"" >/dev/null 2>&1
      fi
    else
      command -v notify-send >/dev/null 2>&1 && notify-send "$headline" "${summary:-$project}" >/dev/null 2>&1
    fi
    desktop_done=1
  fi
fi

# --- channel 5: sound (local, honors focus-mute; backgrounded) ---------------
if [ "$do_sound" = "1" ] && [ "$muted" = "0" ]; then
  if [ "$PLAT" = "mac" ]; then
    if [ -z "$sound" ]; then
      [ "$state" = "done" ] && sound="/System/Library/Sounds/Glass.aiff" \
                            || sound="/System/Library/Sounds/Funk.aiff"
    fi
    command -v afplay >/dev/null 2>&1 && [ -f "$sound" ] && ( afplay "$sound" >/dev/null 2>&1 & )
  else
    if command -v paplay >/dev/null 2>&1; then
      [ -n "$sound" ] || sound="/usr/share/sounds/freedesktop/stereo/complete.oga"
      [ -f "$sound" ] && ( paplay "$sound" >/dev/null 2>&1 & )
    elif command -v canberra-gtk-play >/dev/null 2>&1; then
      ( canberra-gtk-play -i complete >/dev/null 2>&1 & )
    fi
  fi
fi

# --- channel 6: Telegram push (remote; ignores focus-mute; backgrounded) -----
if [ "$do_tg" = "1" ] && [ -n "$NOTIFY_TG_BOT_TOKEN" ] && [ -n "$NOTIFY_TG_CHAT_ID" ] \
   && command -v curl >/dev/null 2>&1; then
  # Build an HTML message: bold header line + lightly-converted summary (newlines
  # kept). parse_mode=HTML renders **bold**/`code`/headings instead of showing
  # the raw markdown the assistant emits.
  esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  tg_hdr=$(printf '%s' "$title_text · $label" | esc)
  tg_html="<b>${glyph} ${tg_hdr}</b>"
  if [ "$NOTIFY_SUMMARY" = "1" ] && [ -n "$summary_raw" ]; then
    tg_sum="$summary_raw"
    [ "${#tg_sum}" -gt "$NOTIFY_TG_SUMMARY_MAX" ] && tg_sum="${tg_sum:0:$NOTIFY_TG_SUMMARY_MAX}…"
    tg_sum=$(printf '%s' "$tg_sum" | md2tg_html)
    [ -n "$tg_sum" ] && tg_html="${tg_html}"$'\n'"${tg_sum}"
  fi
  # Image mode caption is just the header (the full reply is in the image).
  tg_caption="<b>${glyph} ${tg_hdr}</b>"
  dn=$([ "$state" = "done" ] && echo true || echo false)
  (
    api="https://api.telegram.org/bot${NOTIFY_TG_BOT_TOKEN}"
    thread=""
    if [ "$NOTIFY_TG_FORUM" = "1" ] && [ -n "$session_id" ]; then
      tf="$HOME/.claude/.tg_topic_${session_id}"
      if [ -f "$tf" ]; then
        thread=$(head -n1 "$tf" 2>/dev/null)
      else
        # Topic title = "project ⎇ branch · <short session>". The short session
        # suffix keeps two sessions of the same project/branch as distinct topics.
        topic_name="$label · ${session_id:0:6}"
        thread=$(curl -fsS -m 10 "${api}/createForumTopic" \
                   --data-urlencode "chat_id=${NOTIFY_TG_CHAT_ID}" \
                   --data-urlencode "name=${topic_name}" 2>/dev/null \
                 | jq -r '.result.message_thread_id // empty' 2>/dev/null)
        [ -n "$thread" ] && printf '%s\n' "$thread" > "$tf"
      fi
    fi

    sent=0
    # Image mode: render the FULL reply to a PNG (no truncation, web-quality
    # layout) and send that, with the header as the caption. Needs python3 +
    # headless Chrome; render-reply.py decides sendPhoto vs sendDocument and
    # falls back here to the HTML text message on any failure.
    if [ "$NOTIFY_TG_IMAGE" = "1" ] && [ -n "$summary_raw" ] && command -v python3 >/dev/null 2>&1; then
      render=$(python3 -c "import os,sys;print(os.path.join(os.path.dirname(os.path.realpath(sys.argv[1])),'render-reply.py'))" "$0" 2>/dev/null)
      if [ -n "$render" ] && [ -f "$render" ]; then
        td=$(mktemp -d 2>/dev/null) || td=""
        if [ -n "$td" ]; then
          res=$(printf '%s' "$summary_raw" | python3 "$render" --out "$td/reply.png" --header "$title_text · $label" 2>/dev/null)
          if [ -n "$res" ]; then
            TAB=$(printf '\t')
            kind=${res%%"$TAB"*}; img=${res#*"$TAB"}
            meth="sendPhoto"; field="photo"
            [ "$kind" = "document" ] && { meth="sendDocument"; field="document"; }
            if [ -f "$img" ] && curl -fsS -m 60 "${api}/${meth}" \
                 -F "chat_id=${NOTIFY_TG_CHAT_ID}" \
                 ${thread:+-F "message_thread_id=${thread}"} \
                 -F "${field}=@${img}" \
                 -F "parse_mode=HTML" \
                 -F "caption=${tg_caption}" \
                 -F "disable_notification=${dn}" >/dev/null 2>&1; then
              sent=1
            fi
          fi
          rm -rf "$td"
        fi
      fi
    fi

    if [ "$sent" = "0" ]; then
      # parse_mode=HTML, but fall back to plain text if Telegram rejects the entities.
      curl -fsS -m 10 "${api}/sendMessage" \
        --data-urlencode "chat_id=${NOTIFY_TG_CHAT_ID}" \
        ${thread:+--data-urlencode "message_thread_id=${thread}"} \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${tg_html}" \
        --data-urlencode "disable_notification=${dn}" \
        >/dev/null 2>&1 \
      || curl -fsS -m 10 "${api}/sendMessage" \
        --data-urlencode "chat_id=${NOTIFY_TG_CHAT_ID}" \
        ${thread:+--data-urlencode "message_thread_id=${thread}"} \
        --data-urlencode "text=${glyph} ${body}" \
        --data-urlencode "disable_notification=${dn}" \
        >/dev/null 2>&1
    fi
  ) >/dev/null 2>&1 &
fi

# --- diagnostics -------------------------------------------------------------
if [ "$NOTIFY_DEBUG" = "1" ]; then
  { printf '%s event=%s state=%s iterm=%s tty=%s tty_ok=%s tabcolor_done=%s desktop_done=%s muted=%s\n' \
      "$(date '+%H:%M:%S')" "$event" "$state" "$IS_ITERM" "$TTYDEV" "$tty_ok" \
      "$tabcolor_done" "$desktop_done" "$muted" \
      >> "$HOME/.claude/notify-debug.log"; } 2>/dev/null
fi

exit 0
