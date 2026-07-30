---
name: playwright-active-chrome
description: Control the user's already-running, logged-in Google Chrome through Playwright CLI and the official Playwright Extension. Use when the user explicitly asks to use Playwright with their active, current, existing, or signed-in Chrome session; asks to inspect or operate a website through that rendered browser UI; or forbids APIs, browser connectors, or a newly launched browser. Reuse the shared activechrome session and never silently substitute an API, connector, AppleScript, or another browser.
---

# Playwright Active Chrome

Use the official Playwright Extension through this skill's wrapper. Preserve the
user's existing Chrome profile, cookies, logins, and tabs.

This skill is agent-host-neutral and relocatable, while its browser runtime is
macOS-specific. `SKILL_ROOT` below means the absolute directory containing this
`SKILL.md`. Resolve it from the skill path provided by the host agent, and
invoke the scripts by absolute path. Do not assume a particular agent vendor,
home-directory layout, or current working directory.

## Host integration

Keep one canonical copy of this whole directory. A host that supports agent
skills can symlink or copy it into that host's configured skill-discovery
directory. A host without automatic discovery can load this `SKILL.md` by
absolute path. There is no universal discovery directory, so discovery adapters
must remain outside the runtime contract.

The optional file under `agents/` supplies host UI metadata only. The core
instructions and scripts do not depend on it.

## Runtime contract

Use this wrapper for every command:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh"
```

Substitute the resolved absolute skill directory before invoking it. Do not
pass an unset literal `SKILL_ROOT` to the shell.

The wrapper:

- uses one `activechrome` daemon session across agents and repositories for the
  same local desktop user;
- isolates that session in a private, agent-host-neutral `.playwright`
  workspace;
- invokes an already-installed Playwright CLI without patching, installing, or
  reconfiguring the shared executable;
- proves that normal user Chrome is already running before every fresh
  attachment and refuses to launch Chrome itself;
- requires exactly one normal Chrome main process, verifies that the complete
  PID set survives attachment, and fails closed if it changes or retains the
  token;
- checks that the owned session and extension connection are healthy;
- never attaches implicitly or disconnects an extension client owned by
  another tool;
- serializes concurrent attach attempts;
- reads the extension token only for a fresh attachment or explicit
  token-rotation verification;
- captures and scrubs the attach command's token-bearing bootstrap output;
- creates and verifies a clean controlled tab, then parks the required
  extension helper safely in the background;
- redacts the helper's authentication query from forwarded CLI output; and
- bounds attachment to 60 seconds and helper-tab commands to 8 seconds so a
  stalled relay cannot leave the wrapper lock hanging indefinitely.

Default shared state:

- session: `activechrome`
- runtime: `$HOME/Library/Caches/playwright-active-chrome`
- Keychain service: `playwright-active-chrome.extension-token`
- Keychain account: the current macOS username

These environment variables provide configuration overrides:

- `PLAYWRIGHT_ACTIVE_CHROME_CLI`
- `PLAYWRIGHT_ACTIVE_CHROME_NODE`
- `PLAYWRIGHT_ACTIVE_CHROME_RUNTIME_DIR`
- `PLAYWRIGHT_ACTIVE_CHROME_SESSION`
- `PLAYWRIGHT_ACTIVE_CHROME_KEYCHAIN_SERVICE`
- `PLAYWRIGHT_ACTIVE_CHROME_KEYCHAIN_ACCOUNT`
- `PLAYWRIGHT_ACTIVE_CHROME_EXECUTABLE`

CLI and Node overrides must be absolute paths to trusted, compatible
executables. Without overrides, the wrapper checks only standard absolute
NVM, Volta, Homebrew, and `/usr/local` locations; it never selects a
token-bearing CLI through caller-controlled `PATH`. A runtime override must
also be absolute and point to a dedicated, non-symlink directory owned by the
desktop user. The wrapper creates new runtime directories privately and
refuses to claim a non-empty unrelated directory or change its permissions.
The Chrome executable override is only for another trusted Chrome installation
such as Chrome Canary. The default is standard macOS Google Chrome.

Every agent that should reuse the same browser connection must use the same
runtime directory and session name. Every agent that may perform an explicitly
approved fresh connection must use the same Keychain service and account.

When `doctor` reports `session: ready`, call the desired command directly:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" tab-list
```

