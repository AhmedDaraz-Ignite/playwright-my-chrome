# Open-source release implementation notes

## Goal

Publish `playwright-my-chrome` as a vendor-neutral Agent Skill that can be
installed through the Vercel Skills CLI and used by Codex, Claude Code, or any
other compatible agent running in the same macOS desktop session as Chrome.

## Decisions

- Use the Agent Skills `skills/<name>/SKILL.md` layout. The core instructions
  and runtime scripts do not depend on an agent vendor.
- Keep `agents/openai.yaml` optional. It provides UI metadata only and does not
  affect runtime behavior.
- Use `npx skills install` as the primary public command, while retaining
  compatibility with its `add` alias.
- Pin `@playwright/cli` to 0.1.17. Browser operations fail closed for every
  other version because the attachment and daemon behavior is security
  sensitive.
- Store the extension token in macOS Keychain and never accept it as a command
  argument. Token setup reads the clipboard and clears it after storage.
- Reuse one private `mychrome` session across compatible agents for the same
  logged-in desktop user.
- Require exactly one normal Chrome main process and compare the complete PID
  set before and after attachment.
- Bound attachment to 60 seconds and use targeted process cleanup, named-session
  detachment, private artifact removal, and token-rotation guidance on timeout.
- Treat the Playwright CLI daemon's inherited token environment as a disclosed
  upstream residual risk. Disconnecting limits the exposure window.
- Put the MIT notice inside the installable skill directory as well as the
  repository root because skill installers copy only that directory.
- Lock development dependencies with npm and avoid mutable package installation
  in CI. The Ubuntu runner's bundled ShellCheck performs static analysis, while
  macOS runs behavioral and installation tests.

## Alternatives rejected

- Chrome DevTools Protocol was rejected because it requires a separately
  launched debugging browser and does not meet the active-profile requirement.
- Browser APIs and vendor connectors were rejected because the user explicitly
  requires Playwright through the existing signed-in Chrome UI.
- AppleScript and machine-wide Chrome process control were rejected because
  they bypass Playwright and can affect unrelated browser instances.
- Printing and redacting failed attachment logs was rejected because putting
  the live token in a redaction process argument still exposes it through
  process inspection.
- Homebrew installation in CI was rejected because it executes mutable remote
  content during the build.

## Corrections incorporated

- Require explicit maintainer approval for the final commit message.
- Do not use the `generate-pr` skill and do not create a pull request.
- Keep the public skill agent-agnostic and compliant with the Agent Skills
  standard.
- Keep recovery armed until post-attach PID checks, process-token checks,
  helper-tab validation, and private-output sanitation all complete.
- On interruption during attach or post-attach validation, terminate the
  tracked CLI child, unset the token environment, attempt token-free named
  detachment, and remove the private bootstrap artifacts.

## Verification record

Completed locally on macOS:

- `npm run verify`: passed ShellCheck, project validation, and all 21 behavior
  tests under Bash 3.2.
- Agent Skill quick validation: passed.
- Strict skill security scan: 0 findings across 7 files and 2 scripts.
- Workflow and optional host-metadata YAML parsing: passed.
- Locked dependency audit: 0 vulnerabilities.
- Real `@playwright/cli` 0.1.17 `doctor` smoke test: passed.
- Vercel Skills 1.5.21 discovery and copy installation: passed for Codex,
  Claude Code, the universal target, and the wildcard all-agent target.
- Installed copies retained the MIT license and executable script modes.
- Independent shell, installation, and security reviews: publish PASS with no
  remaining blockers.
- Interruption coverage includes both a token-bearing attach child and a
  successful attachment paused in post-attach tab validation. Both tests
  verify token-free detachment and artifact cleanup.

Public GitHub installation, repository security settings, hosted CI, and the
release tag remain post-push verification steps.

## 2026-07-30: rename and README rewrite

### Rename

Renamed the project from `playwright-active-chrome` to `playwright-my-chrome`.
The word "active" was the weakest part of the old name. Many readers, and
especially non-native English readers, read "active" as "the tab in front"
rather than "the browser you already have open". "My" states the point with no
ambiguity.

The rename covers every identifier, not only the repository name, because a
half-renamed project reads as a mistake:

- skill directory and skill `name`
- wrapper script, from `playwright-cli-active.sh` to `playwright-my-chrome.sh`
- environment variable prefix, from `PLAYWRIGHT_ACTIVE_CHROME_` to
  `PLAYWRIGHT_MY_CHROME_`
- shared session name, from `activechrome` to `mychrome`
- Keychain service, from `playwright-active-chrome.extension-token` to
  `playwright-my-chrome.extension-token`
- default runtime directory, from
  `$HOME/Library/Caches/playwright-active-chrome` to
  `$HOME/Library/Caches/playwright-my-chrome`
- runtime claim marker, to `playwright-my-chrome-runtime-v1`

The Keychain service and runtime directory carry state, so an existing install
does not migrate itself. Move the stored token with
`store-extension-token.sh --migrate-from-service`, then delete the old cache
directory. The rename happened a few hours after the first publish, when nobody
had installed the old name yet, so no compatibility shim was added.

Internal messages that used "active Chrome" as plain English were reworded too,
so the word does not come back through the error output.

### README rewrite

Rewritten for clarity and for non-native English readers:

- The macOS and Chrome requirement moved from the middle of the page to the
  intro. It decides whether the reader can use the project at all.
- Added "What it looks like" with a real prompt. The old README never showed
  what using the skill feels like.
- Documented the green Playwright tab group. That instruction only existed in
  `SKILL.md`, and it is the first thing a new user needs.
- Collapsed three install commands into one, with the variants in a sentence
  after it.
- Rewrote the safeguard list so every line starts with a subject and a verb.
  The old list stacked abstract nouns, which is the hardest shape to read in a
  second language.
- Added a Troubleshooting table built from the real `doctor` output in the
  wrapper, not from memory. Writing it surfaced two states the docs never
  mentioned: `chrome: ambiguous` and `session: stale`.
- Added CI, license, and platform badges, plus a short Contributing section.

The page got longer in words. Concise means no wasted words, not fewer answers.

### Verification

- `tests/lint.sh`: passed.
- `tests/run.sh`: 21 of 21 behavior tests passed after the rename.
- `npx skills@1.5.21 install . --list`: found the skill under the new name.
- Keychain token migrated with `--migrate-from-service`. `doctor` then reported
  `token: stored` and the new `playwright-my-chrome` workspace path.
- `safety-audit` on the installed copy against real Chrome: all 7 safeguards
  passed.
- Hosted CI on the rename commit: green.

The old Keychain item `playwright-active-chrome.extension-token` was left in
place. `SKILL.md` says to delete a previous item only when the user asks, and
deleting a credential cannot be undone. Remove it with
`security delete-generic-password -a "$(id -un)" -s
playwright-active-chrome.extension-token`.

The stale `$HOME/Library/Caches/playwright-active-chrome` directory was scanned
for token material, found clean, and deleted. Old-name skill installs were
removed and replaced by one global install of the new name.

Taking a live extension connection was not part of this change, so `connect`
under the new session name is still unverified against real Chrome. Everything
below that point, including the real Playwright CLI, the real Keychain, and the
real Chrome process checks, was exercised.
