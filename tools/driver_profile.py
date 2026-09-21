"""Validate JSON driver fixtures and generate a historical build's parameter header."""
import json
import re
from pathlib import Path

DEFAULT = Path(__file__).resolve().parents[1] / "diagnostics/profiles/legacy-driver-version-1.json"


def driver_profile(path=DEFAULT):
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
        raise ValueError("Unsupported driver parameter schema")
    value = document["primary"]
    for field in ("executable", "probeExecutable"):
        if not isinstance(value[field], str) or not re.fullmatch(r"[a-z0-9._-]+\.exe", value[field]):
            raise ValueError("Invalid driver image")
    for field in ("matchVersion", "replacementVersion"):
        if not isinstance(value[field], list) or len(value[field]) != 4 or any(type(v) is not int or not 0 <= v <= 65535 for v in value[field]):
            raise ValueError("Invalid driver version")
    return value


def version_bits(parts):
    return "0x" + "".join(f"{part:04x}" for part in parts) + "ULL"


def header(path, profile):
    Path(path).write_text("\n".join([
        "/* Generated from JSON; do not edit. */",
        "#define GAMEKIT_LEGACY_PARAMETERS 1",
        "#define GAMEKIT_DRIVER_TARGET L" + json.dumps(profile["executable"]),
        "#define GAMEKIT_DRIVER_PROBE L" + json.dumps(profile["probeExecutable"]),
        "#define GAMEKIT_DRIVER_MATCH ((LONGLONG)" + version_bits(profile["matchVersion"]) + ")",
        "#define GAMEKIT_DRIVER_REPLACEMENT ((LONGLONG)" + version_bits(profile["replacementVersion"]) + ")",
        "",
    ]), encoding="utf-8")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, default=DEFAULT)
    parser.add_argument("--header", type=Path, required=True)
    args = parser.parse_args()
    header(args.header, driver_profile(args.profile))
