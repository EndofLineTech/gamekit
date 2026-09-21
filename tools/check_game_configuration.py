#!/usr/bin/env python3
"""Reject game execution values embedded in code instead of parameter JSON."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = {".swift", ".m", ".mm", ".c", ".cpp", ".h", ".py", ".cjs"}


def configured_values(root):
    tokens = set()
    for directory in ("Sources/GamekitCore/GameProfiles", "diagnostics/profiles", "tests/fixtures"):
        for path in (root / directory).glob("*.json"):
            def visit(value, key=""):
                if isinstance(value, dict):
                    for name, child in value.items():
                        visit(child, name)
                elif isinstance(value, list):
                    if key == "replacementVersion" and len(value) == 4:
                        tokens.add("".join(f"{part:04x}" for part in value))
                    for child in value:
                        visit(child, key)
                elif isinstance(value, str) and (key == "executable" or value.startswith("-")):
                    tokens.add(value.lower())
            visit(json.loads(path.read_text(encoding="utf-8")))
    return tokens


def violations(root=ROOT):
    tokens = configured_values(root)
    identities = {str(value["appId"]) for value in json.loads((root / "diagnostics/profiles/games.json").read_text()).values()
                  if isinstance(value, dict) and "appId" in value}
    result = []
    for directory in ("App", "Sources", "diagnostics", "tools", "tests", "UITests"):
        for path in (root / directory).rglob("*"):
            if path.suffix not in EXTENSIONS or "__pycache__" in path.parts:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                # Documentation/comments describe evidence, not execution inputs.
                text = re.sub(r"//.*$", "", line).lower()
                if text.lstrip().startswith(("# ", "*", "/*")):
                    continue
                for token in tokens:
                    present = re.search(r'''(["'])''' + re.escape(token) + r'''\1''', text) if token.startswith("-") else token in text
                    if present:
                        result.append(f"{path.relative_to(root)}:{number}: parameter {token!r} belongs in JSON")
                if directory in {"App", "Sources", "diagnostics", "tools"}:
                    for identity in identities:
                        if re.search(r"(?<![a-z0-9])" + identity + r"(?![a-z0-9])", text):
                            result.append(f"{path.relative_to(root)}:{number}: game selector {identity} belongs in JSON")
    return result


if __name__ == "__main__":
    failures = violations()
    if failures:
        raise SystemExit("\n".join(failures))
    print("Game-configuration audit passed: execution values are loaded from JSON")
