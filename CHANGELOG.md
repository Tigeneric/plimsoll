# Changelog

Versions follow [semantic versioning](https://semver.org). The version lives in
one place, the git tag; a release is a section here plus `git tag vX.Y.Z`.

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
