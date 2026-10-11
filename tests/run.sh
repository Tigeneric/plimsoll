#!/usr/bin/env bash
# Runs statusline.sh against fixed input in a throwaway $HOME and checks what it
# prints, with colour codes and link brackets stripped and icon glyphs written
# as <U+XXXX>; then runs install.sh in throwaway homes. The status line runs
# under /bin/bash, the 3.2 a stock Mac starts it with.
# Usage: tests/run.sh [path/to/statusline.sh]
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
script=${1:-$repo/statusline.sh}
fails=0

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/Library/Fonts" "$home/conf6/ghostty" "$home/conf7/ghostty" "$home/.codex/sessions"
: > "$home/Library/Fonts/StatuslineIcons-6.otf"
echo 'font-codepoint-map = U+E900-U+E9A9=Statusline Icons 6' > "$home/conf6/ghostty/config"
echo 'font-codepoint-map = U+E900-U+E9A9=Statusline Icons 7' > "$home/conf7/ghostty/config"
# A Codex session log with 8% of its five-hour window used and 24% of the week.
far=$(( $(date +%s) + 86400 * 3 ))
printf '{"rate_limits":{"primary":{"used_percent":8,"resets_at":%d},"secondary":{"used_percent":24,"resets_at":%d}}}\n' \
  "$far" "$far" > "$home/.codex/sessions/rollout-test.jsonl"

input() {  # $1 context %, $2 five-hour %, $3 seconds to its reset, $4 weekly %
  printf '{"session_id":"t","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5.5"},"effort":{"level":"medium"},"context_window":{"used_percentage":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$home" "$1" "$2" "$(( $(date +%s) + $3 ))" "$4" "$far"
}

strip() { perl -CS -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\a]*\a//g; s/([\x{E900}-\x{E9FF}])/sprintf("<U+%04X>",ord $1)/ge'; }

# Each render gets a fresh, empty cache unless the caller names one with
# XDG_CACHE_HOME=...: the shared limits file would otherwise carry one fixture's
# readings into the next.
render() {  # input on stdin, env assignments as arguments; a nonzero exit is recorded
  local out status
  rm -rf "$home/cache-default"
  out=$(env -i PATH="$PATH" HOME="$home" XDG_CACHE_HOME="$home/cache-default" COLUMNS=0 "$@" /bin/bash "$script"); status=$?
  (( status == 0 )) || echo "exit $status" >> "$home/render-failures"
  printf '%s\n' "$out" | strip
}

status_of() {  # the status line's own exit status, not the pipeline's
  rm -rf "$home/cache-default"
  env -i PATH="$PATH" HOME="$home" XDG_CACHE_HOME="$home/cache-default" COLUMNS=0 "$@" /bin/bash "$script" >/dev/null 2>&1
  echo $?
}

