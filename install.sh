#!/usr/bin/env bash
# One-click installer for claude-dotfiles
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash
#
# Or with a custom install dir:
#   CLAUDE_DOTFILES_DIR=~/dev/claude-dotfiles curl -fsSL ... | bash
#
# Env knobs: CLAUDE_DOTFILES_DIR (install location), BACKUP_KEEP (how many
# "<file>.bak.<epoch>" backups to retain per file, default 3; 0 keeps none),
# SKIP_TELEGRAM_SETUP=1, INSTALL_BUN=1, SKIP_JQ_INSTALL=1.

set -e

REPO_URL="https://github.com/ppanphper/claude-dotfiles.git"
INSTALL_DIR="${CLAUDE_DOTFILES_DIR:-$HOME/claude-dotfiles}"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
info() { printf '%b\n' "${CYAN}==>${RESET} $1"; }
ok()   { printf '%b\n' "${GREEN}✓${RESET}  $1"; }
warn() { printf '%b\n' "${YELLOW}!${RESET}  $1"; }
die()  { printf '%b\n' "${RED}✗${RESET}  $1" >&2; exit 1; }

# --- prerequisites ---
command -v git >/dev/null || die "git not installed"

install_jq() {
  command -v jq >/dev/null && return 0
  if [ "${SKIP_JQ_INSTALL:-0}" = "1" ]; then
    die "jq not installed and SKIP_JQ_INSTALL=1 set — install jq manually and re-run"
  fi

  info "jq not found — attempting auto-install"

  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null; then
      sudo_cmd="sudo"
    fi
  fi

  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null; then
        info "running: brew install jq"
        brew install jq
      elif command -v port >/dev/null; then
        info "running: $sudo_cmd port install jq"
        $sudo_cmd port install jq
      else
        die "macOS: install Homebrew (https://brew.sh) and re-run, or: brew install jq manually"
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null; then
        info "running: $sudo_cmd apt-get install -y jq"
        $sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y jq
      elif command -v dnf >/dev/null; then
        info "running: $sudo_cmd dnf install -y jq"
        $sudo_cmd dnf install -y jq
      elif command -v yum >/dev/null; then
        info "running: $sudo_cmd yum install -y jq"
        $sudo_cmd yum install -y jq
      elif command -v pacman >/dev/null; then
        info "running: $sudo_cmd pacman -S --noconfirm jq"
        $sudo_cmd pacman -S --noconfirm jq
      elif command -v zypper >/dev/null; then
        info "running: $sudo_cmd zypper install -y jq"
        $sudo_cmd zypper install -y jq
      elif command -v apk >/dev/null; then
        info "running: $sudo_cmd apk add jq"
        $sudo_cmd apk add jq
      else
        die "no supported package manager (apt/dnf/yum/pacman/zypper/apk) — install jq manually"
      fi
      ;;
    *)
      die "unsupported OS: $(uname -s) — install jq manually"
      ;;
  esac

  command -v jq >/dev/null || die "jq install ran but jq still not on PATH"
  ok "jq installed: $(jq --version)"
}

# statusline.sh shows the `$` spend figures by running ccusage through the first
# of these it finds: a global `ccusage` binary, `bunx` (bun), or `npx` (node).
# Node (so `npx`) ships on most machines, so this usually just passes. Without
# any runner the quota columns still render — only the amounts are hidden, so we
# don't force-install a whole JS runtime by default. Opt in with INSTALL_BUN=1.
ensure_ccusage_runner() {
  if command -v ccusage >/dev/null 2>&1; then
    ok "ccusage runner present: ccusage ($(command -v ccusage))"; return 0
  elif command -v bunx >/dev/null 2>&1; then
    ok "ccusage runner present: bunx ($(command -v bunx))"; return 0
  elif command -v npx >/dev/null 2>&1; then
    ok "ccusage runner present: npx ($(command -v npx))"; return 0
  fi

  # No runner found (uncommon — most machines have Node).
  if [ "${INSTALL_BUN:-0}" != "1" ]; then
    warn "no ccusage runner (ccusage/bunx/npx) found — the \$ spend figures will be hidden"
    warn "fix: install Node.js so \`npx\` exists, or re-run with INSTALL_BUN=1 to add bun"
    warn "everything else in the status line works without it"
    return 0
  fi

  # Node has no clean one-line cross-platform installer; bun does, so INSTALL_BUN
  # grabs bun (self-contained, no sudo) rather than trying to install node.
  if ! command -v curl >/dev/null 2>&1; then
    warn "INSTALL_BUN=1 but no curl to fetch the installer — install bun manually (https://bun.sh)"
    return 0
  fi
  info "installing bun (INSTALL_BUN=1) — powers the \$ spend figures"
  if curl -fsSL https://bun.sh/install | bash; then
    # bun installs to ~/.bun by default; surface it for this session's check.
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
    if command -v bunx >/dev/null 2>&1; then
      ok "bun installed: $(bun --version 2>/dev/null) — restart your shell to put it on PATH"
    else
      warn "bun installed but not on PATH yet — restart your shell and it'll be picked up"
    fi
  else
    warn "bun install failed — install bun or Node.js manually to enable the \$ figures"
  fi
}

