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

render() {  # input on stdin, env assignments as arguments; a nonzero exit is recorded
  local out status
  out=$(env -i PATH="$PATH" HOME="$home" COLUMNS=0 "$@" /bin/bash "$script"); status=$?
  (( status == 0 )) || echo "exit $status" >> "$home/render-failures"
  printf '%s\n' "$out" | strip
}

status_of() {  # the status line's own exit status, not the pipeline's
  env -i PATH="$PATH" HOME="$home" COLUMNS=0 "$@" /bin/bash "$script" >/dev/null 2>&1
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
