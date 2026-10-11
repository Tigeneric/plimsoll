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

now=$(date +%s)

# Codex writes rate_limits into its session log after every turn, so the newest
# log holds its latest reading; logs older than a week are not looked at. The
# reading is only an input to the merge below. Sets cx_pu/cx_pr (five-hour used
# %, reset), cx_su/cx_sr (weekly) and cx_seen (when the log was written); all
# stay empty without a reading.
cx_pu="" cx_pr="" cx_su="" cx_sr="" cx_seen=""
codex_scan() {
  local logs=() f tail_ primary="" secondary="" num='"used_percent":([0-9]+(\.[0-9]+)?)' at='"resets_at":([0-9]+)'
  while IFS= read -r f; do logs+=("$f"); done < <(
    find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -mtime -7 2>/dev/null)
  (( ${#logs[@]} )) || return 1
  # A session that has not finished a turn yet has no reading; try a few more.
  while IFS= read -r f; do
    tail_=$(tail -c 262144 "$f")
    primary=$(grep -o '"primary":{[^}]*}' <<<"$tail_" | tail -1)
    [[ -n "$primary" ]] && break
  done < <(ls -t "${logs[@]}" | head -5)
  [[ "$primary" =~ $num ]] || return 1
  cx_pu=${BASH_REMATCH[1]}
  [[ "$primary" =~ $at ]] && cx_pr=${BASH_REMATCH[1]}
  secondary=$(grep -o '"secondary":{[^}]*}' <<<"$tail_" | tail -1)
  [[ "$secondary" =~ $num ]] && cx_su=${BASH_REMATCH[1]}
  [[ "$secondary" =~ $at ]] && cx_sr=${BASH_REMATCH[1]}
  cx_seen=$(stat -f %m "$f")
}
codex_scan

# The shared limits file, ${XDG_CACHE_HOME:-~/.cache}/plimsoll/limits.json.
# Every session's stdin carries only the limits from its own last API response,
# so an idle tab shows an old reading while others have newer ones. Each session
# merges its reading (Claude's from stdin, Codex's from the log above) into the
# file, window by window, and draws from the merge. No clock orders the
# readings: a reading whose resets_at is later than the stored one by more than
# TOL seconds belongs to a newer window and wins; within TOL it is the same
# window (the reset time jitters by up to ~50 s between responses, measured in
# Codex's logs) and the higher percentage wins, since usage within a window only
# grows. Format (version 1), one object per window, each source keeping its own
# field name:
#   {"version":1,
#    "claude":{"five_hour":{"used_percentage":N,"resets_at":EPOCH,"changed_at":EPOCH},"seven_day":{...}},
#    "codex":{"primary":{"used_percent":N,"resets_at":EPOCH,"changed_at":EPOCH},"secondary":{...}},
#    "antigravity":{"<quota group>":{"5h":{"used_percent":N,...},"weekly":{...}},...}}
# The antigravity section is written by another program that polls Antigravity's
# CLI; plimsoll only keeps it. The cases in tests/contract/ are the rule's
# contract with such writers.
# changed_at is when the stored value of that window last changed, not when it
# was last confirmed: a stale tab replaying an equal value cannot be told from a
# fresh confirmation. (A Codex reading new to the file is stamped with the log's
# own mtime, so a day-old log is not made fresh by being read now.) The file is
# written only when the merge differs from it, to a temporary file in the same
# directory, then renamed over it. There is no lock: the merge is monotonic, so
# an update lost between two concurrent writers comes back with the next render.
# A missing, empty, corrupt or other-version file counts as empty and is
# overwritten. A CLAUDE_CONFIG_DIR other than ~/.claude is another account with
# its own limits, so it gets its own file, in a subdirectory named after its
# path with / and . turned into - (~/.claude-work: plimsoll/-Users-me--claude-work/).
limits_dir="${XDG_CACHE_HOME:-$HOME/.cache}/plimsoll"
config_dir=${CLAUDE_CONFIG_DIR%%+(/)}
[[ -n "$config_dir" && "$config_dir" != "$HOME/.claude" ]] && limits_dir+="/${config_dir//[\/.]/-}"
limits_file="$limits_dir/limits.json"
shared=""
[[ -f "$limits_file" ]] && { shared=$(<"$limits_file"); } 2>/dev/null

# Fields are joined with \x1f, not tabs: read collapses runs of a whitespace
# IFS, so an empty field (a model with no effort level) would shift the rest.
# Control characters in text become "?": a newline would end the read early
# and \x1f would shift the fields. A path that had one is shown but not given
# to git, since its "?" spelling may name another directory. Percentages
# arrive in tenths, 0 to 1000, rounded up once: the bars count cells from
# them, so 12.5% is exactly one cell and 12.6% starts the second. Timestamps
# are whole seconds within a real range. Anything else becomes empty, and its
# segment is left out. The limits come out merged with the shared file; the
# last two fields are whether to write it and what.
IFS=$'\x1f' read -r session_id dir dir_ok model effort fast ctx limit5h reset5h limit7d reset7d cx_pct cx_week cx_changed write_limits limits_json < <(
  jq -r --argjson now "$now" --arg shared "$shared" \
    --arg cpu "$cx_pu" --arg cpr "$cx_pr" --arg csu "$cx_su" --arg csr "$cx_sr" --arg cseen "$cx_seen" '
    def text: tostring | gsub("[\\x00-\\x1f\\x7f]"; "?");
    def tenths: if type == "number" then . * 10 | ceil | if . < 0 then 0 elif . > 1000 then 1000 else . end | tostring else "" end;
    def stamp: if type == "number" and . >= 0 and . < 100000000000 then floor | tostring else "" end;
    # The merge. A reading is {u: used %, r: resets_at, c: changed_at}.
    def tol: 120;
    def pct: if type == "number" then (if . < 0 then 0 elif . > 100 then 100 else . end) else null end;
    def secs: if type == "number" and . >= 0 and . < 100000000000 then floor else null end;
    def reading: if .u == null then null else . end;
    def stored($k): if type == "object" then {u: (.[$k] | pct), r: (.resets_at | secs), c: (.changed_at | secs)} | reading else null end;
    def merge($old; $new):
      if $new == null then $old elif $old == null then $new
      else ($old.r // 0) as $or | ($new.r // 0) as $nr |
        if $nr > $or + tol then $new
        elif $or > $nr + tol then $old
        elif $new.u > $old.u then $new
        else $old end
      end
      | if . != null and .c == null then .c = $now else . end;
    def window($k): if . == null then null else ({($k): .u, resets_at: .r, changed_at: .c} | with_entries(select(.value != null))) end;
    def claude($w): try (.rate_limits[$w] | {u: (.used_percentage | pct), r: (.resets_at | secs), c: $now} | reading) catch null;
    def codex($u; $r): ($u | if . == "" then null else tonumber | pct end) as $u |
      if $u == null then null else {u: $u, r: ($r | if . == "" then null else tonumber | secs end), c: ([$now, ($cseen | if . == "" then $now else tonumber end)] | min)} end;
    def tenth: if . == null then "" else .u * 10 | ceil | tostring end;
    def codex_used: if . == null then "" else (if .r != null and .r <= $now then 0 else .u | floor end | tostring) end;
    (.workspace.current_dir // .cwd // "" | tostring) as $dir |
    (try ($shared | fromjson | if type == "object" and .version == 1 then . else null end) catch null) as $s |
    (try $s.claude.five_hour catch null | stored("used_percentage")) as $s5 |
    (try $s.claude.seven_day catch null | stored("used_percentage")) as $s7 |
    (try $s.codex.primary catch null | stored("used_percent")) as $sp |
    (try $s.codex.secondary catch null | stored("used_percent")) as $ss |
    merge($s5; claude("five_hour")) as $m5 |
    merge($s7; claude("seven_day")) as $m7 |
    merge($sp; codex($cpu; $cpr)) as $mp |
    merge($ss; codex($csu; $csr)) as $ms |
    # Antigravity has no reading here; another writer fills its section and
    # plimsoll keeps it, each window cleaned like the ones above.
    (try ($s.antigravity | if type == "object" then
        with_entries(.value |= (if type == "object" then
          ({"5h": (try .["5h"] catch null | stored("used_percent") | window("used_percent")),
            weekly: (try .weekly catch null | stored("used_percent") | window("used_percent"))}
           | with_entries(select(.value != null)))
        else {} end) | select(.value | length > 0))
      else {} end) catch {}) as $agy |
    ({version: 1}
      + (({five_hour: ($m5 | window("used_percentage")), seven_day: ($m7 | window("used_percentage"))} | with_entries(select(.value != null))) | if length > 0 then {claude: .} else {} end)
      + (({primary: ($mp | window("used_percent")), secondary: ($ms | window("used_percent"))} | with_entries(select(.value != null))) | if length > 0 then {codex: .} else {} end)
      + (if ($agy | length) > 0 then {antigravity: $agy} else {} end)
    ) as $out |
    [
    (.session_id // "" | text),
    ($dir | text),
    (if $dir | test("[\\x00-\\x1f\\x7f]") then "" else "1" end),
    (.model.display_name // "" | text | sub(" *\\(.*\\)$"; "")),
    (.effort.level // "" | text),
    (.fast_mode == true | tostring),
    (.context_window.used_percentage | tenths),
    ($m5 | tenth),
    ($m5 | if . == null or .r == null then "" else .r | tostring end),
    ($m7 | tenth),
    ($m7 | if . == null or .r == null then "" else .r | tostring end),
    ($mp | codex_used),
    ($ms | codex_used),
    ($mp | if . == null then "" else .c | tostring end),
    (if $out != $s and ($out | length) > 1 then "1" else "" end),
    ($out | tojson)
  ] | join("\u001f")' <<<"$input" 2>/dev/null
)

# Write the merge back if it differs from the file, atomically.
if [[ -n "$write_limits" ]]; then
  {
    mkdir -p "$limits_dir" &&
      tmp=$(mktemp "$limits_dir/limits.XXXXXX") &&
      { printf '%s\n' "$limits_json" > "$tmp" && mv -f "$tmp" "$limits_file"; } || rm -f "$tmp"
  } 2>/dev/null
fi

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
# used. Without a reading the group is left out. Nothing refreshes the reading
# between Codex turns: a window whose reset has passed counts as empty (above),
# and a reading neither changed nor confirmed by a Codex turn for over an hour is dimmed.
codex_limit() {
  [[ "$cx_pct" =~ ^[0-9]+$ ]] || return 1
  local pct=$cx_pct week_left="" mark
  [[ "$cx_week" =~ ^[0-9]+$ ]] && week_left=$(( 100 - cx_week ))
  if [[ -n "$icons" ]]; then
    mark=$(link "$CODEX_USAGE_URL" $'\e[38;2;122;157;255m'"$(icon_glyph 4 "$week_left") ${reset}")
  else
    mark=$(link "$CODEX_USAGE_URL" Codex)
  fi
  # Fresh as of the later of the stored value's last change and the log's last
  # write: Codex writes the log only after a real turn, so a steady value in a
  # recently written log is current although its changed_at is old.
  local fresh=$cx_changed
  [[ "$cx_seen" =~ ^[0-9]+$ ]] && (( cx_seen > ${fresh:-0} )) && fresh=$cx_seen
  if [[ "$fresh" =~ ^[0-9]+$ ]] && (( now - fresh > 3600 )); then
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