# Install bun if missing (the Telegram plugin's MCP server runs on it). Returns
# non-zero if it still isn't available afterward.
try_install_bun() {
  command -v bun >/dev/null 2>&1 && return 0
  command -v curl >/dev/null 2>&1 || { warn "no curl to fetch bun — install it manually: https://bun.sh"; return 1; }
  info "installing bun (the Telegram plugin's MCP server needs it)…"
  if curl -fsSL https://bun.sh/install | bash; then
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
    command -v bun >/dev/null 2>&1 && { ok "bun installed: $(bun --version 2>/dev/null) — restart your shell to keep it on PATH"; return 0; }
  fi
  warn "bun install didn't complete — install it manually (https://bun.sh) and re-run."
  return 1
}

# Keep the telegram plugin installed (cached) but globally DISABLED in
# settings.json. A globally-enabled plugin spawns its bun getUpdates poller in
# EVERY claude session, and Claude Code then blocks ~2s at session end while that
# poller drains (telegram server.ts caps it at 2s). Push notifications go through
# notify.sh (plain curl) and don't need the plugin, so the only thing that needs it
# is two-way — which claude-tg re-enables per-session via --settings. Net: normal
# sessions exit instantly; two-way still works on demand. Idempotent + atomic.
disable_telegram_plugin_globally() {
  local key="telegram@claude-plugins-official"
  command -v jq >/dev/null 2>&1 || {
    warn "jq missing — can't disable telegram plugin; set enabledPlugins[\"$key\"]=false yourself to avoid a ~2s session-end delay."
    return 0
  }
  [ -f "$SETTINGS" ] && jq empty "$SETTINGS" 2>/dev/null || {
    warn "$SETTINGS missing/invalid — skipping telegram global-disable."
    return 0
  }
  if [ "$(jq -r --arg k "$key" '.enabledPlugins[$k] // empty' "$SETTINGS")" = "false" ]; then
    ok "telegram plugin already globally disabled (on-demand via claude-tg)"
    return 0
  fi
  local tmp; tmp=$(mktemp)
  if jq --arg k "$key" '.enabledPlugins[$k] = false' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"
    mv "$tmp" "$SETTINGS"
    ok "telegram plugin globally disabled — claude-tg enables it per-session (skips ~2s exit delay)"
  else
    rm -f "$tmp"
    warn "couldn't update $SETTINGS — disable the telegram plugin manually."
  fi
}

# Add a `claude-tg` shell FUNCTION to the user's rc: open an interactive session
# with the Telegram two-way channel. Called only after the user opts into two-way,
# so we write it automatically (idempotently). The telegram plugin is kept
# globally DISABLED (see disable_telegram_plugin_globally) so normal sessions don't
# pay its ~2s getUpdates-drain at exit; the function re-enables it for THIS session
# only via --settings and wires two-way via --channels. It invokes plain `claude`
# (not `command claude`) so a user's proxy-wrapper `claude` function still applies.
add_claude_tg_alias() {
  local rc=""
  case "${SHELL##*/}" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)    rc="${ENV:-$HOME/.profile}" ;;
  esac
  [ -f "$rc" ] || : > "$rc"
  if grep -q 'claude-tg()' "$rc" 2>/dev/null; then
    ok "claude-tg function already in $rc"
    return 0
  fi
  grep -q 'alias claude-tg=' "$rc" 2>/dev/null && \
    warn "an old 'alias claude-tg' is in $rc — delete it; the function below replaces it."
  if cat >> "$rc" <<'TGFUNC'

