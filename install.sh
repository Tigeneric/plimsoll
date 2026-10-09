#!/usr/bin/env bash
# Installs the status line for Claude Code on this Mac:
#   1. links ~/.claude/statusline.sh to this repository's statusline.sh;
#   2. points Claude Code's statusLine setting at it, unless one is already set;
#   3. builds the icon font and installs it as ~/Library/Fonts/StatuslineIcons-<N>.otf;
#   4. checks the terminal maps U+E900-U+E9A9 to that font, and prints the line
#      to add when it does not.
# Safe to run again: each step that is already done is left alone.
# --no-font skips 3 and 4; the status line then prints names (Opus, Codex).
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
claude_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
fonts_dir=$HOME/Library/Fonts
with_font=1
[[ "${1:-}" == --no-font ]] && with_font=""

say()  { printf '%s\n' "$*"; }
# Sets $resolved to a path with its symlinks followed to the file itself. No
# command substitution carries the result, since one drops trailing newlines
# and a link target may end in one. readlink -n prints the target's exact
# bytes (plain readlink adds a newline, except after a target ending in one),
# and a sentinel keeps them through the substitution.
resolve() {
  local f=$1 link
  while [[ -L "$f" ]]; do
    link=$(readlink -n "$f"; echo .); link=${link%.}
    if [[ "$link" == /* ]]; then f=$link; else f=${f%/*}/$link; fi
  done
  resolved=$f
}
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

[[ "$(uname -s)" == Darwin ]] || { warn "macOS only: the status line uses stat -f, sysctl and ~/Library/Fonts."; exit 1; }
missing=()
for tool in jq git; do command -v "$tool" >/dev/null || missing+=("$tool"); done
# The font is built by Swift from the Command Line Tools, the package git
# itself comes from. xcode-select -p asks without starting the installer that
# /usr/bin/swift would open; CoreGraphics' path operations need macOS 14.
if [[ -n "$with_font" ]]; then
  xcode-select -p >/dev/null 2>&1 ||
    missing+=("Command Line Tools: xcode-select --install (or run with --no-font)")
  (( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) ||
    missing+=("macOS 14 or later for the icons (or run with --no-font)")
fi
(( ${#missing[@]} == 0 )) || { warn "missing: ${missing[*]}"; exit 1; }

mkdir -p "$claude_dir"
claude_dir=$(cd "$claude_dir" && pwd)   # absolute: the setting is run from any directory
settings=$claude_dir/settings.json
# Checked before anything changes: a settings file that is not exactly one
# JSON object stops the install here, with the user's setup as it was.
if [[ -e "$settings" ]] && ! jq -s -e 'length == 1 and (.[0] | type == "object")' "$settings" >/dev/null 2>&1; then
  warn "$settings is not a JSON object (empty or invalid); fix it and run again"
  exit 1
fi

step "1. Link"
target=$claude_dir/statusline.sh
mkdir -p "$claude_dir"
if [[ -L "$target" && "$(readlink "$target")" == "$repo/statusline.sh" ]]; then
  say "$target already links here"
else
  if [[ -e "$target" || -L "$target" ]]; then
    stamp=$(date +%Y%m%d-%H%M%S) n=1
    backup=$target.bak-$stamp
    while [[ -e "$backup" || -L "$backup" ]]; do n=$(( n + 1 )); backup=$target.bak-$stamp-$n; done
    mv "$target" "$backup"
    say "kept the previous one as $backup"
  fi
  ln -s "$repo/statusline.sh" "$target"
  say "$target -> $repo/statusline.sh"
fi

step "2. Setting"
[[ -e "$settings" ]] || echo '{}' > "$settings"
# The usual place is written as ~/.claude/..., which survives a renamed home;
# a CLAUDE_CONFIG_DIR elsewhere gets its full path, quoted for the shell
# Claude Code runs it with.
command=$(printf '%q' "$target")
[[ "$claude_dir" == "$HOME/.claude" ]] && command="~/.claude/statusline.sh"
current=$(jq -r '.statusLine.command // ""' "$settings")
case $current in
  "")
    # The new file is made beside the real one (through any symlink) as a copy,
    # so it has the same mode, owner and ACLs, then renamed over it in one
    # step: the link stays a link, and an interrupted write leaves the old
    # settings whole.
    resolve "$settings"; real=$resolved
    tmp=$real.plimsoll-$$
    cp -p "$real" "$tmp"
    if ! jq --arg c "$command" '.statusLine = {type: "command", command: $c}' "$real" > "$tmp"; then
      rm -f "$tmp"; warn "could not write $real; it is unchanged"; exit 1
    fi
    mv "$tmp" "$real"
    say "statusLine set in $settings" ;;
  "$command"|"$target")
    say "statusLine already points at it" ;;
  *)
    warn "statusLine already runs: $current"
    say "  left as it is; to use this one, set its command to $command" ;;
esac

[[ -n "$with_font" ]] || { say; say "Done, without the font: the status line prints names."; exit 0; }

step "3. Font"
version=$(sed -nE 's/^let family = "Statusline Icons ([0-9]+)"$/\1/p' "$repo/fonts/build.swift")
[[ -n "$version" ]] || { warn "no family version found in fonts/build.swift"; exit 1; }
installed=$fonts_dir/StatuslineIcons-$version.otf
if [[ -f "$installed" ]]; then
  say "version $version already installed: $installed"
else
  say "building version $version (downloads the source pictures on first run)"
  swift "$repo/fonts/build.swift" "$repo/fonts/StatuslineIcons.otf"
  mkdir -p "$fonts_dir"
  cp "$repo/fonts/StatuslineIcons.otf" "$installed"
  say "installed $installed"
fi
# Other versions are left alone: a terminal or another checkout may still be
# configured for one, older or newer. They are listed for the user to remove.
others=()
for f in "$fonts_dir"/StatuslineIcons-*.otf; do
  [[ -e "$f" && "$f" != "$installed" ]] && others+=("${f##*/}")
done
if (( ${#others[@]} > 0 )); then
  say "other versions installed: ${others[*]}"
  say "  remove them from $fonts_dir once no terminal config names them"
fi

step "4. Terminal"
family="Statusline Icons $version"
ghostty_line="font-codepoint-map = U+E900-U+E9A9=$family"
if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
  found=""
  for conf in "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config" \
              "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
              "$HOME/Library/Application Support/com.mitchellh.ghostty/config"; do
    [[ -r "$conf" ]] && grep -qxF "$ghostty_line" "$conf" && found=$conf
  done
  if [[ -n "$found" ]]; then
    say "Ghostty maps the icons ($found)"
  else
    say "Add to your Ghostty config (~/.config/ghostty/config), replacing any older"
    say "Statusline Icons line, then restart Ghostty (or cmux):"
    say "  $ghostty_line"
  fi
else
  say "Not running in Ghostty: the status line prints names until the terminal maps"
  say "U+E900-U+E9A9 to \"$family\" and STATUSLINE_ICONS=1 is in Claude Code's environment."
  say "Untested outside"
  say "Ghostty; the glyphs are drawn two cells wide and may be clipped. For example:"
  say "  kitty    symbol_map U+E900-U+E9A9 $family"
  say "  WezTerm  font = wezterm.font_with_fallback({ 'JetBrains Mono', '$family' })"
  say "  VS Code  \"terminal.integrated.fontFamily\": \"JetBrains Mono, '$family'\""
fi

say
say "Done. Claude Code picks the status line up on its next refresh."
