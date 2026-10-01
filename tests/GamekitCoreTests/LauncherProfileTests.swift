import Foundation
import Testing
@testable import GamekitCore

@Suite("Bundled launcher execution policy")
struct LauncherProfileTests {
    @Test("Ubisoft policy is available as a validated bundled resource")
    func bundled() throws {
        let profile = try LauncherProfileStore.bundled("ubisoft")
        #expect(profile.id.rawValue == "ubisoft")
        #expect(profile.name == "Ubisoft Connect")
        #expect(profile.installer.url.scheme == "https")
        #expect(profile.installer.maximumBytes > 32 * 1024 * 1024)
        #expect(profile.executable.components.first == "drive_c")
        #expect(profile.launchArguments?.count == 1)
    }

    @Test("Invalid or modified launcher execution policy is refused")
    func invalidPolicy() throws {
        let profile = try LauncherProfileStore.bundled("ubisoft")
        let template = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        func changed(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var values = template
            change(&values)
            return try JSONSerialization.data(withJSONObject: values)
        }
        for data in try [changed { $0["schemaVersion"] = 2 },
                         changed {
                             var catalog = $0["gameCatalog"] as! [String: Any]
                             catalog["installsRegistryKey"] = "HKCU\\Software\\Credentials\\Installs"
                             $0["gameCatalog"] = catalog
                         },
                         changed {
                             var catalog = $0["gameCatalog"] as! [String: Any]
                             catalog["launchURI"] = "uplay://launch/{id}/../other"
                             $0["gameCatalog"] = catalog
                         },
                         changed { $0["launchArguments"] = ["--invalid=value"] },
                         changed { $0["launchArguments"] = Array(repeating: "--duplicate", count: 9) },
                         changed { $0["executable"] = "../untrusted.exe" },
                         changed { $0["clientExecutables"] = ["../untrusted.exe"] },
                         changed { $0["installer"] = ["url": "http://example.test/setup.exe", "sha256": profile.installer.sha256,
                                                       "maximumBytes": profile.installer.maximumBytes, "arguments": []] }] {
            #expect(throws: (any Error).self) { try LauncherProfile.decode(data) }
        }
        #expect(throws: LauncherProfileError.invalidProfile) { try LauncherProfileStore.bundled("../ubisoft") }
    }
}
