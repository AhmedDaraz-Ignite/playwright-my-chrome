# Playwright Active Chrome

An [Agent Skill](https://agentskills.io/) that lets a coding agent control your
already-running, signed-in Google Chrome through the official Playwright CLI and
Playwright Extension.

The skill is designed for the awkward but important case where a task must use
the browser session you already have: its cookies, logins, tabs, and profile. It
refuses to silently launch a replacement browser.

> [!WARNING]
> A connected agent can read and operate the tabs exposed by the Playwright
> Extension, including signed-in websites. Install this only for agents and
> repositories you trust.

## Install

Install the required Playwright CLI version:

```bash
npm install -g @playwright/cli@0.1.17
```

Install the skill globally for Codex and Claude Code:

```bash
npx skills install AhmedDaraz-Ignite/playwright-active-chrome \
  --skill playwright-active-chrome \
  --global \
  --agent codex \
  --agent claude-code
```

Install it for every agent supported by the Vercel Skills CLI:

```bash
npx skills install AhmedDaraz-Ignite/playwright-active-chrome \
  --skill playwright-active-chrome \
  --global \
  --agent '*'
```

`npx skills add` is an alias for `npx skills install` when a source is
provided. Use `--list` to inspect the repository without installing:

```bash
npx skills install AhmedDaraz-Ignite/playwright-active-chrome --list
```

The repository follows the [Agent Skills specification](https://agentskills.io/specification)
with the standard `skills/<name>/SKILL.md` layout. The
[Vercel Skills CLI](https://github.com/vercel-labs/skills) handles each agent's
discovery directory. The core skill does not depend on Codex, Claude Code, or
another vendor's runtime.

## Requirements

Installation is cross-agent. Running the browser automation currently requires:

- macOS
- Google Chrome
- the official
  [Playwright Extension](https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm)
- Node.js 22.20 or newer
- `@playwright/cli` 0.1.17
- Bash and the macOS Keychain
- an agent running as the same logged-in desktop user as Chrome

Cloud-hosted agents cannot control a Chrome process on your Mac unless they
actually execute in that desktop session.

## One-time setup

1. Install and enable the Playwright Extension in the Chrome profile you want
   the agent to use.
2. Open Chrome manually.
3. Open the extension connection page, regenerate its token, and copy it using
   the extension's copy button.
4. Ask your agent to configure `$playwright-active-chrome`, or run the installed
   skill's `scripts/store-extension-token.sh` while the token is still on the
   clipboard.
5. Run `scripts/playwright-cli-active.sh doctor` from the installed skill
   directory. It should report the token as stored and the CLI as supported.

The token is validated without being printed, stored in macOS Keychain, and
removed from the clipboard after successful setup.

## What the wrapper enforces

- Chrome must already be running before a fresh connection.
- Exactly one normal Chrome main process must exist, and the complete PID set
  must remain unchanged through attachment.
- A token-bearing Chrome command line aborts the connection and requires token
  rotation.
- Attachment is limited to 60 seconds, with targeted child termination,
  named-session detachment attempts, explicit detachment-failure reporting,
  artifact cleanup, and token-rotation guidance on timeout.
- `open`, raw `attach`, `show`, browser installation, `close-all`, and
  `kill-all` are blocked.
- Disconnecting maps to Playwright's `detach`, leaving the external Chrome
  process running.
- One private, shared `activechrome` session is reused across compatible agents.
- The extension token is read only for an explicitly approved fresh connection
  or explicit token-rotation verification.
- Token-bearing bootstrap output is captured and scrubbed without being
  forwarded.

The complete operating procedure lives in
[`SKILL.md`](skills/playwright-active-chrome/SKILL.md).

## Development

Run the release checks on macOS:

```bash
/bin/bash tests/lint.sh
/bin/bash tests/run.sh
npx skills@1.5.21 install . --list
```

The tests use isolated mock Keychain, process-list, clipboard, and Playwright
executables. They do not open or control your real browser.

## Security

Read [SECURITY.md](SECURITY.md) before installing. Please report
vulnerabilities privately through GitHub's security advisory workflow rather
than opening a public issue.

The upstream Playwright CLI daemon inherits the extension token in its
environment for the lifetime of an attached session. Processes running as the
same macOS user may be able to inspect that environment. Disconnect after use
and use a separate Chrome profile for higher-risk automation.

## License

[MIT](LICENSE). Playwright and Google Chrome are trademarks of their respective
owners. This project is independent and is not endorsed by Microsoft or Google.
