"""Export only game AppIDs/names from a Steam license listing and local appinfo.

Input files stay private. Never publish console logs, account IDs, PICS tokens,
purchase history, licensecache, localconfig, achievements or playtime.
Format reference: https://github.com/SteamDatabase/SteamAppInfo (v40/v41).
"""
import argparse
import io
import json
from pathlib import Path
import re
import struct


def licensed_apps(text):
    # Steam appends console output. A new listing begins with its default
    # package; never union an older account/library snapshot into the latest.
    starts = list(re.finditer(r"(?m)^.*License packageID 0:\s*$", text))
    if starts:
        text = text[starts[-1].start():]
    apps, current = set(), set()
    active = False
    in_apps = False
    for raw in text.splitlines() + ["License packageID END:"]:
        line = re.sub(r"^\[[^\]]*\]\s*", "", raw).strip()
        if line.startswith("License packageID "):
            if active:
                apps.update(current)
            current, active, in_apps = set(), False, False
        elif line == "Active" or re.fullmatch(r"- State\s*:\s*Active", line):
            active = True
        elif re.match(r"- Apps\s*:", line):
            in_apps = True
            current.update(int(x) for x in re.findall(r"\d+", line.split(":", 1)[1]))
        elif line.startswith("-") or "in total" in line:
            in_apps = False
        elif in_apps and re.fullmatch(r"[\d,\s]+", line):
            current.update(int(x) for x in re.findall(r"\d+", line))
    if not apps:
        raise ValueError("No active license app listing; run licenses_print in Steam's console")
    return apps


class Reader:
    def __init__(self, data):
        self.stream = io.BytesIO(data)

    def read(self, size):
        data = self.stream.read(size)
        if len(data) != size:
            raise ValueError("Truncated appinfo")
        return data

    def number(self, fmt):
        return struct.unpack(fmt, self.read(struct.calcsize(fmt)))[0]

    def string(self):
        result = bytearray()
        for _ in range(1_048_576):
            byte = self.read(1)
            if byte == b"\0":
                return result.decode("utf-8", errors="strict")
            result.extend(byte)
        raise ValueError("Oversized appinfo string")

    def kv(self, keys=None, depth=0):
        if depth > 32:
            raise ValueError("Excessive KeyValues nesting")
        result = {}
        while True:
            kind = self.number("<B")
            if kind == 8:
                return result
            if keys is None:
                key = self.string()
            else:
                index = self.number("<I")
                if index >= len(keys):
                    raise ValueError("Invalid string table reference")
                key = keys[index]
            if kind == 0:
                value = self.kv(keys, depth + 1)
            elif kind == 1:
                value = self.string()
            elif kind in (2, 3, 4, 6, 7, 10):
                value = self.number({2: "<i", 3: "<f", 4: "<I", 6: "<I", 7: "<Q", 10: "<q"}[kind])
            else:
                raise ValueError(f"Unsupported KeyValues type {kind}")
            result[key] = value


def appinfo(data):
    if len(data) > 128 * 1024 * 1024:
        raise ValueError("Oversized appinfo")
    reader = Reader(data)
    version = reader.number("<I")
    if version not in (0x07564428, 0x07564429) or reader.number("<I") != 1:
        raise ValueError("Unsupported appinfo format/universe")
    keys = None
    if version == 0x07564429:
        table = reader.number("<Q")
        if not 16 <= table < len(data):
            raise ValueError("Invalid string table offset")
        table_reader = Reader(data[table:])
        count = table_reader.number("<I")
        if count > 1_000_000:
            raise ValueError("Oversized string table")
        keys = [table_reader.string() for _ in range(count)]
    result = {}
    while True:
        app_id = reader.number("<I")
        if not app_id:
            return result
        size = reader.number("<I")
        if size < 60 or size > 16 * 1024 * 1024:
            raise ValueError("Invalid app entry size")
        # Skip metadata, including private access tokens; do not expose it.
        reader.read(60)
        result[app_id] = Reader(reader.read(size - 60)).kv(keys).get("appinfo", {})


def catalog(licensed, metadata):
    missing = sorted(licensed - metadata.keys())
    if missing:
        raise ValueError(f"Missing appinfo for {len(missing)} licensed apps: {missing}")
    games = []
    for app_id in licensed:
        common = metadata[app_id].get("common", {})
        if str(common.get("type", "")).lower() != "game":
            continue
        name = common.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"Game {app_id} has no title")
        games.append({"app_id": app_id, "name": name})
    return sorted(games, key=lambda game: (game["name"].casefold(), game["app_id"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--licenses", required=True, type=Path)
    parser.add_argument("--appinfo", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    metadata = {}
    for path in args.appinfo:
        metadata.update(appinfo(path.read_bytes()))
    games = catalog(licensed_apps(args.licenses.read_text(encoding="utf-8")), metadata)
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(games, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(f"Exported {len(games)} licensed games (AppID/name only)")


if __name__ == "__main__":
    main()
