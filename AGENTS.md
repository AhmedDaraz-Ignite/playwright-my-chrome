# AGENTS.md

This file provides guidance to coding agents working with code in this
repository. It is the single source of truth; `CLAUDE.md` is a symlink to it.

## What this repository is

One published Agent Skill, `skills/playwright-my-chrome/`, that lets an agent
drive the Chrome the user already has open and signed in. Everything shipped to
users lives in that directory; the repository root only holds docs, tests, and
CI. macOS and Google Chrome only.

## Commands

```bash
npm run lint      # shellcheck + bash -n on every .sh, then tests/validate_skill.py
npm test          # tests/run.sh, the 21 behavior tests (about 12s)
npm run verify    # both
npx skills@1.5.21 install . --list   # third release check, Skills CLI discovery
```

`npm run lint` needs `shellcheck` on PATH (`brew install shellcheck`).

`tests/run.sh` has no filter flag. It is fast enough to run whole; to isolate one
case, comment out the other calls in the invocation list at the bottom of the
file.

Before any manual check against real Chrome, reinstall first. `npx skills
install` copies the skill directory instead of linking it, so an installed copy
goes stale as soon as `scripts/` changes and would silently test old code:

```bash
npx skills install . --skill playwright-my-chrome --global \
  --agent codex --agent claude-code
```

Then run the wrapper from the installed path, not from this repository.

## Architecture

`scripts/playwright-my-chrome.sh` (about 1800 lines of bash) is the product. It
is a fail-closed wrapper around an already-installed `@playwright/cli`, not a
library. Reading it top to bottom gives the whole design:

1. **Preamble** resolves the CLI and Node from fixed absolute locations (nvm,
   Volta, Homebrew, `/usr/local`), never through caller `PATH`, then resets
   `PATH` to system directories so nothing secret-bearing can be shimmed.
2. **Runtime directory** under the user's Caches folder must be private, mode
   0700, non-symlink, and carry a claim file. The wrapper `cd`s there for every
   CLI call, which is how one shared session named `mychrome` stays the same
   from any repository: Playwright CLI picks its daemon session from the nearest
   `.playwright` folder.
3. **Attachment** (`attach_session`) is the security core. It requires exactly
   one normal Chrome main process already running, reads the Keychain token only
   at that point, writes it to the child as an environment variable, and compares
   the full Chrome PID set immediately before and after. A changed PID set, or a
   Chrome command line still carrying the token, detaches and demands token
   rotation.
4. **Cleanup** paths (`scrub_known_output`, `finalize_sanitation`,
   `remove_known_output`) delete only what private, mode-0600, non-symlink
   metadata files name, and refuse traversal-shaped paths.
5. **Dispatch** at the bottom is an allowlist. `open`, raw `attach`, `show`,
   `install`, `close-all`, and `kill-all` are rejected locally. Unknown commands
   go through `ensure_session` and are forwarded with the session flag and token
   redaction.

`scripts/store-extension-token.sh` is the only writer of the Keychain item. It
reads the token from the clipboard, validates its shape, stores it, and clears
the clipboard. The token is never a command-line argument anywhere.

Stable exit codes the tests assert on: `2` unsupported CLI version, `3` token
unreadable, `4` no owned session and attaching was not approved, `5` Chrome
missing, ambiguous, or changed before attachment, `6` security fail-closed,
`124` attachment timeout, `143` interrupted.

`SKILL.md` is the agent-facing procedure and must stay vendor-neutral and under
500 lines. `agents/openai.yaml` is host UI metadata only; nothing reads it at
runtime.

## Invariants the checks enforce

- **The pinned CLI version appears in five places**: `supported_cli_version` in
  the wrapper, `SKILL.md`, `README.md`, `SECURITY.md`, and `package.json`.
  `validate_skill.py` fails if the wrapper's value is missing from the docs.
  Update all five together.
- **No machine-specific home paths and no Unicode dashes in any tracked file**,
  including this one. `validate_skill.py` scans the whole repository, not only
  the skill.
- **Tests never touch the real world.** Keychain, `ps`, clipboard, and the
  Playwright CLI are replaced by `tests/mocks/*.sh` through
  `PLAYWRIGHT_MY_CHROME_TEST_*` environment variables, with `HOME` pointed at a
  temporary directory. A test that needs a real browser, token, or Chrome
  profile is not acceptable.
- **Every safeguard change needs a regression test.** This is not waived, per
  CONTRIBUTING.md.
- **Fail-closed stays fail-closed.** If a change touches the unsupported-version
  path or the unclear-Chrome-state path, explain what the failure branch does.

## Notes

Design decisions, rejected alternatives, and per-release verification live in
`docs/open-source-release/implementation_notes.md`. Read it before revisiting a
choice that looks arbitrary; most of them were deliberate.

Security-sensitive findings go through a private GitHub advisory, never a pull
request or issue.