check() {  # name, expected substring, actual line
  if [[ "$3" == *"$2"* ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "     expected: $2"; echo "     got:      $3"
    fails=$(( fails + 1 ))
  fi
}

check_absent() {  # name, text that must not appear, actual line
  if [[ "$3" != *"$2"* ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "     must not contain: $2"; echo "     got:              $3"
    fails=$(( fails + 1 ))
  fi
}

check_eq() {  # name, expected, actual; whole value, and never empty
  if [[ -n "$2" && "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "     expected: '$2'"; echo "     got:      '$3'"
    fails=$(( fails + 1 ))
  fi
}

ghostty=(GHOSTTY_RESOURCES_DIR=/x XDG_CONFIG_HOME="$home/conf6")
std=$(input 12 10 7200 40)

# Icons or names. 40% of the week used leaves 60: Opus is icon 1, so
# U+E910 + 0x20 + 60/4 = U+E93F. Codex, icon 4, 76% left: U+E990 + 19 = U+E9A3.
check "ghostty, font and config agree: icons"   "<U+E93F>  5.5 med"  "$(render "${ghostty[@]}" <<<"$std")"
check "ghostty: Codex icon at its weekly level" "<U+E9A3>  8%"       "$(render "${ghostty[@]}" <<<"$std")"
check "not ghostty: model name"                 "Opus 5.5 med"       "$(render XDG_CONFIG_HOME="$home/conf6" <<<"$std")"
check "not ghostty: Codex name"                 "Codex 8%"           "$(render XDG_CONFIG_HOME="$home/conf6" <<<"$std")"
check "config names a version not installed"    "Opus 5.5 med"       "$(render GHOSTTY_RESOURCES_DIR=/x XDG_CONFIG_HOME="$home/conf7" <<<"$std")"
check "STATUSLINE_ICONS=0 overrides"            "Opus 5.5 med"       "$(render "${ghostty[@]}" STATUSLINE_ICONS=0 <<<"$std")"
check "STATUSLINE_ICONS=1 overrides"            "<U+E93F>"           "$(render XDG_CONFIG_HOME="$home/conf6" STATUSLINE_ICONS=1 <<<"$std")"

# Bars: 8 cells, a cell lit as soon as any of it is used.
check "ctx 12% lights 1 of 8 cells"   "ctx ▰▱▱▱▱▱▱▱"  "$(render <<<"$(input 12 10 7200 40)")"
check "ctx 13% lights 2 of 8 cells"   "ctx ▰▰▱▱▱▱▱▱"  "$(render <<<"$(input 13 10 7200 40)")"
# 8100 s to the reset, not 7200: on the hour a second spent before the render
# turns "2h" into "1h30m", and the check flaked once in 20 runs.
# On the last cell the bar can no longer tell how much remains, so the share
# left follows it as a number, without the word.
check "5h 95%: all 8 cells, then 5% left" "2h ▰▰▰▰▰▰▰▰ 5% ·" "$(render <<<"$(input 12 95 8100 40)")"
check_absent "5h 95%: the number has no word after it" "left" "$(render <<<"$(input 12 95 8100 40)")"
check "ctx 12.5% lights exactly 1 cell" "ctx ▰▱▱▱▱▱▱▱" "$(render <<<"$(input 12.5 10 8100 40)")"
check "5h 87.5% lights exactly 7 cells, no number" "2h ▰▰▰▰▰▰▰▱ ·" "$(render <<<"$(input 12 87.5 8100 40)")"
check "ctx 0.5% lights 1 cell"        "ctx ▰▱▱▱▱▱▱▱" "$(render <<<"$(input 0.5 10 7200 40)")"
check "5h 87.6%: 8 cells, then 12% left" "2h ▰▰▰▰▰▰▰▰ 12% ·" "$(render <<<"$(input 12 87.6 8100 40)")"
check "ctx 125% is held to 8 cells"   "ctx ▰▰▰▰▰▰▰▰ ·" "$(render <<<"$(input 125 10 7200 40)")"
check "ctx -5% lights none"           "ctx ▱▱▱▱▱▱▱▱ ·" "$(render <<<"$(input -5 10 7200 40)")"

# Countdown to the five-hour reset, rounded down to a step that grows with it.
check "countdown 4h10m shows 4h"      "4h ▰"   "$(render <<<"$(input 12 10 15000 40)")"
check "countdown 1h50m shows 1h30m"   "1h30m ▰" "$(render <<<"$(input 12 10 6600 40)")"
check "countdown 22m shows 20m"       "20m ▰"  "$(render <<<"$(input 12 10 1330 40)")"
check "countdown 40s shows <1m"       "<1m ▰"  "$(render <<<"$(input 12 10 40 40)")"

# Odd input keeps the rest of the line.
family_only='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":30}}'
check_absent "family-only model name is not doubled" "Opus Opus" "$(render <<<"$family_only")"
check_absent "family-only model name, icons: the icon alone" "Opus" "$(render STATUSLINE_ICONS=1 <<<"$family_only")"
newline_dir='{"workspace":{"current_dir":"/tmp/a\nb"},"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":30}}'
check "newline in the path keeps the model" "Opus 5.5" "$(render <<<"$newline_dir")"
check "newline in the path keeps the context" "ctx ▰▰▰" "$(render <<<"$newline_dir")"
check_eq "no path, no session: no leading space" "Opus" "$(render <<<'{"model":{"display_name":"Opus 5.5"}}' | cut -c1-4)"
fast_text='{"model":{"display_name":"Opus 5.5"},"fast_mode":"x\u001f13","context_window":{"used_percentage":30}}'
check "fast_mode as text cannot shift the fields" "ctx ▰▰▰▱▱▱▱▱" "$(render <<<"$fast_text")"
huge_reset='{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":9223372036854775808}}}'
check_absent "a reset past any real date is not counted down" "2562047787517588h" "$(render <<<"$huge_reset")"
# CPU is shown whatever the session runs in, tmux included (nf-oct-cpu, U+F4BC).
check "CPU shown inside tmux" $'\xef\x92\xbc' "$(render TMUX=/tmp/tmux-1/default <<<"$std")"
check "CPU shown outside tmux" $'\xef\x92\xbc' "$(render <<<"$std")"
check_eq "exits 0" 0 "$(status_of <<<"$std")"
check_eq "exits 0 on input that is not JSON" 0 "$(status_of <<<'not json')"

# Git: the diff is shown for a detached HEAD and for a repository with no
# commit yet, which has a branch name but no HEAD to compare with.
g="$home/git"
git init -q "$g/fresh" && printf 'a\nb\nc\n' > "$g/fresh/f" && git -C "$g/fresh" add f
git init -q "$g/detached" && echo x > "$g/detached/f" && git -C "$g/detached" add f &&
  git -C "$g/detached" -c user.name=t -c user.email=t@t commit -qm init &&
  git -C "$g/detached" checkout -q --detach && echo y >> "$g/detached/f"
at() { printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5.5"}}' "$1"; }
check "no commit yet: staged lines counted" "+3/-0" "$(render <<<"$(at "$g/fresh")")"
check "detached HEAD: diff shown"           "+1/-0" "$(render <<<"$(at "$g/detached")")"
check "detached HEAD: commit shown as the branch" "⎇ @" "$(render <<<"$(at "$g/detached")")"
git init -q --object-format=sha256 "$g/sha256" && printf 'a\nb\n' > "$g/sha256/f" && git -C "$g/sha256" add f
check "sha256 repository, no commit yet: staged lines counted" "+2/-0" "$(render <<<"$(at "$g/sha256")")"
# A path with a control character is shown with "?", and git is not asked
# about it: the "?" spelling may be another directory, here a repository.
git init -q "$home/ctl?dir"
ctl_dir=$(printf '{"workspace":{"current_dir":"%s/ctl\\u0001dir"},"model":{"display_name":"Opus 5.5"}}' "$home")
check_absent "a control character in the path does not reach git" "⎇" "$(render <<<"$ctl_dir")"

# The shared limits file: every session merges its reading into it and renders
# from the result. Each case names its own cache, so one property is read per
# case. Stored readings are written by hand here, the way an earlier render of
# another session would have left them.
clock=$(date +%s)
R=$(( clock + 8100 ))     # a five-hour reset, 2h15m away
W=18000                   # a five-hour window; a newer one resets at least this much later
cache_n=0
new_cache() { cache_n=$(( cache_n + 1 )); cache="$home/cache-$cache_n"; limits="$cache/plimsoll/limits.json"; mkdir -p "$cache/plimsoll"; }
stored_five() {  # used %, resets_at, changed_at (default: just now); the weekly window is left empty
  printf '{"version":1,"claude":{"five_hour":{"used_percentage":%s,"resets_at":%s,"changed_at":%s}}}' "$1" "$2" "${3:-$clock}"
}
stdin_five() {  # used %, resets_at
  printf '{"session_id":"t","model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$2"
}
five_in_file() { jq -c '[.claude.five_hour.used_percentage, .claude.five_hour.resets_at]' "$limits" 2>&1; }
render_raw() { rm -rf "$home/cache-default"; env -i PATH="$PATH" HOME="$home" XDG_CACHE_HOME="${cache:-$home/cache-default}" COLUMNS=0 "$@" /bin/bash "$script" | perl -pe 's/\e\]8;;[^\a]*\a//g'; }   # colour kept, links cut
stderr_of() { env -i PATH="$PATH" HOME="$home" XDG_CACHE_HOME="$cache" COLUMNS=0 /bin/bash "$script" 2>&1 >/dev/null; }

new_cache; stored_five 60 "$R" > "$limits"
check "stale tab: the shared, higher five-hour reading is drawn" "▰▰▰▰▰▱▱▱" \
  "$(render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$(( R + 1 ))")")"

new_cache; stored_five 90 "$R" > "$limits"
check "new window: its lower reading is drawn" "▰▱▱▱▱▱▱▱ ·" \
  "$(render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 10 "$(( R + W ))")")"
new_cache; stored_five 90 "$R" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 10 "$(( R + W ))")" >/dev/null
check_eq "new window replaces an older window's higher reading" "[10,$(( R + W ))]" "$(five_in_file)"

new_cache; stored_five 10 "$(( R + W ))" > "$limits"
check "old window: the newer window's reading is drawn" "▰▱▱▱▱▱▱▱ ·" \
  "$(render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 90 "$R")")"
new_cache; stored_five 10 "$(( R + W ))" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 90 "$R")" >/dev/null
check_eq "an older window does not overwrite a newer one" "[10,$(( R + W ))]" "$(five_in_file)"

# Jitter between responses of one window was measured at up to 48 s in Codex's
# logs (the next gap is 780 s); the tolerance is 120 s.
new_cache; stored_five 60 "$R" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 30 "$(( R + 100 ))")" >/dev/null
check_eq "a reset 100 s later is the same window: the lower reading loses" "[60,$R]" "$(five_in_file)"
new_cache; stored_five 60 "$R" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 30 "$(( R + 200 ))")" >/dev/null
check_eq "a reset 200 s later is a new window: it replaces" "[30,$(( R + 200 ))]" "$(five_in_file)"
new_cache; stored_five 30 "$(( R + 100 ))" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 60 "$R")" >/dev/null
check_eq "a reset 100 s earlier is the same window: the higher reading wins" "[60,$R]" "$(five_in_file)"

