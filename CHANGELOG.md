# Changelog

Versions follow [semantic versioning](https://semver.org). The version lives in
one place, the git tag; a release is a section here plus `git tag vX.Y.Z`.

## 0.2.0 — 2026-10-11

### Added

- A shared limits file, `${XDG_CACHE_HOME:-~/.cache}/plimsoll/limits.json`: every
  session merges its Claude and Codex readings into it and draws from the
  result, so an idle tab no longer shows a reading older than another tab's.
  Per window, a reading with a later reset belongs to a newer window and wins;
  within the same window the higher percentage does. A `CLAUDE_CONFIG_DIR` other
  than `~/.claude` is another account and keeps a file of its own, in a
  subdirectory named after its path. The format is described in the README.
- An `antigravity` section in the shared file, per quota group, with a `5h` and
  a `weekly` window. plimsoll has no reading of its own for it: a poller of
  Antigravity's CLI writes it, and plimsoll keeps it through its own writes
  without drawing it.
- `tests/contract/`: the merge rule as cases, and a file every writer must
  carry through, for other writers of the file to run as well.

### Changed

- The Codex mark is dimmed when its reading has neither changed in the shared
  file nor been confirmed by a write to Codex's log for over an hour.

## 0.1.0 — 2026-10-09

The first release as a project of its own. The status line grew inside a
personal Claude Code configuration before it was moved out here.

### Added

- The line: a session dot, path, branch and uncommitted diff on the left; the
  model with its effort level, the context window, the five-hour limit with its
  reset countdown, Codex's limits, free disk space and CPU on the right.
- Model and Codex marks drawn from a font built on your machine, each filled to
  what is left of its weekly limit in 4% steps, and linked to its usage page.
- Names instead of marks (`Opus 5.5`, `Codex 8%`) wherever the terminal cannot
  draw the font: outside Ghostty, without the font installed, or with the
  installed version not the one the terminal is told to use.
  `STATUSLINE_ICONS=1` or `0` overrides the check.
- `install.sh`: links the script, sets `statusLine` when none is set, builds
  and installs the font, and checks the terminal's configuration.
- The source pictures are downloaded at build time and checked against a
  recorded SHA-256; they are not part of the repository.
- The font is built by a Swift script with CoreGraphics, so nothing beyond
  the Command Line Tools — which `git` already needs — has to be installed.
  Icons need macOS 14 or later.
