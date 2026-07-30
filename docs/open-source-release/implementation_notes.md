# Implementation notes

The decisions behind this project, the options that were turned down, and how
each release was verified.

## Purpose

Let a coding agent drive a Chrome that is already open and signed in. Not a
fresh browser, not a headless one. The real profile with its existing sessions.

`playwright-my-chrome` is a vendor-neutral Agent Skill. It installs through the
Vercel Skills CLI and runs under Codex, Claude Code, or any other agent running
in the same macOS desktop session as Chrome.

## Decisions

### Layout and portability

- Use the Agent Skills `skills/<name>/SKILL.md` layout. The instructions and the
  runtime scripts depend on no agent vendor, so the project is not tied to one
  host.
- Keep `agents/openai.yaml` optional. It carries UI metadata only, and nothing
  at runtime reads it.
- Make `npx skills install` the public command, and keep the `add` alias working
  so both spellings behave the same.
- Put the MIT notice inside the skill directory as well as the repository root.
  Skill installers copy only that directory, so a license at the root alone
  would never reach an installed copy.

### Safety, because the wrapper holds a real token

- Pin `@playwright/cli` to 0.1.17. Browser commands fail closed on every other
  version. Attachment and daemon behavior are security sensitive, and a future
  release may not keep the same guarantees.
- Store the extension token in macOS Keychain and never accept it as a command
  argument. Setup reads the clipboard and clears it afterwards.
- Require exactly one normal Chrome main process, and compare the complete PID
  set immediately before and after attachment. Detach if it changed.
- Bound attachment to 60 seconds. On timeout, kill the exact child that was
  started, attempt a named-session detach, remove the private artifacts, and
  require token rotation.
- Reuse one private `mychrome` session across agents for the same desktop user,
  so two agents do not fight over the extension connection.

### Disclosed rather than papered over

The Playwright CLI daemon inherits the token-bearing environment for as long as
the session is attached. That is upstream behavior this project cannot remove.
It is documented in `SECURITY.md` as a residual risk, and `disconnect` is the
supported way to shorten the exposure window.

### CI

Development dependencies are locked, and no mutable package install runs in CI.
The Ubuntu runner uses its own bundled ShellCheck for static analysis. macOS
runs the behavior and installation tests.

## What was turned down

- **Chrome DevTools Protocol.** It needs a separately launched debugging
  browser, which defeats the point of using an already signed-in profile.
- **Browser APIs and vendor connectors.** The requirement was Playwright driving
  the real rendered Chrome UI, not a service reaching the site another way.
- **AppleScript and machine-wide Chrome process control.** Both bypass
  Playwright and can affect browser instances unrelated to the task.
- **Printing failed attachment logs and redacting them afterwards.** Passing a
  live token to a redaction process still exposes it to anyone who can list
  process arguments. Capturing and scrubbing without printing is the only
  version that holds.
- **Homebrew in CI.** It runs mutable remote content during the build. For a
  project whose job is guarding a credential, that is the wrong trade.

## Corrections made during development

- An early cut was shaped around one agent host. That was pulled back out to
  keep the skill agent-agnostic and compliant with the Agent Skills standard, so
  it does not rot when the host changes.
- Recovery was disarming too early. It now stays armed until the post-attach PID
  checks, the process-token check, helper-tab validation, and private-output
  sanitation have all finished.
- Interrupt handling was added for both attach and post-attach validation. On
  interrupt the wrapper terminates the tracked CLI child, unsets the token
  environment, attempts a token-free named detach, and deletes the private
  bootstrap artifacts.

## First release verification

All on macOS:

- `npm run verify`: ShellCheck, project validation, and all 21 behavior tests
  under Bash 3.2.
- Agent Skill quick validation: passed.
- Strict skill security scan: 0 findings across 7 files and 2 scripts.
- Workflow and host-metadata YAML parsing: passed.
- Locked dependency audit: 0 vulnerabilities.
- Real `@playwright/cli` 0.1.17 `doctor` smoke test: passed.
- Vercel Skills 1.5.21 discovery and copy installation: passed for Codex, Claude
  Code, the universal target, and the wildcard all-agent target.
- Installed copies kept the MIT license and the executable script modes.
- Independent shell, installation, and security reviews: publish PASS with no
  remaining blockers.