new_cache; printf '{"version":1,"claude":{"seven_day":{"used_percentage":70,"resets_at":%s,"changed_at":%s}}}' "$(( clock + 400000 ))" "$clock" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(input 12 10 8100 40)" >/dev/null
check_eq "seven_day merges on its own: the higher reading is kept" "[70,$(( clock + 400000 ))]" \
  "$(jq -c '[.claude.seven_day.used_percentage, .claude.seven_day.resets_at]' "$limits" 2>&1)"
check_eq "five_hour merges on its own beside it" "10" "$(jq -c '.claude.five_hour.used_percentage' "$limits" 2>&1)"
new_cache; render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 125 "$R")" >/dev/null
check_eq "an out-of-range reading is stored held to 100" "100" "$(jq -c '.claude.five_hour.used_percentage' "$limits" 2>&1)"
# The set of windows is written in the script; each needs its own cases above.
new_cache; render XDG_CACHE_HOME="$cache" <<<"$(input 12 10 8100 40)" >/dev/null
check_eq "the file holds version 1 and exactly these windows" \
  "1 claude.five_hour claude.seven_day codex.primary codex.secondary" \
  "$(jq -r '"\(.version) " + ([paths(type == "object" and has("changed_at")) | join(".")] | join(" "))' "$limits" 2>&1)"

