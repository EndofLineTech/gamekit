# Developer ID signing and runtime trust inventory (v1)

Issue: `gamekit-lon.2`. Inventory date: 2026-10-01. Source: `dev` at
`ed0fe40` (the Game Mode PR #104 is merged). This is a **pre-distribution
inventory**, not a signed release or a successful external-runtime qualification.
No production signing, Apple notarization submission, runtime mutation, or prefix
modification was performed for this inventory.

## Release authority and scope

The owner confirmed direct-download distribution by team `EWT2X7Q9ZJ`, a valid
local **Developer ID Application** signing identity with its private key, and
successful validation of the locally stored `gamekit-release` notarytool Keychain
profile. The Mac's existing **Apple Development** identity is from another team,
`SH39L4QQQH`; it is not a distribution identity. The release path must explicitly
select the intended Developer ID team, verify the team on **each** shipped signature,
and smoke-test application identity and persisted settings when moving from local
ad-hoc/development builds to that team. The private key and notary credentials stay
in the owner release Mac Keychain, not in the repository or CI.

The DMG will contain Gamekit, documentation and source/license notices, **not**
the separately obtained Sikarugir Wine/template or Apple D3DMetal, nor Steam or
Ubisoft Connect installers, clients, games or generated Wine application caches.
During setup, Gamekit retrieves the Steam and Ubisoft Connect installers from
their respective vendors' configured endpoints and verifies the pinned bytes;
games are acquired through the vendor clients. The bundled, Gamekit-built Ubisoft
Wine compatibility module listed below is **not** a redistributed Ubisoft client.
The owner confirmed authorization to use the external runtime components on the
acceptance device and access to a clean macOS 27 Apple-silicon installation and
live Steam/gameplay acceptance. Neither the app certificate nor its notarization
authenticates those subsequently retrieved files.

## Shipped app: observed local artifact

From this source, `xcodebuild ... -configuration Release ... archive` produced
an ad-hoc `Gamekit.xcarchive` with `Products/Applications/Gamekit.app`, plus
`dSYMs/` (not an app payload). `project.yml` embeds two built targets in the app
with `SKIP_INSTALL=YES`, so the archive's Products directory contains only
Applications. The app's bundle identifier remains `tech.endofline.gamekit`;
minimum OS is 27.0. `Contents/MacOS/`, `Contents/Frameworks/`, and the SwiftPM
resource bundle were inspected individually. These are **all four observed
Mach-O files** in the app, including the non-obvious library in Resources:

| App-relative path | Architecture / role | Current archive signature | Distribution disposition |
| --- | --- | --- | --- |
| `Contents/MacOS/Gamekit` | arm64 GUI executable | ad-hoc; no Team ID / Hardened Runtime / secure timestamp | Developer ID Application + timestamp + Hardened Runtime; no unproven exceptions |
| `Contents/MacOS/GamekitProcessCounters` | arm64 read-only tool | ad-hoc; no Team ID / Hardened Runtime / secure timestamp | Same team, timestamp, Hardened Runtime; no runtime exceptions evidenced |
| `Contents/Frameworks/WineGameIdentity.dylib` | x86_64 Wine-side in-process identity library | ad-hoc; no Team ID / timestamp | Same team and timestamp; **no executable entitlements**; host Wine process controls library loading |
| `Contents/Resources/GamekitCore_GamekitCore.bundle/Contents/Resources/RuntimeModules/win32u-remote-surface-2.so` | x86_64 prebuilt Wine `win32u.so` replacement | ad-hoc; no Team ID / timestamp | Same team and timestamp; **no executable entitlements**; inspect load behavior in the actual Wine host |

`Contents/Resources/AppIcon.icns`, `Assets.car`, plist, JSON profiles, and the
resource bundle's patch/README/license files are non-executable resources sealed
by the enclosing signature; the resource bundle is not an additional Mach-O
executable. `ExecutionAdapters/dxgi-version-v1.dll` is a Windows x86-64 **PE32+**
DLL, not a macOS Mach-O signing target; it is still a bundled executable payload
whose provenance and hashes must remain checked by its separate adapter contract.
Gamekit's `Info.plist` declares utility category and opts out of
Game Mode; derived **game** bundles, rather than the library app, request Game
Mode. `codesign --verify --deep --strict` passes for the present archive, which
proves integrity of its **ad-hoc** signatures only. `spctl --assess --type execute`
rejects both the local Release build and archive app. That reproduces the current
Gatekeeper distribution blocker without modifying the app or any security policy.

An ordinary local Release **build** currently injects
`com.apple.security.get-task-allow=true` into Gamekit and the process-counter
tool. The separately generated ad-hoc **archive** had no app entitlements and
an empty application-identifier plus no `get-task-allow` on the counter. Do not
assume a Release build is distributable, or that a future Developer ID export
will strip entitlements automatically: inspect the final export and reject any
shipping `get-task-allow` on every executable. No signed export has been tried.

The `.so` is a source-controlled, ad-hoc-signed Mach-O **inside a SwiftPM resource
bundle**, not an innocuous text resource. The Ubisoft launcher profile and shared
fixture pin its signed-file SHA-256 as
`791440e7394236738f8ffefbf6ce7643e801aa5d74e3a092e2dd755eeec020c5`.
`SteamApplicationBundle.prepareSynchronously()` checks those resource bytes before
copying them into a derived launcher. Developer ID re-signing will change the file
hash and may change how SwiftPM stages/signs it; the production JSON hash, fixture,
source-to-artifact evidence and live Ubisoft qualification must be updated
**together** in `gamekit-lon.4`/`.5`. Do not put game-specific hash exceptions in
Swift or silently retain the ad-hoc resource inside a notarized app.

## Trust and process ownership matrix

| Component / location | Code owner and current evidence | Hardened Runtime / exception decision |
| --- | --- | --- |
| Gamekit GUI in downloaded DMG | Gamekit; only this delivered app is under our Developer ID signing/notarization workflow | Hardened Runtime **on**; no demonstrated JIT, DYLD insertion or cross-team library loading in the GUI itself. Start with no exception. |
| `GamekitProcessCounters` embedded tool | Gamekit; spawned for read-only process sampling | Hardened Runtime **on**; no exception justified by current source. |
| `WineGameIdentity.dylib` and the bundled `win32u` module | Gamekit-built x86_64 libraries; loaded into a different process after insertion/copy | Sign with Developer ID; libraries get no executable entitlements. DYLD/library-validation/JIT permissions, if necessary, belong to the **actual host process** and require isolated proof. |
| User-supplied Sikarugir 10.0 revision 6 / Template 1.0.11 | Publisher artifacts verified in `runtime-revision.md`; installed `wine` and `wineserver` are x86_64 and currently **ad-hoc**, with no Team ID | External. Gamekit cannot grant Wine Hardened Runtime entitlements or confer its notarization. Test provenance, local approval and host-process rules before claiming supported first-run behavior. |
| User-supplied Apple D3DMetal 4.0b2 | Original framework binary SHA-256 `f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad`; original **Apple Software Signing** chain verifies | External; keep Apple bytes/signature intact. Its signature is not a signature for the surrounding Sikarugir app or Wine host. |
| Vendor-retrieved Steam and Ubisoft Connect installers/clients and games | Setup downloads pinned installers from Valve/Ubisoft endpoints; vendor clients acquire their own updates and games | Not in Gamekit's DMG or notarization. Verify fetched installer provenance; client updates and game downloads remain vendor-owned. |
| Generated Steam, Ubisoft and per-game Wine bundles under managed user data | `SteamApplicationBundle` copies the selected engine, writes identity plists and sometimes replaces a Wine module; per-game caches use versioned formats | Created **after** distribution; not covered by Gamekit DMG notarization. Pin exact source/derived bytes and isolate approvals and Gatekeeper behavior. Never mistake `open` success on a previously approved prefix for clean-install acceptance. |

`RuntimeLayout.environment()` constructs a narrowly inherited child environment,
sets `DYLD_INSERT_LIBRARIES` to `WineGameIdentity.dylib` for a scoped session, and
sets Wine/graphics paths and `ROSETTA_ADVERTISE_AVX`. The launcher bundle is run by
`/usr/bin/open -g -n -a <derived bundle> --env ...`, not by injecting into the
arm64 Gamekit GUI. The x86_64 Wine process owns loading/JIT behavior; the
ad-hoc Wine binary observed here has no Hardened Runtime flag. The library's
Developer ID team and the Wine host's library-validation/security state must be
tested, not inferred from Gamekit's entitlements. Rosetta is required for the
current Intel Mach-O runtime on Apple silicon; no macOS 28 promise follows from
macOS 27 testing (`runtime-contract.md`).

Provenance on the existing **local** selected runtime: `wine` SHA-256
`1b992a3e0bc5f2a058a24f923832aaa6e464d44766fb0ad13054797e02060d10`,
`wineserver` `6dfe1f9d2d8a67cc6a09a57966f5ef88fd461abe7321d6fb0d4a1672e8ff0350`,
and the D3DMetal binary matches the pinned hash above. The composed runtime root
has `com.apple.provenance`, **no root `com.apple.quarantine` observed**; that is
not a clean downloaded-copy Gatekeeper result. Recheck the exact downloaded
inputs and each relevant signed executable/framework on the acceptance device,
including quarantine and source receipts. Do not remove quarantine from the
owner's current runtime or mutate existing prefixes during inventory work.

## Isolated pass/fail qualification before distribution

`gamekit-lon.4` must produce a clean-source Developer ID archive/export, inspect
all four files above inside-out for team `EWT2X7Q9ZJ`, timestamp and appropriate
Hardened Runtime, verify **no shipping get-task-allow**, and run strict deep
verification. For `gamekit-lon.5`, make an isolated copy of the **verified**
external runtime with a fresh prefix and derived launcher/game caches, preserving
the publisher originals and owner prefixes. Record per-copy hashes, original and
resulting signatures and quarantine; never re-sign Apple's framework.

Compare launch with and without session DYLD insertion; observe which Wine host
image loads the signed helper and whether AMFI/Gatekeeper/library validation
rejects it. Exercise Rosetta, the Ubisoft module when selected, generated bundle
identities, managed Steam launch/stop, a fullscreen game launch/exit and ordinary
Gamekit quit/reopen. Check real downloaded/quarantined DMG and runtime on clean
macOS 27 in `gamekit-lon.7`/`.8`. A test **fails** if the host rejects injection,
JIT/library loading, a generated bundle cannot be approved by a user-scoped flow,
Apple's bytes or source Wine are altered, or the game/session is not functional.
Do not grant blanket GUI entitlements, globally disable Gatekeeper/SIP, or call
an accepted notary response evidence that external Wine is trusted.

**No-go:** if this pinned separately supplied runtime or its generated bundles
cannot run from the supported clean-install security flow with narrowly scoped,
owner-approved local steps, block distribution and request a new owner decision.
No signed runtime or clean-Mac pass is claimed in this inventory.

## Reproduction and Apple references

Use a disposable local build/archive; the paths below contain no private runtime
or account material. `codesign` detail output is on stderr.

```sh
xcodebuild -project Gamekit.xcodeproj -scheme Gamekit -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -archivePath .build/Gamekit-signing-inventory.xcarchive archive
APP=.build/Gamekit-signing-inventory.xcarchive/Products/Applications/Gamekit.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP"
codesign -d --entitlements - "$APP"
codesign -dv --verbose=4 "$APP/Contents/MacOS/GamekitProcessCounters"
codesign -dv --verbose=4 "$APP/Contents/Frameworks/WineGameIdentity.dylib"
codesign -dv --verbose=4 "$APP/Contents/Resources/GamekitCore_GamekitCore.bundle/Contents/Resources/RuntimeModules/win32u-remote-surface-2.so"
spctl --assess --type execute -vv "$APP"  # expected rejection: ad-hoc archive
```

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) requires Developer ID, signed executables, Hardened Runtime, secure timestamp and no shipping get-task-allow.
- [Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues) documents Xcode archive/export behavior for injected entitlements, timestamp and nested targets.
- [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) assigns exceptions to **executables**; libraries inherit the host's permissions.
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) covers container submission, notary log inspection and stapling.
