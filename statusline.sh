#!/usr/bin/env bash
# Claude Code statusline:
# model [effort] 💭 | 🤖 agent | project[/subdir] | 🌿 branch [⎇ worktree]
#   | ctx: in/total (X%) | 💰 $X.XX | quota: 5h X% / 7d Y%

input=$(cat)

DIM='\033[2m'
RESET='\033[0m'
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
MAGENTA='\033[35m'
BLUE='\033[34m'
RED='\033[31m'

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
project_name=$(basename "$project_dir")
if [ "$current_dir" = "$project_dir" ]; then
  dir_str="$project_name"
else
  case "$current_dir" in
    "$project_dir"/*) dir_str="$project_name/${current_dir#$project_dir/}" ;;
    *) dir_str="$(basename "$current_dir")" ;;
  esac
fi

# 4. Git branch
branch=$(git -C "$current_dir" branch --show-current 2>/dev/null)
if [ -n "$branch" ]; then
  if [ -n "$git_worktree" ]; then
    branch_str="🌿 ${branch} ⎇ ${git_worktree}"
  else
    branch_str="🌿 ${branch}"
  fi
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

# 6. Cost
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$cost" ]; then
  cost_str=$(printf '💰 $%.2f' "$cost")
else
  cost_str=""
fi

# 7. Quota
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
if [ -n "$five_pct" ] || [ -n "$week_pct" ]; then
  five_str="n/a"
  week_str="n/a"
  [ -n "$five_pct" ] && five_str=$(printf '%.0f%%' "$five_pct")
  [ -n "$week_pct" ] && week_str=$(printf '%.0f%%' "$week_pct")
  quota_str="quota: 5h ${five_str} / 7d ${week_str}"
else
  quota_str="quota: n/a"
fi

SEP="${DIM} | ${RESET}"

out="${CYAN}${model_str}${RESET}"
[ -n "$agent_name" ] && out="${out}${SEP}${RED}🤖 ${agent_name}${RESET}"
out="${out}${SEP}${GREEN}${dir_str}${RESET}"
[ -n "$branch_str" ] && out="${out}${SEP}${BLUE}${branch_str}${RESET}"
out="${out}${SEP}${YELLOW}${ctx_str}${RESET}"
[ -n "$cost_str" ] && out="${out}${SEP}${YELLOW}${cost_str}${RESET}"
out="${out}${SEP}${MAGENTA}${quota_str}${RESET}"

printf '%b\n' "$out"