# claude-tg: open an interactive Telegram two-way session. The telegram plugin is
# kept globally disabled (so normal sessions skip its ~2s getUpdates drain at exit);
# --settings enables it for THIS session only and --channels wires up two-way.
# Invokes plain `claude` so a user's proxy-wrapper `claude` function still applies.
unalias claude-tg 2>/dev/null  # drop a stale same-name alias so re-sourcing won't clash
claude-tg() {
  claude --settings '{"enabledPlugins":{"telegram@claude-plugins-official":true}}' \
         --channels plugin:telegram@claude-plugins-official "$@"
}
TGFUNC
  then
    ok "claude-tg function added to $rc (run: source $rc)"
  else
    warn "couldn't write to $rc — add a claude-tg function yourself (see README)."
  fi
}

# Write the managed Telegram block to notify.conf. notify.conf is sourced and we
# append at the end, so these assignments win over the defaults above them. The
# block is delimited by sentinels and rewritten in place, so re-running the
# installer updates it rather than stacking duplicates.
write_tg_conf() {
  # $1 = bot token, $2 = chat id, $3 = forum (1/0), $4 = image mode (1/0)
  local s="# >>> claude-dotfiles telegram (managed) >>>"
  local e="# <<< claude-dotfiles telegram (managed) <<<"
  local tmp; tmp=$(mktemp)
  if [ -f "$NOTIFY_CONF" ]; then
    awk -v s="$s" -v e="$e" '
      $0==s {skip=1; next} skip && $0==e {skip=0; next} !skip {print}
    ' "$NOTIFY_CONF" > "$tmp"
  fi
  # Seed THIS machine's label once, outside the managed block, so editing it to a
  # friendly name survives re-runs (runtime falls back to `hostname -s` anyway).
  if ! grep -q '^NOTIFY_TG_HOST_LABEL=' "$tmp" 2>/dev/null; then
    printf 'NOTIFY_TG_HOST_LABEL="%s"\n' "$(hostname -s 2>/dev/null || hostname 2>/dev/null)" >> "$tmp"
  fi
  {
    printf '%s\n' "$s"
    printf 'NOTIFY_TG_BOT_TOKEN="%s"\n' "$1"
    printf 'NOTIFY_TG_CHAT_ID="%s"\n' "$2"
    printf 'NOTIFY_TG_FORUM=%s\n' "$3"
    printf 'NOTIFY_WAIT_TG=1\n'
    printf 'NOTIFY_TG_IMAGE=%s\n' "${4:-0}"
    # Push-only, no two-way: a finished session's topic has no lasting value, so
    # delete it on SessionEnd to keep the forum's topic list clean (the script's
    # own default stays the safer "close" for anyone not configured via here).
    printf 'NOTIFY_TG_TOPIC_CLEANUP=delete\n'
    printf '%s\n' "$e"
  } >> "$tmp"
  mv "$tmp" "$NOTIFY_CONF"
}

# Install + configure the official Telegram plugin (the *reply* half). The push
# hook only sends and the plugin only receives, so reusing one bot is fine. We
# also pre-write access.json (allowlist) so the user skips the pairing dance.
# $1 = bot token, $2 = the push chat id (group → enabled for group replies).
setup_telegram_channels() {
  local token="$1" chat="$2"
  command -v claude >/dev/null 2>&1 || { warn "claude CLI not on PATH — install Claude Code, then see README 'Two-way control'."; return 0; }
  if ! command -v bun >/dev/null 2>&1; then
    printf '      The two-way plugin needs bun. Install it now? [Y/n] '
    local b; read -r b || true
    case "$b" in [nN]*) warn "skipping two-way — install bun (https://bun.sh) and re-run."; return 0 ;; esac
    try_install_bun || return 0
  fi
  info "Installing official Telegram plugin…"
  claude plugin marketplace update claude-plugins-official >/dev/null 2>&1 || true
  if claude plugin install telegram@claude-plugins-official >/dev/null 2>&1; then
    ok "plugin installed: telegram@claude-plugins-official"
  else
    warn "plugin install failed — run manually: claude plugin install telegram@claude-plugins-official"
  fi
  local envdir="$CLAUDE_DIR/channels/telegram"
  mkdir -p "$envdir"
  ( umask 077; printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token" > "$envdir/.env" )
  chmod 600 "$envdir/.env" 2>/dev/null || true
  ok "token written: $envdir/.env"

  # --- access control: write access.json so pairing isn't needed -------------
  printf '\n   Who may drive Claude through this bot? (allowlist — skips pairing)\n'
  printf '      Your Telegram numeric user id (from @userinfobot; blank to skip): '
  local uid; read -r uid || true
  case "$uid" in *[!0-9]*) [ -n "$uid" ] && warn "not a numeric id — ignoring it."; uid="" ;; esac

  # A negative push chat id is a group/supergroup — offer to enable group replies.
  local grp=""
  case "$chat" in -[0-9]*) grp="$chat" ;; esac

  if [ -z "$uid" ] && [ -z "$grp" ]; then
    info "No id given — leaving the default 'pairing' policy."
    info "Approve later in Claude with: /telegram:access pair <code>"
  else
    local af="[]"; [ -n "$uid" ] && af="[\"$uid\"]"
    local groups="{}"
    [ -n "$grp" ] && groups="{\"$grp\":{\"requireMention\":true,\"allowFrom\":$af}}"
    if command -v jq >/dev/null 2>&1; then
      ( umask 077; jq -n --argjson af "$af" --argjson g "$groups" \
          '{dmPolicy:"allowlist", allowFrom:$af, groups:$g}' > "$envdir/access.json" )
    else
      ( umask 077; printf '{"dmPolicy":"allowlist","allowFrom":%s,"groups":%s}\n' "$af" "$groups" > "$envdir/access.json" )
    fi
    chmod 600 "$envdir/access.json" 2>/dev/null || true
    ok "access.json written (allowlist — no pairing needed)"
    if [ -n "$grp" ]; then
      info "Group $grp enabled — reply to the bot's messages there to drive Claude."
      warn "For group replies/topics, make the bot a group ADMIN with 'Manage Topics'."
    fi
  fi

  disable_telegram_plugin_globally
  add_claude_tg_alias

  printf '\n   %b\n' "${CYAN}Finish two-way (interactive — run these yourself):${RESET}"
  printf '     1. Start a two-way session with:  %s\n' "claude-tg"
  printf '        (full form: claude --settings '\''{"enabledPlugins":{"telegram@claude-plugins-official":true}}'\'' --channels plugin:telegram@claude-plugins-official)\n'
  printf '     2. DM the bot (or reply to it in the group) — it reaches Claude.\n'
  [ -z "$uid" ] && printf '     3. If you skipped the id: /telegram:access pair <code> to approve yourself.\n'
}

