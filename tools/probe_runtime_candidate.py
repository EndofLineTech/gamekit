#!/usr/bin/env python3
"""Run one bounded candidate probe in a new private home/prefix, with scoped stop."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid
import shutil

from stage_runtime_candidate import digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--host-observer", type=Path)
    parser.add_argument("--variant")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if not arguments or not 1 <= args.timeout <= 180 or args.output.exists():
        parser.error("Supply a command, bounded timeout, and fresh output directory")
    runtime = args.runtime.resolve(strict=True)
    profile = json.loads(args.profile.read_text())
    variant = profile.get("variants", {}).get(args.variant, {}) if args.variant else {}
    if args.variant and not variant:
        parser.error("Unknown qualification variant")
    receipt = json.loads((runtime / "gamekit-intake.json").read_text())
    if receipt["archiveSHA256"] != profile["archiveSHA256"]:
        raise ValueError("Candidate does not match intake receipt")
    args.output.mkdir()
    root = args.output.resolve()
    prefix = root / "prefix"; prefix.mkdir()
    home = root / "home"; home.mkdir()
    temporary = root / "tmp"; temporary.mkdir()
    token = str(uuid.uuid4())
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(temporary),
                   "WINEPREFIX": str(prefix), "GAMEKIT_CANDIDATE_SESSION": token, "LANG": "en_US.UTF-8"}
    if set(environment).intersection(profile["environment"]):
        raise ValueError("Candidate profile cannot override the private execution scope")
    environment.update({key: value.format(runtime=runtime, prefix=prefix) for key, value in profile["environment"].items()})
    environment["XDG_CACHE_HOME"] = str(home / ".cache")
    if args.host_observer:
        environment["DYLD_INSERT_LIBRARIES"] = str(args.host_observer.resolve(strict=True))
        environment["GAMEKIT_NATIVE_RECEIPT"] = str(root / "native-host.tsv")
    wine = runtime / profile["wine"]; server = runtime / profile["wineserver"]
    for executable in (wine, server):
        if not executable.resolve().is_relative_to(runtime):
            raise ValueError("Candidate executable escapes runtime")
    if variant.get("prefixFiles"):
        with (root / "bootstrap.log").open("wb") as log:
            try:
                bootstrap = subprocess.run([str(wine), "wineboot.exe", "-u"], env=environment, cwd=root,
                                           stdout=log, stderr=subprocess.STDOUT, timeout=90)
                if bootstrap.returncode:
                    raise ValueError("Private prefix bootstrap failed")
            finally:
                subprocess.run([str(server), "-k"], env=environment, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=15)
                subprocess.run([str(server), "-w"], env=environment, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=15)
        hashes = {name.removeprefix("./"): value for value, name in
                  (line.split("  ", 1) for line in (runtime / "metadata/SHA256SUMS").read_text().splitlines())}
        for destination, source in variant["prefixFiles"].items():
            origin = runtime / source; target = prefix / destination
            if not origin.resolve().is_relative_to(runtime) or not target.parent.resolve().is_relative_to(prefix):
                raise ValueError("Prefix staging path escapes qualification scope")
            if digest(origin) != hashes.get(source):
                raise ValueError("Staged provider differs from the verified archive")
            temporary_file = target.with_name(".gamekit-stage-" + uuid.uuid4().hex)
            with origin.open("rb") as input_file, temporary_file.open("xb") as output_file:
                shutil.copyfileobj(input_file, output_file)
            os.replace(temporary_file, target)  # Replace prefix link, never its runtime inode.
    if set(environment).intersection(variant.get("environment", {})) - set(profile["environment"]):
        raise ValueError("Variant cannot replace execution scope")
    environment.update({key: value.format(runtime=runtime, prefix=prefix) for key, value in variant.get("environment", {}).items()})
    started = time.monotonic()
    result = {"candidate": profile["candidate"], "variant": args.variant, "session": token, "arguments": arguments, "timedOut": False}
    with (root / "stdout.log").open("wb") as stdout, (root / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen([str(wine)] + arguments, env=environment, cwd=root,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        result["pid"] = process.pid
        try:
            result["exitCode"] = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            result["timedOut"] = True
        finally:
            # No shared/home prefix is ever passed to the server control command.
            with (root / "stop.log").open("wb") as stop_log:
                try:
                    stopped = subprocess.run([str(server), "-k"], env=environment, cwd=root,
                        stdout=stop_log, stderr=subprocess.STDOUT, timeout=15)
                    result["serverStopExit"] = stopped.returncode
                    waited = subprocess.run([str(server), "-w"], env=environment, cwd=root,
                        stdout=stop_log, stderr=subprocess.STDOUT, timeout=15)
                    result["serverWaitExit"] = waited.returncode
                except subprocess.TimeoutExpired:
                    result["serverStopExit"] = "timeout"
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
            result["exitCode"] = process.returncode
    result["elapsedSeconds"] = round(time.monotonic() - started, 3)
    (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
