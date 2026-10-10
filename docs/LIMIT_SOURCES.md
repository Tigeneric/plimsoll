# Where usage limits can come from

A reference for anyone who wants to show Claude Code, Codex or Antigravity usage limits:
the ways a number can be obtained, what each costs, and why plimsoll uses the one it does.
Every tool in this space shows the same thing in the end, a percentage the provider's
server has already computed. None of them counts tokens into a limit: how tokens weigh
against a plan is known only to the server. The difference between the approaches is
**where the number is read from and how fresh it is**.

## The four sources

| Source | How | Fresh | Cost per reading | Credentials touched |
|---|---|---|---|---|
| **Local** — what the tool already reports | Claude Code passes `rate_limits` to the status line on every redraw (taken from the `anthropic-ratelimit-unified-*` headers of its own API responses); Codex writes `rate_limits` into `~/.codex/sessions/rollout-*.jsonl` after every turn | as of the tool's last response; does not move while it is idle | none: no process, no network | none |
| **CLI** — the tool's own command | `claude -p "/usage"`, `codex app-server` → `account/rateLimits/read`, `agy -p "/usage" --output-format stream-json` | whenever asked; includes usage from other devices and the web | one process: seconds, 0 tokens | none: the tool manages its own login |
| **API** — the endpoint the tool calls internally | e.g. `GET /api/oauth/usage` with the OAuth token Claude Code keeps in the keychain | whenever asked | one HTTP request | another program's token, read from the keychain |
| **Web** — the provider's website | an embedded browser signed in to claude.ai or chatgpt.com, calling the pages' own endpoints with session cookies | whenever asked | a browser engine kept running | live web session cookies |

## What the local source leaves out

Claude Code reads more limits from the response headers than it passes to the status line.
Its header parser keeps one window per `anthropic-ratelimit-unified-<window>-*` header it
receives — among them `five_hour`, `seven_day` and `seven_day_overage_included` (header
`7d_oi`), which its own messages call the **Fable limit**: "You've used your included Fable
usage for this week". The status line's `rate_limits` is built from that state but carries
only `five_hour` and `seven_day`, plus `spend_limit` (from the `overage` window) when Claude
Code signs in through a gateway. The weekly Fable window is parsed and then dropped.

So no status line on a stock Claude Code can show how much of the included Fable usage is
left; plimsoll does not show it either. The number reaches a status line only if Claude Code
starts passing it; inside Claude Code the window is `seven_day_overage_included`, the name a
status line should expect if it ever arrives. The CLI does carry it: `claude -p "/usage"`
prints a line of its own, "Current week (Fable): 0% used · resets Oct 17 at 2pm
(UTC)", so a background poller can read the number even though no status line
can.

## What plimsoll uses, and why

**Local only.** A status line runs on every redraw of every tab and must finish in a
fraction of a second; it has no business waiting seconds for a process or a network
round-trip, and it holds no credentials. So plimsoll merges what Claude Code and Codex
already report into one shared file (see *The shared limits file* in the README) and draws
from it. plimsoll never calls a CLI, an endpoint or a website.

The cost of that choice: while every tab is idle the reading does not move. A separate
background program can close that gap by asking the CLIs and merging the answer into the
same file under the same rule; every tab then draws the fresher number. That program is the
right place for anything slower than a redraw.

## Choosing for a background poller

If you write such a program, prefer the sources in this order:

1. **Local**, whenever it is fresh enough. It is free.
2. **CLI**, to fill the idle gaps. It is the official interface: the tool keeps its own
   login and refreshes its own token, and nothing outside it holds credentials. Its costs
   are real and should be designed around:
   - **Slow.** A process per reading; poll every few minutes, not every few seconds, and
     back off after failures.
   - **Text where you would want data.** Claude's `/usage` answers in sentences
     ("Current week (all models): 4% used · resets Oct 17 at 2pm (UTC)"); a
     parser must give *no reading* for anything it does not fully understand. Codex's
     app-server and Antigravity's `stream-json` answer in structured JSON.
   - **Side effects.** Run each CLI from an empty working directory, with a short
     environment and no way to open a browser. Without `--no-session-persistence` and
     disabled hooks, every `claude -p` call leaves a session behind and runs your hooks.
     A signed-out `agy` opens a Google sign-in page instead of failing: check that it is
     signed in before calling it.
3. **API** only if the CLI cannot be installed. The program then holds another program's
   token. If it ever refreshes that token, it can rotate the refresh token out from under
   the tool and sign it out; the endpoint is internal and may change without notice.
4. **Web** last. It holds live session cookies for whole accounts, depends on pages that
   change (and on bot protection), and needs a browser engine running.

## Measurements

Measured on one machine, macOS 27, on the date given. Re-measure before relying on a
number; tools change.

| Command / input | What was probed | Result (measured 2026-10-10) |
|---|---|---|
| `claude -p "/usage" --output-format json` (Claude Code 2.1.292) | cost, output | 0 tokens, `total_cost_usd` 0; ~4 s; the result is text |
| same, without flags | side effects | a new session file per call; SessionStart hooks run |
| same, with `--no-session-persistence --settings '{"disableAllHooks":true}'` | side effects | no session file, no hooks; 3.75 s |
| `claude --bare -p "/usage"` | output | a `/cost` summary, not the subscription limits |
| `claude -p "/usage"` without `USER` in the environment | output | a `/cost` summary, not the limits |
| `codex app-server`, `initialize` → `initialized` → `account/rateLimits/read` | output, time | `rateLimits.primary` and `.secondary` with `usedPercent`, `windowDurationMins`, `resetsAt`; ~1 s |
| `agy -p "/usage" --output-format stream-json` (Antigravity CLI 1.3.x) | cost, output | 0 tokens; ~5–6 s; per model group, a `5h` and a `weekly` bucket with `remaining_fraction` and `reset_time` |
| same, signed out | behaviour | opens a Google sign-in page in the browser; otherwise fails after ~60 s |
| Claude Code 2.1.292 binary, `strings` | which windows reach the status line | `rate_limits` is built from `five_hour`, `seven_day`, and `overage` as `spend_limit` under a gateway; `seven_day_overage_included` (label `"Fable limit"`) is parsed and not passed (2026-10-11) |
| `claude -p "/usage"`, flags as above (Claude Code 2.1.292) | the Fable window | a line "Current week (Fable): N% used · resets …" after "Current week (all models)"; 0 tokens, 3.3 s (2026-10-11) |
| Codex `rate_limits` in its session logs | reset-time jitter | up to ~50 s between consecutive responses; the next gap is 780 s |

Not probed: `codex app-server` while signed out; any CLI without a network.