# The merge rule as a contract shared with other writers of the file
# (tests/contract/merge-cases.json), every case run through Claude's five-hour
# window. The guard comes first, so an empty case list cannot pass as coverage.
contract="$repo/tests/contract"
check_eq "the merge contract has its 13 cases" "13" "$(jq '.cases | length' "$contract/merge-cases.json" 2>&1)"
check_eq "the merge contract's tolerance is the script's" \
  "$(jq '.tolerance_seconds' "$contract/merge-cases.json" 2>&1)" "$(sed -n 's/.*def tol: \([0-9]*\);.*/\1/p' "$script")"
no_limits='{"session_id":"t","model":{"display_name":"Opus 5.5"}}'
while IFS= read -r c; do
  name=$(jq -r .name <<<"$c")
  new_cache; rm -f "$limits"
  jq -e '.stored != null' <<<"$c" >/dev/null &&
    jq -c '{version: 1, claude: {five_hour: {used_percentage: .stored.used, resets_at: .stored.resets_at, changed_at: 1790000000}}}' <<<"$c" > "$limits"
  if jq -e '.reading != null' <<<"$c" >/dev/null; then
    stdin=$(stdin_five "$(jq .reading.used <<<"$c")" "$(jq .reading.resets_at <<<"$c")")
  else
    stdin=$no_limits
  fi
  render XDG_CACHE_HOME="$cache" <<<"$stdin" >/dev/null
  check_eq "contract: $name" "$(jq -c '[.result.used, .result.resets_at]' <<<"$c")" "$(five_in_file)"
  changed=$(jq '.claude.five_hour.changed_at' "$limits" 2>&1)
  if [[ $(jq -r .winner <<<"$c") == stored ]]; then
    check_eq "contract: $name: changed_at kept" "1790000000" "$changed"
  else
    check_eq "contract: $name: changed_at is now" "now" "$( (( changed >= clock )) 2>/dev/null && echo now || echo "$changed")"
  fi
