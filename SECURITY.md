# Security policy

## Reporting a vulnerability

Use this repository's **Security → Report a vulnerability** flow. Do not open a
public issue for a suspected token leak, browser-control bypass, command
injection, or unsafe cleanup behavior.

Include the affected commit or release, macOS and Chrome versions, Playwright
CLI version, reproduction steps, and whether any real extension token was
exposed. Never include a live extension token, cookie, or session secret in the
report.

## Security boundary

This skill intentionally grants a local coding agent substantial access:

- The Playwright Extension can expose signed-in browser tabs and their content.
- The wrapper retrieves one extension authentication token from macOS Keychain
  when the user explicitly approves a fresh connection or runs explicit
  token-rotation verification.
- Browser commands run with the permissions of the logged-in macOS user.
- The skill invokes the separately installed `@playwright/cli` executable.

The agent, the repository containing the user's task, the installed Playwright
CLI, the Playwright Extension, Chrome, and the local macOS account are all
trusted components. This skill does not make an untrusted agent safe.

## Defenses

- The token is never accepted as a command-line argument.
- The setup helper reads it from the clipboard, stores it in Keychain, and
  clears the clipboard after success.
- Secret-bearing operations use fixed macOS system executables rather than
  caller-controlled `PATH` entries.
- Runtime directories must be private, owned by the current user, non-symlinked,
  and explicitly claimed by the wrapper.
- Cleanup metadata is atomically replaced, must be a private regular file, and
  can identify only one strict direct-child output directory.
- Browser launch and machine-wide cleanup commands are blocked.
- A fresh connection requires an already-running normal Chrome process.
- Exactly one normal Chrome main process is allowed, and the complete PID set is
  rechecked immediately before and after attachment.
- A changed PID set or token-bearing Chrome process causes a fail-closed detach
  and requires token rotation.
- Attachment is limited to 60 seconds. Timeout handling terminates the exact CLI
  child and its direct descendants, attempts named-session detachment, reports
  any detachment failure, scrubs private artifacts, and requires token rotation.
- The public release pins the supported `@playwright/cli` version.
- Development CLI dependencies are exact and integrity-locked.

## Residual risks

- Any connected agent can perform actions the signed-in user could perform in
  exposed tabs.
- Browser or extension vulnerabilities remain outside this project's control.
- A malicious replacement for the trusted Playwright CLI can access the token
  supplied to it during attachment.
- The upstream Playwright CLI daemon inherits the token-bearing attachment
  environment while the owned session is alive. Other processes running as the
  same macOS user may be able to inspect that environment. `disconnect` limits
  this exposure window but cannot remove this upstream behavior.
- Process checks reduce the Chrome-launch race but cannot make cross-process
  inspection atomic.
- macOS Keychain access may display an operating-system authorization prompt,
  depending on local Keychain policy.

Use a separate Chrome profile for higher-risk automation. Disconnect the skill,
delete its Keychain item, and regenerate the Playwright Extension token whenever
you suspect exposure.

## Supported versions

Security fixes are provided for the latest tagged release. The initial release
supports `@playwright/cli` 0.1.17 exactly and fails closed for browser commands
under other versions.
