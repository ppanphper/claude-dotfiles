#!/usr/bin/env bash
# Claude Code statusline:
# model [effort] 💭 | 🤖 agent | project[/subdir] | 🌿 branch
#   | ctx: in/total (X%) | free: 5h X% (reset) $A / 7d Y% (reset) $B
# <full current path in dim gray>

input=$(cat)

DIM='\033[2m'
RESET='\033[0m'
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
MAGENTA='\033[35m'
BLUE='\033[34m'
RED='\033[31m'
MONEY='\033[92m'

fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) {
      v = n/1000000
      if (v == int(v)) printf "%dM", v; else printf "%.1fM", v
    } else if (n >= 1000) {
      v = n/1000
      if (v >= 100 || v == int(v)) printf "%dk", v; else printf "%.1fk", v
    } else {
      printf "%d", n
    }
  }'
}

fmt_dur() {
  awk -v s="$1" 'BEGIN {
    if (s <= 0) { printf "now"; exit }
    d = int(s/86400); s -= d*86400
    h = int(s/3600);  s -= h*3600
    m = int(s/60)
    if (d > 0)      printf "%dd%dh", d, h
    else if (h > 0) printf "%dh%dm", h, m
    else            printf "%dm", m
  }'
}

fmt_money() {
  awk -v n="$1" 'BEGIN {
    n = n + 0
    if (n >= 100) printf "$%.0f", n
    else          printf "$%.2f", n
  }'
}

# 1. Model + effort + thinking
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
effort=$(echo "$input" | jq -r '.effort.level // empty')
thinking=$(echo "$input" | jq -r '.thinking.enabled // false')
model_str="$model"
[ -n "$effort" ] && model_str="${model_str} [${effort}]"
[ "$thinking" = "true" ] && model_str="${model_str} 💭"

# 2. Agent
agent_name=$(echo "$input" | jq -r '.agent.name // empty')

# 3. Project / current dir
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
git_worktree=$(echo "$input" | jq -r '.workspace.git_worktree // empty')
[ -z "$current_dir" ] && current_dir="$PWD"
[ -z "$project_dir" ] && project_dir="$current_dir"

# Override current_dir if the worktree-tracker hook recorded a newer path.
# See hooks/worktree-tracker.sh — written after a successful `git worktree add`.
session_id=$(echo "$input" | jq -r '.session_id // empty')
if [ -n "$session_id" ]; then
  wt_file="$HOME/.claude/.last_worktree_${session_id}"
  if [ -f "$wt_file" ]; then
    saved=$(head -n1 "$wt_file" 2>/dev/null)
    if [ -n "$saved" ] && [ -d "$saved" ]; then
      current_dir="$saved"
      git_worktree=""
    fi
  fi
fi