done < <(jq -c '.cases[]' "$contract/merge-cases.json")

# The antigravity section has no source in plimsoll: another writer (a poller
# that asks Antigravity's CLI) fills it, and plimsoll keeps it through its own
# writes, each window checked like the others. A reading of the same Claude
# window that is higher forces the write.
new_cache; cp "$contract/limits-file.json" "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 70 1800000000)" >/dev/null
check_eq "a write keeps the antigravity section as it was" \
  "$(jq -cS .antigravity "$contract/limits-file.json")" "$(jq -cS .antigravity "$limits" 2>&1)"
new_cache
printf '{"version":1,"antigravity":{"G":{"5h":{"used_percent":"x","resets_at":%s},"weekly":{"used_percent":140,"resets_at":%s,"changed_at":%s}},"H":5,"I":{"5h":null}}}' \
  "$R" "$R" "$clock" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$R")" >/dev/null
check_eq "an unusable antigravity window or group is dropped, a percentage held to 100" \
  "{\"G\":{\"weekly\":{\"changed_at\":$clock,\"resets_at\":$R,\"used_percent\":100}}}" "$(jq -cS .antigravity "$limits" 2>&1)"

# A file that cannot be used never breaks the line, and is repaired.
break_file() {  # kind
  case $1 in
    corrupt) printf '{"version":1,"claude":{"five_ho' > "$limits" ;;
    empty) : > "$limits" ;;
    version2) printf '{"version":2,"claude":{"five_hour":{"used_percentage":99,"resets_at":%s}}}' "$R" > "$limits" ;;
    binary) printf '\000\001\377{' > "$limits" ;;
  esac
}
for kind in corrupt empty version2 binary; do
  new_cache
  break_file $kind; err=$(stderr_of <<<"$(stdin_five 40 "$R")")
  check_eq "$kind file: nothing on stderr" "none" "${err:-none}"
  break_file $kind
  check_eq "$kind file: exits 0" "0" "$(status_of XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$R")")"
  break_file $kind
  check "$kind file: the stdin reading is drawn" "▰▰▰▰▱▱▱▱" "$(render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$R")")"
  check_eq "$kind file: repaired" "[40,$R]" "$(five_in_file)"
done
# Each Claude config directory is its own account with its own limits: one
# other than ~/.claude keeps its file in a subdirectory named after its path,
# with / and . turned into -.
new_cache; stored_five 90 "$R" > "$limits"
check "another config dir does not draw the default file's reading" "▰▱▱▱▱▱▱▱ ·" \
  "$(render XDG_CACHE_HOME="$cache" CLAUDE_CONFIG_DIR="$home/work.d" <<<"$(stdin_five 10 "$R")")"
new_cache; rm -f "$limits"
render XDG_CACHE_HOME="$cache" CLAUDE_CONFIG_DIR="$home/work.d" <<<"$(stdin_five 40 "$R")" >/dev/null
check_eq "another config dir leaves the default file alone" "absent" "$([[ -e "$limits" ]] && echo present || echo absent)"
check_eq "another config dir writes its own file" "[40,$R]" \
  "$(jq -c '[.claude.five_hour.used_percentage, .claude.five_hour.resets_at]' "$cache/plimsoll/${home//[\/.]/-}-work-d/limits.json" 2>&1)"
new_cache
render XDG_CACHE_HOME="$cache" CLAUDE_CONFIG_DIR="$home/.claude/" <<<"$(stdin_five 40 "$R")" >/dev/null
check_eq "CLAUDE_CONFIG_DIR=~/.claude/ uses the default file" "[40,$R]" "$(five_in_file)"
check_eq "a limits path that is a directory does not break the line" "0" \
  "$(mkdir -p "$home/cache-dir/plimsoll/limits.json"; status_of XDG_CACHE_HOME="$home/cache-dir" <<<"$(stdin_five 40 "$R")")"

# Nothing changed, nothing written: the inode and the mtime are read after the
# second render, while the first render's file is still the one on disk.
new_cache; stored_five 60 "$R" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$R")" >/dev/null     # first render normalises the file
touch -t 200101010000 "$limits"; before=$(stat -f '%i %m' "$limits" 2>&1)
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$R")" >/dev/null
check_eq "an unchanged merge does not rewrite the file" "$before" "$(stat -f '%i %m' "$limits" 2>&1)"
new_cache; stored_five 60 "$R" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 40 "$R")" >/dev/null
touch -t 200101010000 "$limits"; before=$(stat -f '%i %m' "$limits" 2>&1)
render XDG_CACHE_HOME="$cache" <<<"$(stdin_five 70 "$R")" >/dev/null
check_absent "a higher reading does rewrite it" "$before" "$(stat -f '%i %m' "$limits" 2>&1)"
check_eq "the cache directory is created when missing" "yes" \
  "$(rm -rf "$home/fresh-cache"; render XDG_CACHE_HOME="$home/fresh-cache" <<<"$(stdin_five 40 "$R")" >/dev/null; [[ -f $home/fresh-cache/plimsoll/limits.json ]] && echo yes || echo no)"
