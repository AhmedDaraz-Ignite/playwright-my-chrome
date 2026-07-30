# Open-source release implementation notes

## Goal

Publish `playwright-active-chrome` as a vendor-neutral Agent Skill that can be
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
- Reuse one private `activechrome` session across compatible agents for the same
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