- Interruption coverage runs against a token-bearing attach child and against a
  successful attachment paused in post-attach tab validation. Both tests check
  token-free detachment and artifact cleanup.

Public installation, repository security settings, hosted CI, and the release
tag were left as post-push steps.

## 2026-07-30: rename and documentation rewrite

### Rename

The project was renamed from `playwright-active-chrome` to
`playwright-my-chrome`.

"Active" was the weakest word in the old name. Most readers, and especially
non-native English readers, take "active" to mean "the tab in front" rather than
"the browser already open". "My" carries the intended meaning with no second
reading.

Every identifier moved, not only the repository name. A half-renamed project
reads as a mistake:

- the skill directory and the skill `name`
- the wrapper script, from `playwright-cli-active.sh` to
  `playwright-my-chrome.sh`
- the environment variable prefix, from `PLAYWRIGHT_ACTIVE_CHROME_` to
  `PLAYWRIGHT_MY_CHROME_`
- the shared session, from `activechrome` to `mychrome`
- the Keychain service, to `playwright-my-chrome.extension-token`
- the default runtime directory, to `$HOME/Library/Caches/playwright-my-chrome`
- the runtime claim marker, to `playwright-my-chrome-runtime-v1`

Internal messages that used "active Chrome" as plain English were reworded too,
so the word does not return through the error output.

The Keychain service and the runtime directory hold state, so an existing
install does not migrate itself. Move the stored token with
`store-extension-token.sh --migrate-from-service`, then delete the old cache
directory.

No compatibility shim was added. The rename landed a few hours after the first
publish, before anyone had installed the old name, so there was nothing to stay
compatible with. Deferring it would have cost a permanent redirect and a
deprecation note, and kept the weaker name.

### Documentation

The old README served a reader who had already decided to use the project, not
one still deciding.

What changed and why:

- The macOS and Chrome requirement moved to the top. It decides whether the
  reader can use the project at all, and it was sitting halfway down the page.
- Added "What it looks like" with a real prompt. The old page never showed what
  using the skill feels like.
- Documented the green Playwright tab group. That instruction existed only in
  `SKILL.md`, and it is the first thing a new user needs.
- Collapsed three install commands into one. Three variants before the reader
  has done anything is a choice they are not ready to make.
- Rewrote the safeguard list so every line starts with a subject and a verb. The
  old list stacked abstract nouns, which is the hardest shape to read in a
  second language.
- Added a Troubleshooting table built from the real `doctor` output in the
  wrapper rather than from assumption. Writing it surfaced two states the docs
  never mentioned: `chrome: ambiguous` and `session: stale`.
- Added CI, license, and platform badges, and a short Contributing section.

The page grew in words. Concise means no wasted words, not fewer answers.

`SECURITY.md` and `CONTRIBUTING.md` were rewritten against the same readability
bar: short sentences, plain words, and every list item starting with a subject
and a verb.

### Rename verification

- `tests/lint.sh`: passed.
- `tests/run.sh`: 21 of 21 behavior tests passed after the rename.
- `npx skills@1.5.21 install . --list`: found the skill under the new name.
- Keychain token migrated with `--migrate-from-service`. `doctor` then reported
  `token: stored` and the new `playwright-my-chrome` workspace path.
- `safety-audit` on the installed copy against real Chrome: all 7 safeguards
  passed.
- Hosted CI on the rename commit: green.

The stale `$HOME/Library/Caches/playwright-active-chrome` directory was scanned
for token material before deletion. It was clean, which confirmed the wrapper's
scrubbing had been working. Old-name installs were removed and replaced with a
single global install of the new name.

The old Keychain item `playwright-active-chrome.extension-token` was left in
place. `SKILL.md` says to delete a previous item only on request, and deleting a
credential cannot be undone. Remove it with:

```bash
security delete-generic-password \
  -a "$(id -un)" \
  -s playwright-active-chrome.extension-token
```

A live connection was then taken against real Chrome to close the last gap:

- `connect` reported ready on the renamed `mychrome` session.
- `doctor` reported `session: ready` and `process-token: absent`, so the token
  did not reach the Chrome command line during a real attachment.
- `tab-list` returned the extension helper tab and the clean controlled tab,
  with the helper's authentication query redacted in the forwarded output.
- `goto https://example.com` loaded the page and returned its title, which
  proves the session actually drives the browser.
- `disconnect` detached and left Chrome running on the same PID it started on.