check_eq "XDG_CACHE_HOME unset: the file goes to ~/.cache" "yes" \
  "$(env -i PATH="$PATH" HOME="$home" COLUMNS=0 /bin/bash "$script" <<<"$(stdin_five 40 "$R")" >/dev/null 2>&1; [[ -f $home/.cache/plimsoll/limits.json ]] && echo yes || echo no)"
rm -rf "$home/.cache"

# Codex goes through the same merge. The log has 8% of the five-hour window
# and 24% of the week used, both resetting at $far.
stored_codex() {  # primary %, its resets_at, its changed_at
  printf '{"version":1,"codex":{"primary":{"used_percent":%s,"resets_at":%s,"changed_at":%s},"secondary":{"used_percent":24,"resets_at":%s,"changed_at":%s}}}' "$1" "$2" "$3" "$far" "$clock"
}
codex_in_file() { jq -c '[.codex.primary.used_percent, .codex.primary.resets_at]' "$limits" 2>&1; }
new_cache; stored_codex 50 "$far" "$clock" > "$limits"
check "codex: a higher shared reading in the same window is drawn" "Codex 50%" "$(render XDG_CACHE_HOME="$cache" <<<"$std")"
new_cache; stored_codex 50 "$(( far - W ))" "$clock" > "$limits"
check "codex: the log's newer window replaces an older one" "Codex 8%" "$(render XDG_CACHE_HOME="$cache" <<<"$std")"
new_cache; stored_codex 3 "$(( far + W ))" "$clock" > "$limits"
render XDG_CACHE_HOME="$cache" <<<"$std" >/dev/null
check_eq "codex: an older window does not overwrite a newer one" "[3,$(( far + W ))]" "$(codex_in_file)"
new_cache; render XDG_CACHE_HOME="$cache" <<<"$std" >/dev/null
check_eq "codex: the log's reading is stored" "[8,$far]" "$(codex_in_file)"
check_eq "codex secondary is stored too" "[24,$far]" "$(jq -c '[.codex.secondary.used_percent, .codex.secondary.resets_at]' "$limits" 2>&1)"
log_old() { touch -t "$(date -v-2H +%Y%m%d%H%M)" "$home/.codex/sessions/rollout-test.jsonl"; }   # over an hour, under a week
new_cache; stored_codex 8 "$far" "$(( clock - 7200 ))" > "$limits"; log_old
check "codex: dimmed when both the stored value and the log are over an hour old" "Codex"$'\e[2m 8%' "$(render_raw XDG_CACHE_HOME="$cache" <<<"$std")"
# A steady value keeps its old changed_at, but the log is rewritten after every
# real turn: that is a confirmation, and the reading is current.
touch "$home/.codex/sessions/rollout-test.jsonl"
new_cache; stored_codex 8 "$far" "$(( clock - 7200 ))" > "$limits"
check_absent "codex: not dimmed when the same value is in a fresh log" "Codex"$'\e[2m' "$(render_raw XDG_CACHE_HOME="$cache" <<<"$std")"
new_cache; stored_codex 8 "$far" "$(( clock - 10 ))" > "$limits"
log_old
check_absent "codex: not dimmed while the stored reading is fresh, whatever the log's age" "Codex"$'\e[2m' "$(render_raw XDG_CACHE_HOME="$cache" <<<"$std")"
new_cache
check "codex: a log read for the first time keeps its own age: dimmed" "Codex"$'\e[2m 8%' "$(render_raw XDG_CACHE_HOME="$cache" <<<"$std")"
touch "$home/.codex/sessions/rollout-test.jsonl"

