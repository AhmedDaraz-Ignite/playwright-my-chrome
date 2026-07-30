#!/usr/bin/env python3
from pathlib import Path
import os
import re
import sys


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


repo_root = Path(__file__).resolve().parents[1]
skill_dir = repo_root / "skills" / "playwright-my-chrome"
skill_file = skill_dir / "SKILL.md"
wrapper_file = skill_dir / "scripts" / "playwright-my-chrome.sh"
root_license = repo_root / "LICENSE"
skill_license = skill_dir / "LICENSE"
macos_home_prefix = "/" + "Users" + "/"
linux_home_prefix = "/" + "home" + "/"

if not skill_file.is_file():
    fail("SKILL.md is missing")

text = skill_file.read_text(encoding="utf-8")
lines = text.splitlines()
if len(lines) >= 500:
    fail(f"SKILL.md has {len(lines)} lines; expected fewer than 500")
if not lines or lines[0] != "---":
    fail("SKILL.md must start with YAML frontmatter")

try:
    end = lines.index("---", 1)
except ValueError:
    fail("SKILL.md frontmatter is not closed")

metadata: dict[str, str] = {}
for line in lines[1:end]:
    match = re.fullmatch(r"([a-z-]+):\s*(.+)", line)
    if not match:
        fail(f"unsupported frontmatter line: {line!r}")
    metadata[match.group(1)] = match.group(2)

if set(metadata) != {"name", "description"}:
    fail("frontmatter must contain exactly name and description")

name = metadata["name"]
description = metadata["description"]
if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
    fail("skill name does not satisfy the Agent Skills naming rule")
if name != skill_dir.name:
    fail("skill name must match its directory")
if not 1 <= len(description) <= 1024:
    fail("description must contain 1-1024 characters")

for path in skill_dir.rglob("*"):
    if path.is_symlink():
        fail(f"skill contains a symlink: {path.relative_to(skill_dir)}")
    if path.is_file() and path.stat().st_size > 1_000_000:
        fail(f"skill contains a file larger than 1 MB: {path.relative_to(skill_dir)}")

for script in (skill_dir / "scripts").iterdir():
    if script.is_file():
        if script.suffix != ".sh":
            fail(f"executable scripts must use .sh so scanners detect them: {script.name}")
        if not os.access(script, os.X_OK):
            fail(f"script is not executable: {script.name}")

for path in skill_dir.rglob("*"):
    if not path.is_file():
        continue
    content = path.read_text(encoding="utf-8")
    if macos_home_prefix in content or linux_home_prefix in content:
        fail(f"machine-specific home path found in {path.relative_to(skill_dir)}")
    if re.search(r"PLAYWRIGHT_MCP_EXTENSION_TOKEN=[A-Za-z0-9_-]{32,}", content):
        fail(f"token-shaped assignment found in {path.relative_to(skill_dir)}")

if not skill_license.is_file():
    fail("the installable skill must include its license")
if skill_license.read_bytes() != root_license.read_bytes():
    fail("the installable skill license must match the repository license")

for path in repo_root.rglob("*"):
    if not path.is_file():
        continue
    relative = path.relative_to(repo_root)
    if ".git" in relative.parts or "node_modules" in relative.parts:
        continue
    content = path.read_text(encoding="utf-8")
    if macos_home_prefix in content or linux_home_prefix in content:
        fail(f"machine-specific home path found in {relative}")
    if "\u2013" in content or "\u2014" in content:
        fail(f"forbidden Unicode dash found in {relative}")

wrapper_text = wrapper_file.read_text(encoding="utf-8")
version_match = re.search(r'^supported_cli_version="([^"]+)"$', wrapper_text, re.MULTILINE)
if not version_match:
    fail("wrapper does not declare its supported Playwright CLI version")
supported_version = version_match.group(1)
for documentation in (
    repo_root / "README.md",
    repo_root / "SECURITY.md",
    skill_file,
):
    if supported_version not in documentation.read_text(encoding="utf-8"):
        fail(f"{documentation.name} does not mention supported CLI {supported_version}")

print("Agent Skill validation passed.")
