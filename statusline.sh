#!/usr/bin/env bash
# Claude Code status line:
#   ● ~/path ⎇ branch +12/-3              Opus 5.5 high · ctx 34% ·  25G ·  47%
#
# The dot's colour is hashed from session_id, so two sessions in the same
# project tell apart at a glance. The session's name is not repeated here:
# Claude Code already draws it on the prompt's top border. Model, context, free
# SSD and CPU sit at the right edge. The disk and CPU icons are Nerd Font glyphs
# (nf-fa-hdd, nf-oct-cpu): one cell wide, and Ghostty draws them from its
# built-in symbol font even when no Nerd Font is installed.

# extglob for visible_width's patterns; it has to be on before they are parsed.
shopt -s extglob

input=$(cat)

# Fields are joined with \x1f, not tabs: read collapses runs of a whitespace
# IFS, so an empty field (a model with no effort level) would shift the rest.
# Control characters in text become "?": a newline would end the read early
# and \x1f would shift the fields. A path that had one is shown but not given
# to git, since its "?" spelling may name another directory. Percentages
# arrive in tenths, 0 to 1000, rounded up once: the bars count cells from
# them, so 12.5% is exactly one cell and 12.6% starts the second. Timestamps
# are whole seconds within a real range. Anything else becomes empty, and its
# segment is left out.
IFS=$'\x1f' read -r session_id dir dir_ok model effort fast ctx limit5h reset5h limit7d reset7d < <(
  jq -r 'def text: tostring | gsub("[\\x00-\\x1f\\x7f]"; "?");
    def tenths: if type == "number" then . * 10 | ceil | if . < 0 then 0 elif . > 1000 then 1000 else . end | tostring else "" end;
    def stamp: if type == "number" and . >= 0 and . < 100000000000 then floor | tostring else "" end;
    (.workspace.current_dir // .cwd // "" | tostring) as $dir |
    [
    (.session_id // "" | text),
    ($dir | text),
    (if $dir | test("[\\x00-\\x1f\\x7f]") then "" else "1" end),
    (.model.display_name // "" | text | sub(" *\\(.*\\)$"; "")),
    (.effort.level // "" | text),
    (.fast_mode == true | tostring),
    (.context_window.used_percentage | tenths),
    (.rate_limits.five_hour.used_percentage | tenths),
    (.rate_limits.five_hour.resets_at | stamp),
    (.rate_limits.seven_day.used_percentage | tenths),
    (.rate_limits.seven_day.resets_at | stamp)
  ] | join("\u001f")' <<<"$input" 2>/dev/null
)

reset=$'\e[0m'; dim=$'\e[2m'
green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; magenta=$'\e[35m'; blue=$'\e[34m'; cyan=$'\e[36m'
sep=" ${dim}·${reset} "

parts=()

# Session marker: a stable colour per session from a palette of distinct
# 256-colour indices.
if [[ -n "$session_id" ]]; then
  palette=(39 208 170 76 220 141 45 203 114 179 99 37)
  hash=$(printf '%s' "$session_id" | cksum | cut -d' ' -f1)
  colour=${palette[hash % ${#palette[@]}]}
  marker=$'\e[38;5;'"${colour}m●${reset}"
fi

# Path, branch and uncommitted diff. --no-optional-locks keeps this read-only
# poll from taking the index lock out from under a concurrent git command.
# symbolic-ref tells the three states apart in one call: a branch (0, also
# with no commit yet), a detached HEAD (1, shown as @<commit>), not a
# repository (128). A repository with no commit has no HEAD to compare with,
# so its changes are counted against the empty tree, whose name depends on
# the repository's hash.
git_q() { git -C "$dir" --no-optional-locks "$@" 2>/dev/null; }
if [[ -n "$dir" ]]; then
  location="${green}${dir/#$HOME/~}${reset}"
  state=128
  [[ -n "$dir_ok" ]] && { branch=$(git_q symbolic-ref -q --short HEAD); state=$?; }
  if (( state == 0 || state == 1 )); then
    base=$(git_q hash-object -t tree /dev/null)   # the empty tree, SHA-1 or SHA-256
    if head=$(git_q rev-parse -q --verify --short HEAD); then
      base=HEAD
      [[ -n "$branch" ]] || branch="@$head"
    fi
    [[ -n "$branch" ]] && location+=" ${yellow}⎇ ${branch}${reset}"
    read -r added removed < <(
      git_q diff --numstat "$base" | awk '{ a += $1; d += $2 } END { print a + 0, d + 0 }'
    )
    (( added + removed > 0 )) && location+=" ${magenta}+${added}/-${removed}${reset}"
  fi
  parts+=("$location")
fi

# Everything below goes to the right-hand group.
right_parts=()

# Icons come from our own font (fonts/build.swift in this repository, mapped in the
# Ghostty config), drawn two cells wide over the space that follows. Index 0-3
# is Fable, Opus, Sonnet, Haiku, 4 is Codex. Whole at U+E900 + index; with a
# percentage left, the glyph shows it as a fill level from the bottom, in 4%
# steps (the screen's resolution), at U+E910 + 0x20 * index + left / 4.
icon_glyph() {
  local cp=$(( 0xE900 + $1 ))
  if [[ "$2" =~ ^-?[0-9]+$ ]]; then
    local left=$2
    (( left > 100 )) && left=100
    (( left < 0 )) && left=0
    cp=$(( 0xE910 + 0x20 * $1 + left / 4 ))
  fi
  printf "\\xee\\x$(printf %02x $(( 0x80 | (cp >> 6 & 0x3f) )))\\x$(printf %02x $(( 0x80 | (cp & 0x3f) )))"
}

# The icons need the font installed and the terminal told to draw U+E900-E9A9
# from it; a terminal that is not draws empty boxes there. Only Ghostty (and
# cmux, built on it) is set up for that, so anywhere else, or with no font file
# of the version the Ghostty config names, the names are printed instead: Opus,
# Codex. STATUSLINE_ICONS=1 or 0 overrides the check.
icons_available() {
  case $STATUSLINE_ICONS in 1) return 0 ;; 0) return 1 ;; esac
  [[ -n "$GHOSTTY_RESOURCES_DIR" ]] || return 1
  local conf version="" dir
  for conf in "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config" \
              "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
              "$HOME/Library/Application Support/com.mitchellh.ghostty/config"; do
    [[ -r "$conf" ]] || continue
    version=$(sed -nE 's/^[[:space:]]*font-codepoint-map[[:space:]]*=[[:space:]]*U\+E900-[^=]*=[[:space:]]*Statusline Icons ([0-9]+)[[:space:]]*$/\1/p' "$conf" | tail -1)
    [[ -n "$version" ]] && break
  done
  [[ -n "$version" ]] || return 1
  for dir in "$HOME/Library/Fonts" /Library/Fonts; do
    [[ -f "$dir/StatuslineIcons-$version.otf" ]] && return 0
  done
  return 1
}
icons_available && icons=1 || icons=""

# An OSC 8 hyperlink around $2 to $1. Terminated with BEL, not ST: Claude Code's
# status line passes BEL-terminated links through, and has been reported to
# drop ST-terminated ones. In cmux a plain click opens it in the built-in browser.
link() { printf '\e]8;;%s\a%s\e]8;;\a' "$1" "$2"; }
CLAUDE_USAGE_URL=https://claude.ai/settings/usage
CODEX_USAGE_URL="https://chatgpt.com/settings/usage?tab=overview"

# Subscription limits: present only on Pro/Max and only after the first
# response. A reset already past means the window is empty again.
now=$(date +%s)
[[ "$limit5h" =~ ^[0-9]+$ && "$reset5h" =~ ^[0-9]+$ ]] && (( reset5h <= now )) && limit5h=0
[[ "$limit7d" =~ ^[0-9]+$ && "$reset7d" =~ ^[0-9]+$ ]] && (( reset7d <= now )) && limit7d=0

# Model with its effort level (medium shortened to fit) and ⚡ in fast mode.
# The family name becomes its icon from Anthropic's model docs, a rounded tile in
# the family's colour with the icon cut out of it. The tile is filled to what is
# left of the weekly limit; the spent part shows as its outline. Without the
# limit (API keys, before the first response) the tile is whole. An unknown
# family keeps its name; without the icons every family does, as a link.
model_icon() {
  local index tile left=""
  case $1 in
    Fable)  index=0 tile='123;164;230' ;;
    Opus)   index=1 tile='224;155;121' ;;
    Sonnet) index=2 tile='239;235;227' ;;
    Haiku)  index=3 tile='196;211;203' ;;
    *) return 1 ;;
  esac
  [[ -n "$icons" ]] || { link "$CLAUDE_USAGE_URL" "$1"; return; }
  [[ "$limit7d" =~ ^[0-9]+$ ]] && left=$(( (1000 - limit7d) / 10 ))
  link "$CLAUDE_USAGE_URL" "$(printf '\e[38;2;%sm%s \e[0m' "$tile" "$(icon_glyph "$index" "$left")")"
}
if [[ -n "$model" ]]; then
  family=${model%% *}
  rest=${model#"$family"}; rest=${rest# }   # empty for a name that is the family alone
  icon=$(model_icon "$family") && model="${icon}${rest:+ $rest}"
  [[ "$effort" == medium ]] && effort=med
  [[ -n "$effort" ]] && model+=" ${cyan}${effort}${reset}"
  [[ "$fast" == true ]] && model+=" ${yellow}⚡${reset}"
  right_parts+=("$model")
fi

# A bar of BAR_CELLS cells, each worth 100 / BAR_CELLS = 12.5 percent. A cell
# fills as soon as any of it is used, so an empty cell is always a whole one
# still free, and the last cell lights up once less than one cell is left.
BAR_CELLS=8
bar() {
  local filled=$(( ($1 * BAR_CELLS + 999) / 1000 ))   # $1 in tenths of a percent
  local full="" empty=""
  for (( i = 0; i < filled; i++ )); do full+="▰"; done
  for (( i = filled; i < BAR_CELLS; i++ )); do empty+="▱"; done
  printf '%s%s' "$full" "${dim}${empty}${reset}"
}

# Time left to a reset, coarser the further away it is: whole hours from 3h,
# then 30-minute steps, 15 from 1h, 5 from 30m and single minutes under 15m.
# Rounded down, so the value shown has always been reached.
time_left() {
  # Seconds first: bash divides towards zero, so a reset a few seconds past
  # would come out as 0 minutes and print "<1m".
  local s=$(( $1 - $(date +%s) )) m step
  (( s <= 0 )) && return 1
  m=$(( s / 60 ))
  if   (( m >= 180 )); then step=60
  elif (( m >= 60 ));  then step=30
  elif (( m >= 30 ));  then step=15
  elif (( m >= 15 ));  then step=5
  else step=1
  fi
  m=$(( m / step * step ))
  local h=$(( m / 60 )) mm=$(( m % 60 ))
  if (( m == 0 )); then printf '<1m'
  elif (( h == 0 )); then printf '%dm' "$mm"
  elif (( mm == 0 )); then printf '%dh' "$h"
  else printf '%dh%02dm' "$h" "$mm"
  fi
}

# Context window: bar only, coloured as before. Absent until the first response.
if [[ "$ctx" =~ ^[0-9]+$ ]]; then
  if (( ctx >= 800 )); then ctx_colour=$red
  elif (( ctx >= 500 )); then ctx_colour=$yellow
  else ctx_colour=$green
  fi
  right_parts+=("${ctx_colour}ctx $(bar "$ctx")${reset}")
fi

# Five-hour limit: the time to its reset, then the bar; plain until 70%. Once
# the last cell is lit the bar can no longer tell how much remains, so the
# share left follows it as a number, rounded down. The weekly limit is the
# model tile's fill level (above).
if [[ "$limit5h" =~ ^[0-9]+$ ]]; then
  if (( limit5h >= 900 )); then lim_colour=$red
  elif (( limit5h >= 700 )); then lim_colour=$yellow
  else lim_colour=""
  fi
  # The countdown labels the bar; without a reset time it falls back to "5h".
  label=5h
  [[ "$reset5h" =~ ^[0-9]+$ ]] && countdown=$(time_left "$reset5h") && label=$countdown
  segment="${lim_colour}${label} $(bar "$limit5h")${lim_colour}"
  (( (limit5h * BAR_CELLS + 999) / 1000 >= BAR_CELLS )) && segment+=" $(( (1000 - limit5h) / 10 ))%"
  right_parts+=("${segment}${reset}")
fi

# Codex's limits, for when it works alongside: its mark, filled to what is left
# of its weekly limit like the model tile, and the share of its five-hour window
# used. Codex writes rate_limits into its session log after every turn, so the
# newest log holds the latest reading; logs older than a week are not looked at,
# and without one the group is left out. Nothing refreshes the reading between
# Codex turns: a window whose reset has passed counts as empty, and a reading
# over an hour old is dimmed.
codex_window_used() {   # a primary/secondary object -> % used, 0 once its reset has passed
  [[ "$1" =~ \"used_percent\":([0-9]+) ]] || return 1
  local used=${BASH_REMATCH[1]}
  [[ "$1" =~ \"resets_at\":([0-9]+) ]] && (( BASH_REMATCH[1] <= now )) && used=0
  printf '%s' "$used"
}
codex_limit() {
  local logs=() f tail_ primary="" secondary="" pct week_used week_left=""
  while IFS= read -r f; do logs+=("$f"); done < <(
    find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -mtime -7 2>/dev/null)
  (( ${#logs[@]} )) || return 1
  # A session that has not finished a turn yet has no reading; try a few more.
  while IFS= read -r f; do
    tail_=$(tail -c 262144 "$f")
    primary=$(grep -o '"primary":{[^}]*}' <<<"$tail_" | tail -1)
    [[ -n "$primary" ]] && break
  done < <(ls -t "${logs[@]}" | head -5)
  pct=$(codex_window_used "$primary") || return 1
  secondary=$(grep -o '"secondary":{[^}]*}' <<<"$tail_" | tail -1)
  week_used=$(codex_window_used "$secondary") && week_left=$(( 100 - week_used ))
  local mark
  if [[ -n "$icons" ]]; then
    mark=$(link "$CODEX_USAGE_URL" $'\e[38;2;122;157;255m'"$(icon_glyph 4 "$week_left") ${reset}")
  else
    mark=$(link "$CODEX_USAGE_URL" Codex)
  fi
  if (( now - $(stat -f %m "$f") > 3600 )); then
    printf '%s' "${dim}${mark}${dim} ${pct}%${reset}"
    return
  fi
  local colour=""
  if (( pct >= 90 )); then colour=$red
  elif (( pct >= 70 )); then colour=$yellow
  fi
  printf '%s' "${mark} ${colour}${pct}%${colour:+$reset}"
}
codex=$(codex_limit) && right_parts+=("$codex")

join() {
  local out="" part
  for part in "$@"; do out+="${out:+$sep}$part"; done
  printf '%s' "$out"
}

# Free SSD space. APFS volumes share their container's free space, so the home volume speaks for all.
free_gb=$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
if [[ "$free_gb" =~ ^[0-9]+$ ]]; then
  if (( free_gb < 10 )); then ssd_colour=$red
  elif (( free_gb < 25 )); then ssd_colour=$yellow
  else ssd_colour=""
  fi
  right_parts+=("${ssd_colour} ${free_gb}G${ssd_colour:+$reset}")
fi

# CPU: the load summed over processes, divided by the number of cores.
cpu=$(ps -A -o %cpu= | awk -v n="$(sysctl -n hw.ncpu)" '{ s += $1 } END { printf "%d", s / n }')
right_parts+=("${blue} ${cpu}%${reset}")

line="${marker:+$marker }$(join "${parts[@]}")"
right=$(join "${right_parts[@]}")

# The right group goes to the right edge. Claude Code passes the terminal width
# in COLUMNS; without it, or when the line is too long to pad, the right group
# just follows a separator.
if [[ -n "$right" ]]; then
  # Visible width: colour codes and hyperlink brackets stripped, counted in
  # characters, not bytes.
  # In bash itself, two runs a refresh: colour codes and link brackets are cut
  # with extglob patterns, and ${#} counts characters under a UTF-8 locale set
  # here, whatever locale Claude Code passes (or none). Empty text prints 0.
  visible_width() {
    local LC_ALL=en_US.UTF-8
    local s=${1//$'\e['*([0-9;])m/}
    s=${s//$'\e]8;;'*([^$'\a'])$'\a'/}
    printf '%s' "${#s}"
  }
  margin=4  # Claude Code indents its footer rows; leave room so the group is never wrapped.
  pad=$(( ${COLUMNS:-0} - margin - $(visible_width "$line") - $(visible_width "$right") ))
  if (( pad >= 2 )); then
    line+="$(printf '%*s' "$pad" '')$right"
  else
    line+="${line:+$sep}$right"
  fi
fi

printf '%s\n' "$line"