# install.sh in throwaway homes: it must leave a user's settings as it found
# them unless it has something to add, and never half-install.
installer() {  # home, args...
  local h=$1; shift
  env -i PATH="$PATH" HOME="$h" /bin/bash "$repo/install.sh" "$@" >"$h/out" 2>&1
  echo $?
}
fresh_home() { local h="$home/inst-$1"; mkdir -p "$h/.claude"; echo "$h"; }

h=$(fresh_home symlink); mkdir -p "$h/dotfiles"; echo '{"model":"x"}' > "$h/dotfiles/settings.json"
ln -s "$h/dotfiles/settings.json" "$h/.claude/settings.json"; chmod 640 "$h/dotfiles/settings.json"
installer "$h" --no-font >/dev/null
check_eq "symlinked settings stay a symlink" "yes" "$([[ -L $h/.claude/settings.json ]] && echo yes || echo no)"
check "the symlink's target gets the setting" "statusline.sh" "$(cat "$h/dotfiles/settings.json")"
check_eq "symlinked settings: target keeps its mode" "640" "$(stat -f %Lp "$h/dotfiles/settings.json")"
h=$(fresh_home mode); echo '{"model":"x"}' > "$h/.claude/settings.json"; chmod 640 "$h/.claude/settings.json"
installer "$h" --no-font >/dev/null
check_eq "settings keep their mode" "640" "$(stat -f %Lp "$h/.claude/settings.json")"

# A write that fails half-way leaves the settings as they were: here jq fails
# when asked to rewrite them, after the checks have passed.
mkdir -p "$home/badjq"
printf '#!/bin/sh\ncase " $* " in *" --arg "*) echo "{\\"half" ; exit 5 ;; esac\nexec %s "$@"\n' "$(command -v jq)" > "$home/badjq/jq"
chmod +x "$home/badjq/jq"
h=$(fresh_home failed-write); echo '{"model":"x"}' > "$h/.claude/settings.json"
env -i PATH="$home/badjq:$PATH" HOME="$h" /bin/bash "$repo/install.sh" --no-font >/dev/null 2>&1
check_eq "a failed rewrite leaves the settings whole" '{"model":"x"}' "$(cat "$h/.claude/settings.json")"
# The same when the copy into place fails half-way (a full disk): a cat that
# writes five bytes and gives up. Writing through the settings with cat
# truncated them first and left those five bytes.
mkdir -p "$home/badcat"
printf '#!/bin/sh\nhead -c 5 "$1"\nexit 1\n' > "$home/badcat/cat"; chmod +x "$home/badcat/cat"
h=$(fresh_home failed-copy); echo '{"model":"x"}' > "$h/.claude/settings.json"
env -i PATH="$home/badcat:$PATH" HOME="$h" /bin/bash "$repo/install.sh" --no-font >/dev/null 2>&1
check_eq "a failed copy leaves the settings whole" "x" "$(jq -r .model "$h/.claude/settings.json" 2>&1)"

# A symlink whose target name ends in a newline: command substitution would
# drop it and the install would rewrite the neighbouring settings.json.
h=$(fresh_home newline-link); mkdir -p "$h/dotfiles"
echo '{"model":"x"}' > "$h/dotfiles/settings.json"$'\n'
echo '{"statusLine":{"type":"command","command":"mine"}}' > "$h/dotfiles/settings.json"
ln -s "$h/dotfiles/settings.json"$'\n' "$h/.claude/settings.json"
installer "$h" --no-font >/dev/null
check_eq "a link to a name ending in a newline: the neighbour is untouched" "mine" "$(jq -r .statusLine.command "$h/dotfiles/settings.json")"
check "a link to a name ending in a newline: its target gets the setting" "statusline.sh" "$(jq -r .statusLine.command "$h/dotfiles/settings.json"$'\n')"

h=$(fresh_home empty); : > "$h/.claude/settings.json"; echo old > "$h/.claude/statusline.sh"
check_eq "empty settings: install refuses" "1" "$(installer "$h" --no-font)"
check_eq "empty settings: script not replaced" "old" "$(cat "$h/.claude/statusline.sh")"
h=$(fresh_home broken); echo '{"a":' > "$h/.claude/settings.json"; echo old > "$h/.claude/statusline.sh"
check_eq "invalid settings: install refuses" "1" "$(installer "$h" --no-font)"
check_eq "invalid settings: script not replaced" "old" "$(cat "$h/.claude/statusline.sh")"

