# Ubisoft Connect: isolated launcher qualification

## Scope and provenance

The owner approved Ubisoft Connect as the next launcher after Steam. This is a
qualification of the Windows client on the current pinned Gamekit runtime, not
an authenticated game-library or gameplay result. No installed Steam prefix,
account data, or Gamekit launcher controls were used for the probe.

On 2026-09-29, Ubisoft's official [download page](https://www.ubisoft.com/en-us/ubisoft-connect/download)
linked to `https://ubi.li/4vxt9`, which redirected over HTTPS to
`https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe`.
The server reported `Content-Length: 264786072` and `Last-Modified: Tue, 01 Sep
2026 09:10:19 GMT`. The complete downloaded artifact had SHA-256
`2df8790f7a4aba803dd140ff20e45a55f60d1c7fe3bd34709b4519bcb5c5e3e7`.
It is an x86 Windows PE NSIS self-extracting installer. TLS provenance, the PE
format, and a recorded digest do not independently authenticate its publisher
or guarantee the next download will contain the same build.

## Isolated runtime observation

The disposable Wine prefix was under
`/var/folders/qc/4lbpvxwj7pn5_675mjffljrr0000gn/T/opencode/gamekit-ubisoft-qualify-prefix`.
The selected Sikarugir 10.0 / driver-version-1 runtime reported Windows
`10.0.19043` during `wine cmd /c ver`. The installer returned exit code zero
with `/S` and created `drive_c/Program Files (x86)/Ubisoft/Ubisoft Game
Launcher/UbisoftConnect.exe`, `upc.exe`, `UplayWebCore.exe`, and companion
services. The installed client's `version.txt` contained `13333`; the fresh
prefix occupied about 797 MiB. The executable's presence alone is not a
readiness check.

Launching `UbisoftConnect.exe` under that same isolated prefix handed off to
`upc.exe -upc_desktop_mode` and multiple `UplayWebCore.exe` renderer,
network, storage, GPU, and media helpers. A native `Ubisoft Connect` window
(1454 × 934 points) and the process group remained observable after 20 seconds.
Its authenticated UI and actual game launching were not exercised. The
disposable prefix's own `wineserver -k` stopped this probe; no other Wine or
Steam session was signalled. Raw client logs and screen captures are not
included here.

## Integration gates

- Give Ubisoft Connect an independent registered environment, prefix, session
  receipt, validated executable, and scoped lifecycle. Existing metadata and
  observation APIs still call their executable `steamExecutable` and identify
  Steam client/web-helper roles. Never route a Ubisoft process through Steam's
  lifecycle, reset, or game-action methods.
- Permit the observed official installer endpoint with an appropriate bounded
  size. Steam's downloader currently allows only its exact 32 MiB source and
  writes into a shared download directory; the Ubisoft artifact is about
  265 MB. Keep acquisition policy and launcher execution parameters in
  validated launcher JSON, with per-launcher receipts and no permissive
  cross-host redirect policy.
- An unsigned-in client has no authoritative owned-game catalog. Validate
  installed-game IDs, names, paths, and local receipt format after the owner
  signs in and installs a game in the *persistent, isolated managed Ubisoft
  environment*. Do not infer ownership from generic game folders or ship
  sample Ubisoft games. No credentials are requested or stored by Gamekit.
- Verify the managed client can survive ordinary Gamekit Quit without
  duplicating or misnaming its macOS Dock entry, and that Stop targets only
  its own tagged Wine processes. The isolated direct-Wine probe does not
  establish either property.

This qualifies installer execution and a bounded client startup path, while
full integration remains gated by owned lifecycle and signed-in game evidence.

## Managed-path follow-up

The separately registered setup now loads its installer/executable/process
contract from `Sources/GamekitCore/LauncherProfiles/ubisoft.json` and uses
per-launcher download receipts. An opt-in run with that same locally verified
installer, the owner's selected Sikarugir driver-version-1 runtime, and a
fresh disposable Gamekit metadata root installed version `13333`. The
coordinator observed both the scoped client and web-helper roles for three
continuous seconds, stopped installation bootstrap, and recorded the Ubisoft
environment independently of Steam. A replacement lifecycle controller then
started the derived **Ubisoft Connect.app** identity, observed an owned client
and web helper for three seconds, verified a client PID for Show, and stopped
the selected prefix, clearing only its `ubisoft.json` lifecycle receipt.
No account was used and no user-owned Wine processes were signalled. This is
launcher readiness evidence; a signed-in game catalog and actual gameplay
remain unverified.

The separate opt-in production acquisition path also streamed the full
264,786,072-byte official installer over HTTPS into its own disposable
receipt directory, validated the pinned SHA-256 on download and reopen, and
did not execute that downloaded copy. The download and validation completed
in about 14 seconds on the qualification host; the client can still update
later, so the pinned hash is rechecked at every new installation.
