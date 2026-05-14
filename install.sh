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

# --- update settings.json ---
DESIRED='{"type":"command","command":"~/.claude/statusline.sh","padding":0}'

if [ -f "$SETTINGS" ]; then
  if ! jq empty "$SETTINGS" 2>/dev/null; then
    die "$SETTINGS is not valid JSON — fix it manually first"
  fi
  CURRENT=$(jq -c '.statusLine // empty' "$SETTINGS")
  if [ "$CURRENT" = "$DESIRED" ]; then
    ok "settings.json already configured"
  else
    BACKUP="${SETTINGS}.bak.$(date +%s)"
    cp "$SETTINGS" "$BACKUP"
    warn "settings.json backed up → $BACKUP"
    tmp=$(mktemp)
    jq --argjson sl "$DESIRED" '.statusLine = $sl' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "settings.json updated"
  fi
else
  echo "$DESIRED" | jq '{statusLine: .}' > "$SETTINGS"
  ok "settings.json created"
fi

echo
ok "Done. Restart Claude Code to see the status line."