# Optional guided Telegram setup. Only runs with a real terminal (skipped under
# `curl | bash`, where stdin is the script). Opt out with SKIP_TELEGRAM_SETUP=1.
setup_telegram() {
  [ "${SKIP_TELEGRAM_SETUP:-0}" = "1" ] && return 0
  if [ ! -t 0 ]; then
    info "Telegram alerts (push + optional two-way replies) are available."
    info "To set them up, run this installer in a terminal: bash \"$INSTALL_DIR/install.sh\""
    return 0
  fi
  # Already configured? (real token in notify.conf) → don't re-prompt.
  if [ -f "$NOTIFY_CONF" ] && grep -q '^NOTIFY_TG_BOT_TOKEN="[0-9]' "$NOTIFY_CONF" 2>/dev/null; then
    ok "Telegram already configured in notify.conf (left untouched)"
    return 0
  fi

  printf '\n'
  info "Optional: Telegram notifications"
  printf '   %s\n' "Get Claude's done/waiting alerts — with a summary — on your phone,"
  printf '   %s\n' "even when you're away from your desk."
  printf '   Set up Telegram push now? [y/N] '
  local reply; read -r reply || return 0
  case "$reply" in [yY]*) ;; *) info "Skipped. Add it later by editing $NOTIFY_CONF."; return 0 ;; esac

  printf '\n   1) Create a bot: open @BotFather in Telegram, send /newbot, copy the token.\n'
  printf '      Bot token (blank to skip): '
  local token; read -r token || return 0
  [ -z "$token" ] && { warn "no token — skipping Telegram setup."; return 0; }

  # Validate the token and learn the bot's name in one call.
  local botname=""
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    botname=$(curl -s "https://api.telegram.org/bot${token}/getMe" 2>/dev/null | jq -r 'select(.ok).result.username // empty' 2>/dev/null) || true
    if [ -z "$botname" ]; then
      warn "couldn't verify that token with Telegram — double-check it. Continuing anyway."
    else
      ok "bot verified: @$botname"
    fi
  fi

  printf '\n   2) Message your bot once (any text), then we auto-detect your chat id.\n'
  printf '      Press Enter to auto-detect, or paste a chat id: '
  local chat; read -r chat || return 0
  if [ -z "$chat" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    chat=$(curl -s "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null \
      | jq -r '[.result[]?.message.chat.id] | last // empty' 2>/dev/null) || true
    [ -n "$chat" ] && ok "detected chat id: $chat"
  fi
  if [ -z "$chat" ]; then
    warn "no chat id — message your bot first, then paste the id."
    printf '      Chat id (blank to skip): '
    read -r chat || return 0
    [ -z "$chat" ] && { warn "no chat id — skipping Telegram setup."; return 0; }
  fi

  # Per-session forum topics need a real forum supergroup — a plain group or DM
  # can't have topics, so enable it only when getChat confirms is_forum (this is
  # the exact trap of "forum=1 on a basic group" that silently sends nothing).
  local forum=0
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    case "$chat" in
      -*)
        local isf
        isf=$(curl -s "https://api.telegram.org/bot${token}/getChat" \
                --data-urlencode "chat_id=${chat}" 2>/dev/null \
              | jq -r 'select(.ok).result.is_forum // false' 2>/dev/null) || true
        if [ "$isf" = "true" ]; then
          forum=1; ok "forum supergroup detected — each session gets its own topic."
        else
          info "not a forum supergroup — using plain group messages."
          info "(turn on Topics in the group + make the bot admin, then re-run for per-session topics.)"
        fi
        ;;
    esac
  fi

  # Image mode: render the full reply to an image (needs python3 + headless
  # Chrome; degrades to text if either is missing).
  local image=0
  if command -v python3 >/dev/null 2>&1; then
    printf '\n   Send the FULL reply as a rendered image (web-quality layout, no\n'
    printf '   truncation; needs headless Chrome — falls back to text if absent)? [y/N] '
    local im; read -r im || true
    case "$im" in [yY]*) image=1 ;; esac
  fi

  write_tg_conf "$token" "$chat" "$forum" "$image"
  ok "Telegram push enabled in $NOTIFY_CONF"
  [ "$image" = "1" ] && ok "image mode on (NOTIFY_TG_IMAGE=1)"

  if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null --fail "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=✅ claude-dotfiles: Telegram push is configured." 2>/dev/null; then
      ok "sent a test message — check Telegram."
    else
      warn "test send failed — verify the chat id and that you've messaged the bot."
    fi
  fi

  printf '\n   Also REPLY in Telegram to drive Claude (official Channels plugin)? [y/N] '
  local reply2; read -r reply2 || return 0
  case "$reply2" in
    [yY]*) setup_telegram_channels "$token" "$chat" ;;
    *) info "Push-only for now. Add two-way later — see README 'Two-way control'." ;;
  esac
}

