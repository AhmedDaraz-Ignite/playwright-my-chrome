# Contributing

Pull requests are welcome. This page lists what a change is checked against
before it merges.

## Development

This project has no runtime dependency installer, on purpose. Install
`@playwright/cli` separately, and keep its supported version the same in the
wrapper, the skill instructions, the README, the tests, and CI. Those five
places drift apart as soon as one of them is updated alone.

Run all checks on macOS:

```bash
/bin/bash tests/lint.sh
/bin/bash tests/run.sh
npx skills@1.5.21 install . --list
```

Tests must use the fake executables in `tests/mocks`. No test may touch a real
extension token, Keychain item, clipboard, or Chrome profile. A suite that needs
a real browser to pass is a suite nobody can trust.

## Testing a change against a real browser

`npx skills install` copies the skill directory. It does not link to it. An
installed copy therefore goes stale the moment `scripts/` changes, and running
the installed wrapper would test the old code without saying so.

Reinstall before any manual check against real Chrome:

```bash
npx skills install . --skill playwright-my-chrome --global \
  --agent codex --agent claude-code
```

Then run the wrapper from the installed path, not from this repository, so the
check covers what a user actually gets.

## Pull requests

- Say which browser-control or security behavior changes, and why.
- Add a regression test for every safeguard and every bug fix. This one is not
  waived.
- Keep `SKILL.md` vendor-neutral and under 500 lines. It has to stay readable by
  any agent, not only the one you use.
- Do not add tokens, screenshots of extension connection pages, cookies, browser
  profiles, or machine-specific paths.
- Keep the fail-closed behavior for unsupported CLI versions and for unclear
  Chrome process state. If a change touches one of those paths, explain what
  happens on the failure branch.

Found something security sensitive? Do not open a pull request for it. Use a
private GitHub security advisory, as described in [SECURITY.md](SECURITY.md).