An explicitly approved `connect` after Chrome, the extension, or the Playwright
daemon restarts may briefly flash the extension's `connect.html` page. This is
the official extension handshake, not user content. The CLI opens it
unconditionally on a fresh extension attachment. Do not inspect it, report it
as the requested page, or repeatedly reconnect because it appeared.

The wrapper creates a controlled blank tab, verifies that it is attached, and
parks the helper in the background. The helper must remain open because it owns
the extension heartbeat. Navigating or closing it can tear down the session.
Keeping the shared session alive prevents it from taking focus during normal
use.

## One-time configuration

This local implementation requires macOS, Google Chrome, the official
Playwright Extension, Bash, Node.js 22.20 or newer, Playwright CLI, and macOS
Keychain. Different agent hosts can load the skill from any location, but they
must run as the same logged-in desktop user to share that Chrome instance.

This release requires `@playwright/cli` 0.1.17 and never installs or upgrades
it. The wrapper refuses browser commands under another version rather than
assuming forward compatibility. `doctor` reports the resolved executable,
version, and compatibility state.

Complete these steps once for the macOS user and Chrome profile:

1. Install and enable the official Playwright Extension in the Chrome profile
   that contains the signed-in sessions to automate.
2. Open Chrome manually. Never depend on `connect` to start it.
3. Open the extension connection page. Regenerate the extension token with the
   circular-arrow button so any previously exposed value is invalidated.
4. Copy the token with the extension's copy button. Never paste it into chat or
   a terminal command.
5. While the token remains on the clipboard, run:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh"
```

The script validates the token without printing it, stores it in macOS
Keychain, and clears the clipboard after success.

To move an existing token from a previous service name without exposing it or
deleting the old entry:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh" \
  --migrate-from-service "<previous-keychain-service>"
```

After verifying the new configuration, the old Keychain item may be removed
separately if the user requests it.

Check readiness without displaying or retrieving the token:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" doctor
```

`token: stored` means an explicitly approved `connect` can authenticate without
printing the secret. `doctor` checks only whether the Keychain item exists.
`session: missing` is normal before that connection. `chrome: missing` means
the wrapper will refuse to attach until the user opens Chrome.
`process-token: exposed` requires the rotation procedure under Security.

Verify all enforced safeguards:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" safety-audit
```

## Normal workflow

The wrapper selects `activechrome` automatically. Do not add
`-s=activechrome` unless compatibility with an existing command requires it.

The Playwright Extension permits only one active client, and a connection owned
by another tool is not necessarily visible in this wrapper's session registry.
Ordinary commands therefore never attach when this skill's session is missing
or stale. Require explicit approval to take the exclusive extension
connection. Honor approval already present in the current task; do not ask for
it twice. Then run:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" connect
```

`connect` must fail without opening a browser unless exactly one normal Chrome
main process is already running. Do not bypass that preflight, call the
underlying `attach` directly, or use `open`. The wrapper blocks `attach`,
`open`, `show`, `install`, `close-all`, and `kill-all`.

Do not infer approval from a generic browser task. Once `connect` reports ready,
keep the session alive and use ordinary commands without another setup step.

The token-based extension handshake does not automatically take control of
every tab already open in Chrome. It starts with the clean controlled tab
prepared by the wrapper. Existing user tabs stay open and untouched.

To operate an already-open tab, ask the user to drag that tab into the green
Playwright tab group in Chrome, then list the tabs exposed by the extension:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" tab-list
```

Navigate the controlled tab:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" goto "https://example.com"
```

Create another controlled tab:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" tab-new "https://example.com"
```

Use `goto` when a separate tab is unnecessary. Use snapshots, `find`, locators,
and `eval` to inspect the rendered page. Base answers only on browser-visible
state, and verify the final URL and result.

Use absolute paths for uploads, downloads, scripts, screenshots, and saved
state because the shared session runs from its neutral runtime directory.