# Migrate ~/.claude/notify.conf onto the latest template (notify.conf.example) so a
# new release's added keys + comments show up, WITHOUT clobbering the user's edits.
# This is a 3-way merge against a baseline snapshot (~/.claude/.notify.conf.base =
# the template defaults the conf was last reconciled with): a value that differs
# from the OLD default was changed by the USER (carry it), one that equals it is a
# stale default (adopt the NEW default instead). New keys the user never had simply
# inherit the new template's default. The Telegram "managed" block is carried
# verbatim. Idempotent + atomic; backs up before replacing.
sync_notify_conf() {
  local example="$NOTIFY_CONF_EXAMPLE" user="$NOTIFY_CONF" base="$NOTIFY_BASE"
  [ -f "$example" ] || { warn "notify.conf.example missing — skipping notify.conf sync"; return 0; }

  # Baseline for "old defaults": the saved snapshot if present, else the new
  # template (first run after this feature ships — for that one run we can't tell a
  # user-set value from a since-changed default; every later run is exact).
  local base_src="$example"
  [ -f "$base" ] && base_src="$base"

  local s="# >>> claude-dotfiles telegram (managed) >>>"
  local e="# <<< claude-dotfiles telegram (managed) <<<"

  # The Telegram managed block (token/chat/…) — carried verbatim — and the keys it
  # assigns (excluded from the overrides below so they aren't duplicated).
  local managed_block managed_keys
  managed_block=$(awk -v s="$s" -v e="$e" '$0==s{f=1} f{print} $0==e{f=0}' "$user")
  managed_keys=$(printf '%s\n' "$managed_block" | grep -oE '^NOTIFY_[A-Z_]+=' | sed 's/=$//' | sort -u) || true

  # Keys the user EXPLICITLY assigned, outside the managed block, ignoring
  # comment-only lines. No line anchor → the example's compound "A=0; B=0; …" lines
  # are caught too. An inline trailing "# note" sits after the value, so it's safe.
  local user_keys
  user_keys=$(awk -v s="$s" -v e="$e" '$0==s{f=1} !f && $0!~/^[[:space:]]*#/{print} $0==e{f=0}' "$user" \
              | grep -oE 'NOTIFY_[A-Z_]+=' | sed 's/=$//' | sort -u) || true

  # Dump KEY<TAB>VALUE by sourcing a conf in a clean subshell (robust to
  # quotes/CJK/compound lines). Reads only the keys named in $2.
  _dump() {
    ( set +e; set +u; . "$1" >/dev/null 2>&1
      for k in $2; do printf '%s\t%s\n' "$k" "${!k-}"; done )
  }
  _val() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}'; }
  # Double-quote a value the way the template does (keeps UTF-8 emoji/CJK readable,
  # unlike printf %q which byte-escapes them on bash 3.2). Escape \ " $ `.
  _q() {
    local v=$1
    v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}
    printf '"%s"' "$v"
  }

  local new_vals old_vals user_vals
  new_vals=$(_dump "$example"  "$user_keys")
  old_vals=$(_dump "$base_src" "$user_keys")
  user_vals=$(_dump "$user"    "$user_keys")

  # Carry a key only if the user's value differs from the OLD template default.
  local overrides="" k old uval line
  for k in $user_keys; do
    printf '%s\n' "$managed_keys" | grep -qxF "$k" && continue   # in managed block → skip
    old=$(_val "$old_vals" "$k")
    uval=$(_val "$user_vals" "$k")
    [ "$uval" = "$old" ] && continue                              # untouched → take new default
    line="$k=$(_q "$uval")"
    overrides+="$line"$'\n'
  done

  # Assemble: new template (verbatim) + migrated overrides (win over the defaults
  # above) + the Telegram managed block last (wins over everything, as before).
  local tmp; tmp=$(mktemp)
  cat "$example" > "$tmp"
  if [ -n "$overrides" ]; then
    {
      printf '\n# >>> claude-dotfiles migrated overrides >>>\n'
      printf '# 升级时从你旧的 notify.conf 迁移过来的改动（位于模板默认值之后，故会覆盖它们）。\n'
      printf '# 可直接在此编辑；下次升级会继续保留你的改动。\n'
      printf '%s' "$overrides"
      printf '# <<< claude-dotfiles migrated overrides <<<\n'
    } >> "$tmp"
  fi
  [ -n "$managed_block" ] && printf '\n%s\n' "$managed_block" >> "$tmp"

  if cmp -s "$tmp" "$user"; then
    rm -f "$tmp"
    cp "$example" "$base" 2>/dev/null || true
    ok "notify.conf already up to date with the latest template"
    return 0
  fi
  local bak="${user}.bak.$(date +%s)"
  cp "$user" "$bak"
  mv "$tmp" "$user"
  cp "$example" "$base" 2>/dev/null || true
  warn "notify.conf backed up → $bak"
  ok "notify.conf migrated onto the latest template (your settings carried over)"
}

