# Managed Ubisoft installed-game discovery

Gamekit queries only the install subtree in the launcher JSON profile via Wine's
`reg.exe` while an already-owned Ubisoft Connect client is running. For each
numeric install ID, it queries only that ID's uninstall record. Matching vendor
install paths, display title and publisher must resolve to one regular game
directory under the profile's managed `gamesDirectory`. The install-state and
manifest markers must exist as nonempty regular files for the **Installed** state.
The optional icon comes from the vendor's registered icon path under the
profile's bounded `iconDirectory`. Gamekit does not scan account/token files,
read a full registry hive, parse game-content manifests, or invent game sizes.
The vendor's installed-game record provides a small icon, not portrait box art.
For explicitly verified game IDs in `Sources/GamekitCore/ArtworkProfiles/ubisoft.json`,
Gamekit requests a public Ubisoft Store edition packshot over HTTPS and accepts
only the pinned SHA-256 JPEG with bounded portrait dimensions. The original
packshot fits within the 2:3 cover without cropping. If an ID is not mapped or
the request is offline, redirected or changed, Gamekit displays the same 2:3
icon/title fallback instead. Art is an in-memory cache, separate from the
managed game prefix; Gamekit does not scrape the Store by title or query account
data. New mappings require independent evidence linking the Store's
`uplayGameID` to a real installed Ubisoft ID.

The public [Ubisoft Store page for The Division](https://store.ubisoft.com/us/tom-clancys-the-division/56c494ad88a7e300458b4d62.html)
explicitly identifies `uplayGameID: 568` and its `edition_packshot` as
`images/large/56c494ad88a7e300458b4d62.jpg` on the same product. On
2026-10-01 the official Store JPEG was 464×608, 61,125 bytes, with SHA-256
`9eb314a57a19a96b8b2137f3570ddc048983fd63a443be9d1d2a254f0669e4af`.
These are public product/artwork facts; no retail image is bundled or copied
into the repository. A Store update that changes those bytes requires new
verification and a JSON profile update.

On 2026-09-30, the owner's signed-in isolated Ubisoft Connect build 13368 wrote
`HKLM\Software\Wow6432Node\Ubisoft\Launcher\Installs\568` for the installed
**Tom Clancy's The Division**, pointing at its own managed `games/` directory.
`HKLM\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Uplay Install 568`
reported the same path, title, publisher and an icon under the launcher's
`data/` directory. The game folder contained nonempty `uplay_install.state`
and `uplay_install.manifest` files. These game-only facts are the sanitized test
fixture in `tests/fixtures/ubisoft-catalog.json`; no account or sign-in data is
included. The live signed local candidate displayed The Division next to the
unchanged Steam installation and cached only the validated ID, title, folder
name, icon filename and prefix identity.

An incomplete install is shown as incomplete. An unreadable or stopped client
retains last-known entries without enabling Play; a replaced prefix cannot adopt
the saved cache. A fresh owned scan can renew it after a volume renumber. The
validated numeric ID is substituted only into the vendor URI template from the
Ubisoft launcher JSON profile, and the request uses the same receipt/session as
the running client. No actual game launch, gameplay or save result is inferred
from sending that request. The owner can verify gameplay separately.