Keep the session attached between related tasks. Disconnect only when the user
asks, or when troubleshooting requires a clean attachment:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" disconnect
```

`disconnect` maps to Playwright CLI `detach`, verifies that normal Chrome
remains running, and never closes the external browser. Disconnect after use
when minimizing token exposure is more important than session reuse.

## Diagnostics and recovery

Run `doctor` only for setup or connection failures, not before every task:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" doctor
```

Inspect active Playwright sessions before cleanup:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" cleanup-plan
```

Close only a named, non-attached Playwright browser from its owning workspace
with `playwright-cli -s=<name> close`. Detach an attached external browser.
Let ChatGPT browser control, ChromeDriver, and other test runners close their
own Chrome processes. Never use this skill to run `close-all`, `kill-all`, or a
machine-wide Chrome kill.

Check an existing owned session without taking a new connection:

```bash
"$SKILL_ROOT/scripts/playwright-cli-active.sh" ensure
```

`ensure` fails closed when the session is missing or stale. Only `connect`
performs a fresh attachment, and only after explicit user approval.

If the wrapper reports a missing or invalid token, ask the user to regenerate
and copy it in the extension, then run:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh"
```

If **Allow & select** appears despite a stored token, stop. The Keychain token
is stale or belongs to another Chrome profile. Ask the user to regenerate,
copy, and store it; do not wait silently or attempt to read extension storage.

If the helper page appears on every approved connection, run `doctor`. A
`missing` or `stale` session indicates that Chrome, the extension, or the daemon
is disconnecting between commands. Do not loop on `connect`. If it remains
visible after one fresh connection, report the cleanup failure rather than
treating it as a requested tab.

Do not use the Chrome remote-debugging checkbox, `attach --cdp`, another browser
tool, AppleScript, or a different browser unless the user explicitly authorizes
that fallback.

## Security

- Never print, log, return, or screenshot the extension token.
- Never store it in this skill, shell profiles, repositories, `.env` files, or
  terminal history.
- Never ask the user to paste it into chat, a file, or a command.
- Playwright CLI passes the extension token in a Chrome connection URL during
  attachment. If Chrome is not already running, that URL can remain in the
  long-lived Chrome process command line. The wrapper checks the complete
  normal Chrome PID set immediately before and after attachment, detaches on
  any change, and requires token rotation if the token appears in a persistent
  process.
- The upstream Playwright CLI daemon inherits the token-bearing attachment
  environment while the owned session is alive. Processes running as the same
  macOS user may be able to inspect it. Disconnect after use and prefer a
  separate Chrome profile for higher-risk automation.
- Keep the trusted CLI and macOS system-command paths under the desktop user's
  control; the wrapper rejects relative CLI paths and does not use `PATH` shims
  for secret-bearing system operations.
- To revoke this skill's stored-token access, delete the configured Keychain
  item and regenerate the extension token:

```bash
security delete-generic-password \
  -a "${PLAYWRIGHT_ACTIVE_CHROME_KEYCHAIN_ACCOUNT:-$(id -un)}" \
  -s "${PLAYWRIGHT_ACTIVE_CHROME_KEYCHAIN_SERVICE:-playwright-active-chrome.extension-token}"
```

If `doctor` reports `process-token: exposed`, complete all of these steps:

1. Disconnect the owned session.
2. Fully close normal Chrome so the token-bearing command line disappears.
3. While Chrome is closed, record a private, hash-only comparison baseline:

   ```bash
   "$SKILL_ROOT/scripts/playwright-cli-active.sh" begin-token-rotation
   ```

4. Reopen Chrome manually and regenerate the token from the extension icon.
5. Copy it with the extension button and immediately run
   `"$SKILL_ROOT/scripts/store-extension-token.sh"`.
6. Mark the current Chrome process as the one in which regeneration occurred:

   ```bash
   "$SKILL_ROOT/scripts/playwright-cli-active.sh" mark-token-regenerated
   ```

7. Fully quit and manually reopen Chrome again. This post-regeneration restart
   invalidates any client authorized with the previous token.
8. Verify the stored token changed and Chrome restarted without displaying
   either token:

   ```bash
   "$SKILL_ROOT/scripts/playwright-cli-active.sh" rotation-status
   ```

9. Require `rotation: VERIFIED`, `token: stored`, and
   `process-token: absent` before reconnecting.