# Backup retention. Every upgrade can leave a "<file>.bak.<epoch>" behind (symlink
# swaps, settings.json merge, notify.conf migration); without pruning they pile up
# forever. Keep the newest $BACKUP_KEEP per base file (default 3), delete the rest.
# The .bak.<epoch> suffix is fixed-width seconds, so a glob already lists them
# oldest→newest. BACKUP_KEEP=0 keeps none. Best-effort: never fails the install.
prune_backups() {
  local base="$1" keep="${BACKUP_KEEP:-3}"
  case "$keep" in ''|*[!0-9]*) keep=3 ;; esac
  shopt -s nullglob
  local matches=( "$base".bak.* )
  shopt -u nullglob
  local total=${#matches[@]}
  [ "$total" -gt "$keep" ] || return 0
  local remove=$(( total - keep )) i=0
  while [ "$i" -lt "$remove" ]; do
    rm -f "${matches[$i]}" 2>/dev/null || true
    i=$(( i + 1 ))
  done
  info "pruned $remove old backup(s) of $(basename "$base") (kept newest $keep)"
}

install_jq

mkdir -p "$CLAUDE_DIR"

# --- clone / update repo ---
if [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating $INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  info "Cloning to $INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- symlink statusline.sh ---
TARGET="$INSTALL_DIR/statusline.sh"
LINK="$CLAUDE_DIR/statusline.sh"
[ -f "$TARGET" ] || die "$TARGET not found"
chmod +x "$TARGET"

if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; then
  ok "symlink already in place: $LINK"
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  BACKUP="${LINK}.bak.$(date +%s)"
  warn "existing $LINK backed up → $BACKUP"
  mv "$LINK" "$BACKUP"
  ln -s "$TARGET" "$LINK"
  ok "symlink created: $LINK → $TARGET"
else
  ln -s "$TARGET" "$LINK"
  ok "symlink created: $LINK → $TARGET"
fi

# --- symlink hooks/worktree-tracker.sh ---
HOOKS_DIR="$CLAUDE_DIR/hooks"
mkdir -p "$HOOKS_DIR"

HOOK_TARGET="$INSTALL_DIR/hooks/worktree-tracker.sh"
HOOK_LINK="$HOOKS_DIR/worktree-tracker.sh"
[ -f "$HOOK_TARGET" ] || die "$HOOK_TARGET not found"
chmod +x "$HOOK_TARGET"

if [ -L "$HOOK_LINK" ] && [ "$(readlink "$HOOK_LINK")" = "$HOOK_TARGET" ]; then
  ok "hook symlink already in place: $HOOK_LINK"
elif [ -e "$HOOK_LINK" ] || [ -L "$HOOK_LINK" ]; then
  BACKUP="${HOOK_LINK}.bak.$(date +%s)"
  warn "existing $HOOK_LINK backed up → $BACKUP"
  mv "$HOOK_LINK" "$BACKUP"
  ln -s "$HOOK_TARGET" "$HOOK_LINK"
  ok "hook symlink created: $HOOK_LINK → $HOOK_TARGET"
else
  ln -s "$HOOK_TARGET" "$HOOK_LINK"
  ok "hook symlink created: $HOOK_LINK → $HOOK_TARGET"
fi

# --- symlink hooks/notify.sh (Stop + Notification alerts) ---
NOTIFY_TARGET="$INSTALL_DIR/hooks/notify.sh"
NOTIFY_LINK="$HOOKS_DIR/notify.sh"
[ -f "$NOTIFY_TARGET" ] || die "$NOTIFY_TARGET not found"
chmod +x "$NOTIFY_TARGET"

if [ -L "$NOTIFY_LINK" ] && [ "$(readlink "$NOTIFY_LINK")" = "$NOTIFY_TARGET" ]; then
  ok "notify hook symlink already in place: $NOTIFY_LINK"
elif [ -e "$NOTIFY_LINK" ] || [ -L "$NOTIFY_LINK" ]; then
  BACKUP="${NOTIFY_LINK}.bak.$(date +%s)"
  warn "existing $NOTIFY_LINK backed up → $BACKUP"
  mv "$NOTIFY_LINK" "$BACKUP"
  ln -s "$NOTIFY_TARGET" "$NOTIFY_LINK"
  ok "notify hook symlink created: $NOTIFY_LINK → $NOTIFY_TARGET"
else
  ln -s "$NOTIFY_TARGET" "$NOTIFY_LINK"
  ok "notify hook symlink created: $NOTIFY_LINK → $NOTIFY_TARGET"
fi

# --- symlink hooks/render-reply.py (optional: NOTIFY_TG_IMAGE renderer) -------
# notify.sh finds it via realpath($0), so this is just for discoverability.
RENDER_TARGET="$INSTALL_DIR/hooks/render-reply.py"
RENDER_LINK="$HOOKS_DIR/render-reply.py"
if [ -f "$RENDER_TARGET" ]; then
  chmod +x "$RENDER_TARGET"
  if [ -L "$RENDER_LINK" ] && [ "$(readlink "$RENDER_LINK")" = "$RENDER_TARGET" ]; then
    :
  else
    [ -e "$RENDER_LINK" ] || [ -L "$RENDER_LINK" ] && mv "$RENDER_LINK" "${RENDER_LINK}.bak.$(date +%s)"
    ln -s "$RENDER_TARGET" "$RENDER_LINK"
    ok "reply-image renderer symlinked: $RENDER_LINK"
  fi
fi

# --- seed / migrate ~/.claude/notify.conf from the example --------------------
# Fresh install: copy the template. Upgrade: 3-way-merge the latest template onto
# the user's conf (new keys/comments appear; their edits are carried over) — see
# sync_notify_conf. .notify.conf.base snapshots the template we last merged with.
NOTIFY_CONF_EXAMPLE="$INSTALL_DIR/notify.conf.example"
NOTIFY_CONF="$CLAUDE_DIR/notify.conf"
NOTIFY_BASE="$CLAUDE_DIR/.notify.conf.base"
if [ -f "$NOTIFY_CONF" ]; then
  sync_notify_conf
elif [ -f "$NOTIFY_CONF_EXAMPLE" ]; then
  cp "$NOTIFY_CONF_EXAMPLE" "$NOTIFY_CONF"
  cp "$NOTIFY_CONF_EXAMPLE" "$NOTIFY_BASE"
  ok "notify.conf created from example: $NOTIFY_CONF"
fi

# --- update settings.json ---
DESIRED_STATUSLINE='{"type":"command","command":"'"$CLAUDE_DIR"'/statusline.sh","padding":0}'
HOOK_CMD="$CLAUDE_DIR/hooks/worktree-tracker.sh"
NOTIFY_CMD="$CLAUDE_DIR/hooks/notify.sh"

# Default Chinese spinner verbs (the word shown next to Claude Code's loading
# spinner). Seeded only when the user hasn't set their own spinnerVerbs, so a
# customized list is never clobbered on re-run. "replace" swaps the built-in
# English verbs entirely; switch to "append" to keep them and add these.
DESIRED_SPINNERVERBS='{"mode":"replace","verbs":["思考中","分析中","构思中","琢磨中","推敲中","酝酿中","盘算中","推理中","处理中","编码中","码字中","调试中","优化中","重构中","检索中","解析中","计算中","规划中","整理中","钻研中","验证中","组织中","打磨中","捣鼓中","施法中","召唤中","炼丹中","搬砖中","脑暴中","冲浪中","运筹中","加载中"]}'

merge_settings() {
  # $1 = current settings.json content (or "{}" if none)
  jq --argjson sl "$DESIRED_STATUSLINE" --argjson spin "$DESIRED_SPINNERVERBS" --arg hook "$HOOK_CMD" --arg notify "$NOTIFY_CMD" '
    # Ensure an event group (Stop/Notification) carries our command exactly once,
    # leaving any other hooks the user already has on that event intact.
    def ensure_event($key):
      .hooks[$key] = (
        (.hooks[$key] // []) as $arr
        | if ($arr | any(((.hooks // []) | any(.command == $notify)))) then $arr
          else $arr + [{matcher:"", hooks:[{type:"command", command:$notify}]}]
          end
      );
    # Ensure a PostToolUse matcher group carries $cmd exactly once, leaving any
    # other PostToolUse matchers (and other commands on this matcher) intact.
    def ensure_ptu($matcher; $cmd):
      .hooks.PostToolUse = (
        (.hooks.PostToolUse // []) as $arr
        | if ($arr | any(.matcher == $matcher)) then
            $arr | map(
              if .matcher == $matcher then
                .hooks = ((.hooks // []) + (
                  if ((.hooks // []) | any(.command == $cmd)) then []
                  else [{type:"command", command:$cmd}]
                  end
                ))
              else . end
            )
          else
            $arr + [{matcher:$matcher, hooks:[{type:"command", command:$cmd}]}]
          end
      );
    .statusLine = $sl
    | .spinnerVerbs //= $spin
    | ensure_ptu("Bash"; $hook)
    | ensure_ptu("AskUserQuestion"; $notify)
    | ensure_event("Stop")
    | ensure_event("Notification")
    | ensure_event("UserPromptSubmit")
    | ensure_event("SessionEnd")
  '
}

if [ -f "$SETTINGS" ]; then
  if ! jq empty "$SETTINGS" 2>/dev/null; then
    die "$SETTINGS is not valid JSON — fix it manually first"
  fi
  tmp=$(mktemp)
  merge_settings < "$SETTINGS" > "$tmp"
  if jq -e --slurpfile a "$SETTINGS" --slurpfile b "$tmp" -n '$a == $b' >/dev/null; then
    ok "settings.json already configured"
    rm -f "$tmp"
  else
    BACKUP="${SETTINGS}.bak.$(date +%s)"
    cp "$SETTINGS" "$BACKUP"
    warn "settings.json backed up → $BACKUP"
    mv "$tmp" "$SETTINGS"
    ok "settings.json updated"
  fi
else
  echo '{}' | merge_settings > "$SETTINGS"
  ok "settings.json created"
fi

# --- ensure a ccusage runner for the $ spend figures (optional feature) ---
ensure_ccusage_runner

# --- optional guided Telegram setup (interactive terminals only) ---
setup_telegram

# --- prune old backups so they don't accumulate across upgrades ---------------
# Runs last so this upgrade's fresh backups are the ones kept. Covers every file
# the installer may back up. Tune with BACKUP_KEEP (default 3; 0 keeps none).
for _b in "$LINK" "$HOOK_LINK" "$NOTIFY_LINK" "$RENDER_LINK" "$SETTINGS" "$NOTIFY_CONF"; do
  [ -n "$_b" ] && prune_backups "$_b"
done

echo
ok "Done. Restart Claude Code to see the status line."
