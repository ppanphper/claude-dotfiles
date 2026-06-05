#!/usr/bin/env bash
# One-click installer for claude-dotfiles
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ppanphper/claude-dotfiles/main/install.sh | bash
#
# Or with a custom install dir:
#   CLAUDE_DOTFILES_DIR=~/dev/claude-dotfiles curl -fsSL ... | bash

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

# --- update settings.json ---
DESIRED_STATUSLINE='{"type":"command","command":"'"$CLAUDE_DIR"'/statusline.sh","padding":0}'
HOOK_CMD="$CLAUDE_DIR/hooks/worktree-tracker.sh"

merge_settings() {
  # $1 = current settings.json content (or "{}" if none)
  jq --argjson sl "$DESIRED_STATUSLINE" --arg hook "$HOOK_CMD" '
    .statusLine = $sl
    | .hooks.PostToolUse = (
        (.hooks.PostToolUse // []) as $arr
        | if ($arr | any(.matcher == "Bash")) then
            $arr | map(
              if .matcher == "Bash" then
                .hooks = ((.hooks // []) + (
                  if ((.hooks // []) | any(.command == $hook)) then []
                  else [{type:"command", command:$hook}]
                  end
                ))
              else . end
            )
          else
            $arr + [{matcher:"Bash", hooks:[{type:"command", command:$hook}]}]
          end
      )
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

echo
ok "Done. Restart Claude Code to see the status line."