# Recompute git_worktree if we don't have one yet (e.g., after override).
if [ -z "$git_worktree" ]; then
  gitdir=$(git -C "$current_dir" rev-parse --git-dir 2>/dev/null)
  case "$gitdir" in
    */.git/worktrees/*) git_worktree=$(basename "$gitdir") ;;
  esac
fi

project_name=$(basename "$project_dir")
if [ "$current_dir" = "$project_dir" ]; then
  dir_str="$project_name"
else
  case "$current_dir" in
    "$project_dir"/*) dir_str="$project_name/${current_dir#$project_dir/}" ;;
    *) dir_str="$(basename "$current_dir")" ;;
  esac
fi

# 4. Git branch (worktree name is already shown in the dir column, so don't repeat it)
branch=$(git -C "$current_dir" branch --show-current 2>/dev/null)
if [ -n "$branch" ]; then
  branch_str="🌿 ${branch}"
else
  branch_str=""
fi

# 5. Context: tokens used / window size (percent)
ctx_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$ctx_in" ] && [ -n "$ctx_size" ] && [ "$ctx_in" != "0" ]; then
  pct_disp=$(printf '%.0f' "${ctx_pct:-0}")
  ctx_str="ctx: $(fmt_tokens "$ctx_in")/$(fmt_tokens "$ctx_size") (${pct_disp}%)"
elif [ -n "$ctx_pct" ]; then
  ctx_str="ctx: $(printf '%.0f' "$ctx_pct")%"
else
  ctx_str="ctx: n/a"
fi

# 6. Cost figures: spend in the current 5-hour block + last 7 days, via ccusage.
# Not in the statusline JSON — ccusage aggregates ~/.claude/projects/**/*.jsonl.
# Cache (TTL 30s) and refresh in the background so renders stay snappy.
# These get appended onto the matching 5h / 7d quota parts below.
c5=""; c7=""
COST_CACHE="$HOME/.claude/.cost_cache"
COST_LOCK="$HOME/.claude/.cost_cache.lock"
COST_TTL=30
refresh_costs() {
  local since b5 d7 tmp
  since=$(date -v-6d +%Y%m%d)
  b5=$(bunx ccusage blocks --active --json --offline 2>/dev/null \
       | jq -r '[.blocks[]?|select(.isActive)|.costUSD]|add // empty')
  d7=$(bunx ccusage daily --json --offline --since "$since" 2>/dev/null \
       | jq -r '.totals.totalCost // empty')
  if [ -n "${b5}${d7}" ]; then
    tmp=$(mktemp "${COST_CACHE}.XXXXXX") || return
    printf '%s %s\n' "${b5:-0}" "${d7:-0}" > "$tmp"
    mv -f "$tmp" "$COST_CACHE"
  fi
}
if command -v bunx >/dev/null 2>&1; then
  cnow=$(date +%s)
  stale=1
  if [ -f "$COST_CACHE" ]; then
    age=$(( cnow - $(stat -f %m "$COST_CACHE" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$COST_TTL" ] && stale=0
  fi
  if [ "$stale" = 1 ]; then
    # Clear a lock left behind by a crashed refresh.
    if [ -d "$COST_LOCK" ]; then
      lage=$(( cnow - $(stat -f %m "$COST_LOCK" 2>/dev/null || echo 0) ))
      [ "$lage" -gt 120 ] && rmdir "$COST_LOCK" 2>/dev/null
    fi
    if mkdir "$COST_LOCK" 2>/dev/null; then
      if [ -f "$COST_CACHE" ]; then
        ( refresh_costs; rmdir "$COST_LOCK" 2>/dev/null ) >/dev/null 2>&1 &
      else
        refresh_costs; rmdir "$COST_LOCK" 2>/dev/null   # first run: compute now
      fi
    fi
  fi
  [ -f "$COST_CACHE" ] && read -r c5 c7 < "$COST_CACHE" 2>/dev/null
fi

# 7. Quota remaining (100 - used_percentage) + reset countdown, with spend appended.
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
if [ -n "$five_pct" ] || [ -n "$week_pct" ]; then
  now=$(date +%s)
  five_str="n/a"
  week_str="n/a"
  if [ -n "$five_pct" ]; then
    five_str=$(awk -v p="$five_pct" 'BEGIN{printf "%.0f%%", 100-p}')
    [ -n "$five_reset" ] && five_str="${five_str} ($(fmt_dur $((five_reset - now))))"
    [ -n "$c5" ] && five_str="${five_str} ${MONEY}$(fmt_money "$c5")${MAGENTA}"
  fi
  if [ -n "$week_pct" ]; then
    week_str=$(awk -v p="$week_pct" 'BEGIN{printf "%.0f%%", 100-p}')
    [ -n "$week_reset" ] && week_str="${week_str} ($(fmt_dur $((week_reset - now))))"
    [ -n "$c7" ] && week_str="${week_str} ${MONEY}$(fmt_money "$c7")${MAGENTA}"
  fi
  quota_str="free: 5h ${five_str} / 7d ${week_str}"
else
  quota_str="free: n/a"
fi

SEP="${DIM} | ${RESET}"

out="${CYAN}${model_str}${RESET}"
[ -n "$agent_name" ] && out="${out}${SEP}${RED}🤖 ${agent_name}${RESET}"
out="${out}${SEP}${GREEN}${dir_str}${RESET}"
[ -n "$branch_str" ] && out="${out}${SEP}${BLUE}${branch_str}${RESET}"
out="${out}${SEP}${YELLOW}${ctx_str}${RESET}"
out="${out}${SEP}${MAGENTA}${quota_str}${RESET}"

# Second line: full current path in dim gray.
printf '%b\n' "$out"
printf '%b\n' "${DIM}${current_dir}${RESET}"
