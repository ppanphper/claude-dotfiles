#!/usr/bin/env bash
# PostToolUse hook on Bash. If the command contained `git worktree add ... <path>`
# and the path exists afterwards, write the absolute path to
# ~/.claude/.last_worktree_<session_id> so statusline.sh can display it.
#
# Limits (intentional):
#   - Only `git worktree add` is matched. No `cd`, no `git clone`, no scripts.
#   - Subshells `(git worktree add ...)` are NOT detected (segments split only
#     on &&, ;, ||, |).
#   - Paths containing `$` or backticks are skipped (no variable expansion).
#   - Quoted paths with embedded spaces are not handled.
# These cases fall back to the JSON's current_dir, which is safe.

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

[ -n "$cmd" ] || exit 0
[ -n "$session_id" ] || exit 0

case "$cmd" in
  *"git worktree add"*) ;;
  *) exit 0 ;;
esac

target=""
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  case "$seg" in
    "git worktree add "*|"git worktree add"$'\t'*) ;;
    *) continue ;;
  esac
  rest="${seg#git worktree add}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  # shellcheck disable=SC2086
  set -- $rest
  skip_next=0
  while [ $# -gt 0 ]; do
    tok="$1"; shift
    if [ "$skip_next" = "1" ]; then skip_next=0; continue; fi
    case "$tok" in
      -b|-B) skip_next=1 ;;
      --) ;;
      -*) ;;
      *'$'*|*'`'*) ;;
      *) target="$tok"; break ;;
    esac
  done
  [ -n "$target" ] && break
done < <(printf '%s\n' "$cmd" | tr '&;|' '\n\n\n')

[ -n "$target" ] || exit 0

case "$target" in
  \"*\") target="${target#\"}"; target="${target%\"}" ;;
  \'*\') target="${target#\'}"; target="${target%\'}" ;;
esac
case "$target" in
  "~/"*) target="$HOME/${target#~/}" ;;
  "~")   target="$HOME" ;;
esac

case "$target" in
  /*) abs="$target" ;;
  *)
    [ -n "$cwd" ] || exit 0
    abs="${cwd%/}/$target"
    ;;
esac

[ -d "$abs" ] || exit 0
abs=$(cd "$abs" 2>/dev/null && pwd -P) || exit 0

mkdir -p "$HOME/.claude"
printf '%s\n' "$abs" > "$HOME/.claude/.last_worktree_${session_id}"
exit 0
