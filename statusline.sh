#!/usr/bin/env bash
# Claude Code statusline:
# model [effort] 💭 | 🤖 agent | project[/subdir] | 🌿 branch
#   | ctx: in/total (X%) | free: 5h X% (reset) $A / 7d Y% (reset) $B
# <full current path in dim gray>
#
# Columns are greedily wrapped across as many rows as needed to fit the
# terminal width ($COLUMNS, exported by Claude Code >= 2.1.153) so nothing is
# truncated in narrow panes (e.g. iTerm2 split panes). When the width isn't
# known we fall back to the original single row.

input=$(cat)

# Colors are stored as real ESC bytes (ANSI-C $'...') so we can both print them
# with `printf '%s'` and strip them when measuring on-screen column widths.
DIM=$'\033[2m'
RESET=$'\033[0m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
MAGENTA=$'\033[35m'
BLUE=$'\033[34m'
RED=$'\033[31m'
MONEY=$'\033[92m'

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

# Pick a runner for ccusage. A globally-installed `ccusage` binary is fastest;
# otherwise fall back to `bunx` (bun) or `npx` (node), which fetch it on demand.
# Whichever exists wins; with none of them the spend figures are just omitted.
COST_RUN=""
if command -v ccusage >/dev/null 2>&1; then
  COST_RUN="ccusage"
elif command -v bunx >/dev/null 2>&1; then
  COST_RUN="bunx ccusage"
elif command -v npx >/dev/null 2>&1; then
  COST_RUN="npx --yes ccusage"
fi

# Pick the platform's date/stat forms ONCE, from bash's built-in $OSTYPE — set
# at shell startup, so this runs no probe command at all, just a string match.
# The chosen helpers carry no fallback, so nothing is re-detected per call.
# macOS/BSD use `date -v` / `stat -f`; GNU/Linux use `date -d` / `stat -c`.
case "$OSTYPE" in
  darwin*|*bsd*)
    mtime()         { stat -f %m "$1" 2>/dev/null || echo 0; }
    date_days_ago() { date -v-"$1"d +%Y%m%d; }
    ;;
  *)
    mtime()         { stat -c %Y "$1" 2>/dev/null || echo 0; }
    date_days_ago() { date -d "$1 days ago" +%Y%m%d; }
    ;;
esac

refresh_costs() {
  local since b5 d7 tmp
  since=$(date_days_ago 6)
  b5=$($COST_RUN blocks --active --json --offline 2>/dev/null \
       | jq -r '[.blocks[]?|select(.isActive)|.costUSD]|add // empty')
  d7=$($COST_RUN daily --json --offline --since "$since" 2>/dev/null \
       | jq -r '.totals.totalCost // empty')
  if [ -n "${b5}${d7}" ]; then
    tmp=$(mktemp "${COST_CACHE}.XXXXXX") || return
    printf '%s %s\n' "${b5:-0}" "${d7:-0}" > "$tmp"
    mv -f "$tmp" "$COST_CACHE"
  fi
}
if [ -n "$COST_RUN" ]; then
  cnow=$(date +%s)
  stale=1
  if [ -f "$COST_CACHE" ]; then
    age=$(( cnow - $(mtime "$COST_CACHE") ))
    [ "$age" -lt "$COST_TTL" ] && stale=0
  fi
  if [ "$stale" = 1 ]; then
    # Clear a lock left behind by a crashed refresh.
    if [ -d "$COST_LOCK" ]; then
      lage=$(( cnow - $(mtime "$COST_LOCK") ))
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

SEP="${DIM} | ${RESET}"   # column separator (3 visible cells: " | ")
SEP_W=3

# Columns in display order. Empty ones are skipped so they leave no gap.
parts=()
parts+=("${CYAN}${model_str}${RESET}")
[ -n "$agent_name" ] && parts+=("${RED}🤖 ${agent_name}${RESET}")
parts+=("${GREEN}${dir_str}${RESET}")
[ -n "$branch_str" ] && parts+=("${BLUE}${branch_str}${RESET}")
parts+=("${YELLOW}${ctx_str}${RESET}")
parts+=("${MAGENTA}${quota_str}${RESET}")

# Terminal width. Claude Code >= 2.1.153 exports COLUMNS before invoking the
# statusline; tput/stty can't help here because our stdout is a pipe. When it's
# present we greedily pack columns into rows no wider than the terminal; when
# it's absent (older versions / non-tty) we emit the original single row.
cols="${COLUMNS:-}"
case "$cols" in ""|*[!0-9]*) cols=0 ;; esac

if [ "$cols" -gt 0 ]; then
  # On-screen width of each column in cells, ignoring color escapes and
  # counting CJK/emoji as 2. perl is precise across scripts; the bash fallback
  # covers ASCII plus the handful of emoji this statusline emits.
  widths=()
  if command -v perl >/dev/null 2>&1; then
    while IFS= read -r w; do widths+=("$w"); done < <(
      printf '%s\n' "${parts[@]}" | perl -CSDA -ne '
        chomp; s/\e\[[0-9;?]*[ -\/]*[@-~]//g;
        my $n = 0;
        for my $ch (split //) {
          my $o = ord $ch;
          next if $o == 0xFE0F || ($o >= 0x0300 && $o <= 0x036F);  # zero-width
          if ($o >= 0x1100 && ($o <= 0x115F
            || ($o >= 0x2E80 && $o <= 0xA4CF)
            || ($o >= 0xAC00 && $o <= 0xD7A3)
            || ($o >= 0xF900 && $o <= 0xFAFF)
            || ($o >= 0xFE30 && $o <= 0xFE4F)
            || ($o >= 0xFF00 && $o <= 0xFF60)
            || ($o >= 0xFFE0 && $o <= 0xFFE6)
            || ($o >= 0x2600 && $o <= 0x27BF)
            || ($o >= 0x1F000 && $o <= 0x1FAFF))) { $n += 2 }
          else { $n += 1 }
        }
        print "$n\n";
      '
    )
  else
    shopt -s extglob 2>/dev/null
    for p in "${parts[@]}"; do
      s="${p//$'\e'\[*([0-9;?])[a-zA-Z]/}"           # strip ANSI escapes
      t="${s//🤖/}"; t="${t//🌿/}"; t="${t//💭/}"
      widths+=( $(( ${#s} + ${#s} - ${#t} )) )       # +1 cell per wide emoji
    done
  fi

  # Greedily pack columns into rows, breaking before any column that would
  # overflow the current row.
  line=""; line_w=0; i=0
  for p in "${parts[@]}"; do
    pw=${widths[i]:-0}; i=$((i + 1))
    if [ -z "$line" ]; then
      line="$p"; line_w=$pw
    elif [ $((line_w + SEP_W + pw)) -le "$cols" ]; then
      line="${line}${SEP}${p}"; line_w=$((line_w + SEP_W + pw))
    else
      printf '%s\n' "$line"
      line="$p"; line_w=$pw
    fi
  done
  [ -n "$line" ] && printf '%s\n' "$line"
else
  out=""
  for p in "${parts[@]}"; do
    [ -z "$out" ] && out="$p" || out="${out}${SEP}${p}"
  done
  printf '%s\n' "$out"
fi

# Final line: the full current path, in the same green as the dir column above
# (its expanded form). Plain green, not faint — the old DIM (\033[2m) rendered
# near-invisible on many terminals.
printf '%s\n' "${GREEN}${current_dir}${RESET}"
