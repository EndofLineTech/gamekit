# Steam installer acquisition

E4.1 (`gamekit-ftm.1`) supplies the core download and artifact-validation API for
the subsequent installation coordinator. It downloads Windows Steam from the
HTTPS installer link on [Valve's About page](https://store.steampowered.com/about/):

```text
https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe
```

## Usage

```swift
let acquisition = try SteamInstallerAcquisition()
let artifact = try await acquisition.acquire()
// Persist artifact.id with coordinator progress when installation is implemented.
let installerURL = try await acquisition.validatedURL(for: artifact)
// The installation coordinator can now pass this path as a literal Wine argument.
```

`acquire()` returns only after the complete response passes validation and both
artifact and receipt have been published. `InstallerArtifact.provenance` uses the
existing `InstallerProvenance` type: original source URL, SHA-256 and download
timestamp. The receipt additionally records schema version 1, a generated artifact
UUID, the final response URL and byte count. Dates use Foundation's default Codable
Date representation (seconds since 2001-01-01 UTC).

After restart, `load(id)` reads the receipt and rechecks the stored bytes. Call
`validatedURL(for:)` immediately before use; it reloads the receipt, checks equality
with the supplied artifact, verifies length/hash and repeats PE validation. Never
launch a file found by scanning the download directory or trust a decoded receipt
alone. Acquisition itself does not execute the installer or change a Wine prefix.

## Network policy

- Use a fresh ephemeral URLSession with ordinary system TLS certificate validation.
- Disable cookie storage, credential storage and URL caching. Do not resume or
  combine partial downloads from earlier attempts.
- Follow at most five redirects, and only to the exact approved HTTPS host/path.
  Port 443 is allowed; other ports, credentials, query strings and fragments are
  rejected. Requests are rebuilt on redirect rather than forwarding arbitrary
  headers. A new CDN endpoint requires a reviewed policy change.
- Require HTTP 200, no Content-Range, and an identity/unencoded response. Partial
  responses, error pages and compressed HTTP representations are not accepted.
- Limit captured download data to **32 MiB**, checking both declared length and
  received bytes. Check the final byte count against Content-Length when provided.
- Use a 30-second request timeout and 120-second resource timeout. Cancellation
  propagates through the async transfer; the session is invalidated on every exit.

Missing Content-Length is supported: the transfer must complete normally and fit
the byte cap. Transport errors, including disconnects after partial delivery,
produce no completed artifact. Retrying starts a fresh request from byte zero.

## Validation and trust

The trust source is the official HTTPS endpoint authenticated by the system TLS
stack. This implementation does **not** independently verify Windows Authenticode
signatures. A freshly calculated SHA-256 identifies the acquired bytes and detects
later changes relative to the saved receipt; it is not an externally authenticated
digest or a publisher signature.

Before publication, structural validation requires DOS/PE signatures, a bounded
header and section table, x86 PE32 or x64 PE32+ executable characteristics (not a
DLL), and in-file raw section ranges. A declared certificate-table range must also
fit within the file. These checks reject obvious wrong-format/truncated artifacts;
they do not prove NSIS payload correctness or successful installation. A server
that deliberately serves a structurally valid but incorrect executable is outside
what these format checks can detect.

## Storage, interruption and ownership

The default data root is `~/Library/Application Support/Gamekit`. Downloads use a
dedicated directory, preserving the manually evaluated artifacts:

```text
InstallerDownloads/
  .acquisition.lock
  <artifact-uuid>.exe
  <artifact-uuid>.json
```

Downloads accumulate in bounded memory, not an executable partial file. The shared
descriptor-relative storage layer saves the complete validated bytes atomically
with mode 0600, then publishes the receipt as the final commit marker. The metadata
document size limit remains 1 MiB; only installer binary I/O opts into the 32 MiB
limit. Newly created managed directories use mode 0700.

An actor guard and cross-instance filesystem lease reject concurrent acquisition
with `EnvironmentStoreError.busy`. Publication rechecks directory identity; a
replacement directory is not silently used. Symlinks and non-regular artifact or
receipt files are refused.

Failed receipt publication removes the executable created by that attempt. A
process crash between executable and receipt publication may leave a complete but
receiptless file; `load` refuses it. A retry works independently with a fresh UUID.
Strictly named abandoned `.installer-<uuid>.tmp` files are reclaimed under the
acquisition lease. Other files and previous completed downloads are preserved.
Automatic completed-artifact retention is not provided by this API.

The receipt and artifact are cooperatively owned local files, not a sandbox against
another process running as the same user. The final path-based Wine launch still
has a check/use interval; the coordinator must not treat a returned URL as a
permanent capability. Atomic replacement is not a full power-loss durability claim.

## Verification

Normal `make check` uses temporary roots and URLProtocol HTTP fixtures. Tests cover
successful publication/reopening, tampering, unsafe paths, missing receipts,
redirect rejection/header handling, size limits without Content-Length, invalid
statuses/encoding/ranges, partial and interrupted transfers, active cancellation,
same-instance/cross-instance contention, retry, orphan cleanup, malformed PE
structures and directory replacement during acquisition.

The opt-in real-source test downloads and validates without launching anything:

```bash
GAMEKIT_INSTALLER_SMOKE=1 swift test --filter officialInstaller
```

Verified on the target macOS 27/Xcode 27 host on 2026-09-15 (local date):

- 2,380,800 bytes from the official URL above.
- SHA-256 `7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb`.
- Saved receipt and artifact reopened and revalidated successfully.
- The hash matches the E2 manual installer; it is evidence, not a pinned allowlist.

The fixture is removed after the test. Normal CI does not contact Valve, install
Steam, or use authenticated Steam environments.