h=$(fresh_home spaced); mkdir -p "$h/my config"
env -i PATH="$PATH" HOME="$h" CLAUDE_CONFIG_DIR="$h/my config" /bin/bash "$repo/install.sh" --no-font >/dev/null 2>&1
check "a config dir with a space is quoted" 'my\ config/statusline.sh' "$(jq -r .statusLine.command "$h/my config/settings.json")"

# A fixed clock: both runs happen in "the same second" whatever the real one.
mkdir -p "$home/clock"; printf '#!/bin/sh\ncase "$1" in +%%Y*) echo 20261008-120000 ;; *) exec /bin/date "$@" ;; esac\n' > "$home/clock/date"
chmod +x "$home/clock/date"
h=$(fresh_home backups); echo first > "$h/.claude/statusline.sh"
env -i PATH="$home/clock:$PATH" HOME="$h" /bin/bash "$repo/install.sh" --no-font >/dev/null 2>&1
rm "$h/.claude/statusline.sh"; echo second > "$h/.claude/statusline.sh"
env -i PATH="$home/clock:$PATH" HOME="$h" /bin/bash "$repo/install.sh" --no-font >/dev/null 2>&1
check_eq "two backups in one second both kept" "first second" "$(cat "$h"/.claude/statusline.sh.bak-* | sort | tr '\n' ' ' | sed 's/ $//')"

h=$(fresh_home fonts); mkdir -p "$h/Library/Fonts"
version=$(sed -nE 's/^let family = "Statusline Icons ([0-9]+)"$/\1/p' "$repo/fonts/build.swift")
for v in $(( version - 1 )) "$version" $(( version + 1 )); do : > "$h/Library/Fonts/StatuslineIcons-$v.otf"; done
installer "$h" >/dev/null
check_eq "no font version is deleted" "$(( version - 1 )) $version $(( version + 1 ))" \
  "$(ls "$h/Library/Fonts" | sed -nE 's/^StatuslineIcons-([0-9]+)\.otf$/\1/p' | sort -n | tr '\n' ' ' | sed 's/ $//')"


# Right alignment counts characters, not bytes: with a Cyrillic path and the
# icons the line still ends 4 columns short of the terminal's width.
wide=$(printf '{"session_id":"t","workspace":{"current_dir":"/tmp/проект"},"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":30}}')
aligned=$(render COLUMNS=80 STATUSLINE_ICONS=1 <<<"$wide" | perl -CS -ne 'chomp; s/<U\+[0-9A-F]{4}>/X/g; print length')
check_eq "aligned line is the width less the margin" "76" "$aligned"

# After the last render, so that every fixture's exit status is in it.
render_failures=$(cat "$home/render-failures" 2>/dev/null)
check_eq "every rendered fixture exited 0" "none" "${render_failures:-none}"
# The code point layout is written twice: in build.swift's constants and in
# icon_glyph(). Both must say the same, or the script prints a glyph the font
# keeps for a different icon or level.
build=$repo/fonts/build.swift
layout_font=$(perl -ne 'print "$1 $2 $3 " if /^let levelBase = (0x\w+), levelStride = (0x\w+), levelStep = (\d+)$/;
                        print "$1 " if /^let wholeBase = (0x\w+)$/' "$build")
layout_sh=$(perl -ne 'print "$1 $2 $3 " if /cp=\$\(\( (0x\w+) \+ (0x\w+) \* \$1 \+ left \/ (\d+) \)\)/;
                      print "$1 " if /local cp=\$\(\( (0x\w+) \+ \$1 \)\)/' "$script")
order_font=$(perl -0777 -ne 'print join(" ", $1 =~ /\("(\w+)", "(?:tile|mark)"\)/g) if /^let icons[^=]*= \[(.*?)^\]/ms' "$build")
check "build.swift layout found"      "0xE900 0xE910 0x20 4"  "$layout_font"
check_eq "statusline.sh layout matches build.swift" "$layout_font" "$layout_sh"
check_eq "icon order: Fable, Opus, Sonnet, Haiku, Codex" "head cursor bubble bird codex" "$order_font"

echo
(( fails == 0 )) && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
