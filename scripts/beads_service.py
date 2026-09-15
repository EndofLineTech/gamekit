#!/usr/bin/env python3
"""Manage the personal Gamekit Beads service and its public GitHub backup."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time


HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/Gamekit/Beads"
SETTINGS = SUPPORT / "service.json"
REMOTE = "git+https://github.com/EndofLineTech/gamekit.git"
LABEL = "tech.endofline.gamekit.dolt"
BACKUP_LABEL = "tech.endofline.gamekit.beads-backup"


def run(args, cwd=None):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300,
    )
    if result.returncode:
        raise RuntimeError(f"Command failed: {' '.join(map(str, args))}\n{result.stderr}{result.stdout}")
    return result.stdout


def settings():
    return json.loads(SETTINGS.read_text())


def connection(config):
    return [config["dolt"], "--host", "127.0.0.1", "--port", "3307",
            "--no-tls", "--use-db", config["database"]]


def query(command, sql, cwd=None):
    return json.loads(run([*command, "sql", "-r", "json", "-q", sql], cwd))["rows"]


def wait_for_server(config):
    for attempt in range(30):
        try:
            query(connection(config), "SELECT COUNT(*) AS count FROM issues")
            return
        except (RuntimeError, json.JSONDecodeError):
            if attempt == 29:
                raise
            time.sleep(1)


def install(repo):
    repo = repo.resolve()
    metadata = json.loads((repo / ".beads/metadata.json").read_text())
    database = metadata["dolt_database"]
    data = repo / ".beads/dolt"
    if not (data / database / ".dolt").is_dir():
        raise RuntimeError("Expected an existing initialized Beads database; restore it first.")
    dolt = shutil.which("dolt")
    if not dolt:
        raise RuntimeError("dolt must be installed and on PATH")
    # Do not start a second writer or silently replace someone else's service.
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 3307)) == 0:
            raise RuntimeError("Port 3307 is occupied. Stop the identified server before installing.")
    agents = HOME / "Library/LaunchAgents"
    for label in (LABEL, BACKUP_LABEL):
        if (agents / f"{label}.plist").exists():
            raise RuntimeError(f"Agent {label} already exists; follow the documented reinstall procedure.")
    SUPPORT.mkdir(parents=True, exist_ok=True)
    agents.mkdir(parents=True, exist_ok=True)
    config = {"dolt": dolt, "database": database, "data": str(data), "repo": str(repo)}
    SETTINGS.write_text(json.dumps(config, indent=2) + "\n")
    helper = SUPPORT / "beads_service.py"
    shutil.copyfile(__file__, helper)
    environment = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOME": str(HOME), "GIT_TERMINAL_PROMPT": "0"}
    server = {
        "Label": LABEL,
        "ProgramArguments": [dolt, "sql-server", "--host", "127.0.0.1", "--port", "3307",
                             "--data-dir", str(data), "--loglevel", "warning"],
        "WorkingDirectory": str(data), "EnvironmentVariables": environment,
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
        "StandardOutPath": str(SUPPORT / "server.log"),
        "StandardErrorPath": str(SUPPORT / "server.log"),
    }
    backup = {
        "Label": BACKUP_LABEL,
        "ProgramArguments": [sys.executable, str(helper), "backup"],
        "EnvironmentVariables": environment, "WorkingDirectory": str(SUPPORT),
        "RunAtLoad": True, "StartInterval": 3600,
        "StandardOutPath": str(SUPPORT / "backup.log"),
        "StandardErrorPath": str(SUPPORT / "backup.log"),
    }
    for agent in (server, backup):
        path = agents / f"{agent['Label']}.plist"
        path.write_bytes(plistlib.dumps(agent))
        run(["plutil", "-lint", path])
    domain = f"gui/{os.getuid()}"
    run(["launchctl", "bootstrap", domain, agents / f"{LABEL}.plist"])
    wait_for_server(config)
    run(["launchctl", "bootstrap", domain, agents / f"{BACKUP_LABEL}.plist"])
    print("Installed login startup, crash restart, and hourly backups.")


def backup():
    config = settings()
    with (SUPPORT / "backup.lock").open("w") as lock:
        # launchd and a manual invocation may overlap. Only one sync at a time.
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            wait_for_server(config)
            backups = query(connection(config), "SELECT * FROM dolt_backups")
            target = next((item for item in backups if item["name"] == "github"), None)
            if target is None or target["url"] != REMOTE:
                raise RuntimeError("Expected github backup URL is missing or changed; refusing to upload.")
            run([*connection(config), "backup", "sync", "github"])
            report = {"ok": True, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "remote": REMOTE, "ref": "refs/dolt/data"}
        except Exception as error:
            report = {"ok": False, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "error": str(error)}
            raise
        finally:
            if "report" in locals():
                temporary = SUPPORT / "backup-status.tmp"
                temporary.write_text(json.dumps(report, indent=2) + "\n")
                temporary.replace(SUPPORT / "backup-status.json")
        print(json.dumps(report), flush=True)


def restore(destination):
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("Restore destination must not exist. Live data is never overwritten.")
    if not destination.parent.is_dir():
        raise RuntimeError("Restore destination parent must already exist.")
    dolt = shutil.which("dolt")
    if not dolt:
        raise RuntimeError("dolt must be installed and on PATH")
    # 2.3.4 needs a repository-local Git cache even for backup restore.
    # This scratch repo is independent of the live service and deleted afterward.
    with tempfile.TemporaryDirectory(prefix="gamekit-dolt-restore-") as scratch:
        run([dolt, "init", "--name", "Gamekit recovery", "--email", "recovery@localhost"], scratch)
        # This version accepts a database name here, not an absolute path.
        run([dolt, "backup", "restore", REMOTE, "restored"], scratch)
        # The restored database is offline. copytree refuses an existing target,
        # including one created after the preflight check, and works across disks.
        shutil.copytree(Path(scratch) / "restored", destination)
    print(f"Restored snapshot to {destination}")


def verify():
    config = settings()
    backup()
    sql = "SELECT DOLT_HASHOF_DB('WORKING') AS root_hash"
    source = query(connection(config), sql)
    with tempfile.TemporaryDirectory(prefix="gamekit-beads-verify-") as scratch:
        destination = Path(scratch) / "restored"
        restore(destination)
        restored = query([config["dolt"]], sql, destination)
        if source != restored or source != query(connection(config), sql):
            raise RuntimeError("Snapshot hash mismatch or live board changed during verification; retry while idle.")
        for statement in (
            # Remote and embedded Dolt JSON encode numeric aggregates differently.
            "SELECT issue_type, CAST(COUNT(*) AS CHAR) AS count FROM issues GROUP BY issue_type ORDER BY issue_type",
            "SELECT type, CAST(COUNT(*) AS CHAR) AS count FROM dependencies GROUP BY type ORDER BY type",
            "SELECT commit_hash FROM dolt_log ORDER BY commit_hash",
        ):
            if query(connection(config), statement) != query([config["dolt"]], statement, destination):
                raise RuntimeError(f"Restore mismatch: {statement}")
        print(f"PASS: restored working-set hash, issue/dependency counts and current-branch history match: {source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install-service")
    install_parser.add_argument("--repo", type=Path, required=True)
    commands.add_parser("backup")
    commands.add_parser("verify-restore")
    restore_parser = commands.add_parser("restore")
    restore_parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.command == "install-service":
        install(args.repo)
    elif args.command == "backup":
        backup()
    elif args.command == "restore":
        restore(args.destination)
    else:
        verify()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
