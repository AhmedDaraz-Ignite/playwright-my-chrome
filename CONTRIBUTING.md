# Contributing

Contributions are welcome.

## Development

This project intentionally has no runtime dependency installer. Install
`@playwright/cli` separately and keep its supported version synchronized across
the wrapper, skill instructions, README, tests, and CI.

Run all checks on macOS:

```bash
/bin/bash tests/lint.sh
/bin/bash tests/run.sh
npx skills@1.5.21 install . --list
```

Tests must use the isolated executables in `tests/mocks`. Do not use a real
extension token, macOS Keychain item, clipboard, or Chrome profile in automated
tests.

## Pull requests

- Explain the browser-control or security behavior being changed.
- Add a regression test for every safeguard or bug fix.
- Keep `SKILL.md` vendor-neutral and below 500 lines.
- Do not add tokens, screenshots of extension connection pages, cookies,
  browser profiles, or machine-specific paths.
- Preserve fail-closed behavior for unsupported CLI versions and ambiguous
  Chrome process state.

Security-sensitive reports belong in a private GitHub security advisory, as
described in [SECURITY.md](SECURITY.md).
