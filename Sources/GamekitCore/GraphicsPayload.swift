import Foundation

public enum GraphicsPayloadError: Error, Equatable { case unavailable }

/// Separately staged, immutable renderer modules. No game or prefix DLLs are
/// replaced. Pins cover the upstream payload and its Wine/macOS dependencies.
struct GraphicsPayload: Sendable {
    let backend: GraphicsBackend
    init?(backend: GraphicsBackend) {
        guard backend == .dxmt || backend == .dxvk else { return nil }
        self.backend = backend
    }
    var revision: String { backend == .dxmt ? "dxmt-0.80-1" : "dxvk-macos-1.10.3-20230507-1" }
    func root(_ layout: RuntimeLayout) -> URL { layout.dataRoot.appendingPathComponent("GraphicsBackends/\(revision)") }
    var hashes: [String: String] {
        if backend == .dxmt {
            return [
                "x86_64-windows/d3d11.dll": "7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47",
                "x86_64-windows/d3d10core.dll": "833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26",
                "x86_64-windows/dxgi.dll": "fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544",
                "x86_64-windows/winemetal.dll": "514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0",
                "i386-windows/d3d11.dll": "9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d",
                "i386-windows/d3d10core.dll": "c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f",
                "i386-windows/dxgi.dll": "7df8cdf66e12a108410002abc77b01f70aa59b8a36a70fa0bc6ae3b056841319",
                "i386-windows/winemetal.dll": "20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3",
                "x86_64-unix/winemetal.so": "3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca",
            ]
        }
        return [
            "x86_64-windows/d3d11.dll": "173980cb6c51fdd53dc37b9a17f0de7c5dfdebda18f52059aa7d5a6f1871299c",
            "x86_64-windows/d3d10core.dll": "225562562050d9fae1d4d5d2ca0537020bac268c80dec9aa0633dc0d338a2840",
            "x86_64-windows/dxgi.dll": "732e580910e3b935a030e97799409331b5d759b569afdfad2065ccea6de75186",
            "i386-windows/d3d11.dll": "2173b081a8660dd70a089dac875a829da6cd1a6230b23fd1daa2a7d7baa1cb03",
            "i386-windows/d3d10core.dll": "9e0202437af13a6d0acdb992954321f00a641b2eb98897908c41635ffddc1fc8",
            "i386-windows/dxgi.dll": "228cb38f21224d880217635bb3d59f94ce3f3c7b2de109821ac47d8b4391a792",
        ]
    }
    func privateFiles(arch: String) -> Set<String> {
        Set(hashes.keys.filter { $0.hasPrefix(arch + "/") }.map { String($0.dropFirst(arch.count + 1)) })
    }
    func validate(layout: RuntimeLayout) throws {
        let root = root(layout)
        guard (try? ManagedDirectory.openRoot(root, create: false)) != nil,
              hashes.allSatisfy({ RuntimeDetector.matches(root.appendingPathComponent($0.key), root: root, hash: $0.value) })
        else { throw GraphicsPayloadError.unavailable }
        let dependencies = backend == .dxmt ? [
            "Contents/SharedSupport/wine/lib/wine/x86_64-unix/winemac.so": "4cbf65e363d6d8b5a70dba719b50b811fb4b2705985e93f777c6cb7a12878eb0"
        ] : [
            "Contents/Frameworks/moltenvkcx/libMoltenVK.dylib": "e9de8aa6053e1347c82aff01c6d7964556f306b2f7c63db88eb54a05e4f8b980",
            "Contents/SharedSupport/wine/lib/wine/x86_64-unix/winevulkan.so": "85b3d6b19749b861a6a4f403a5473aff6bb4861d1d2b2794545c2e024e46db60"
        ]
        guard dependencies.allSatisfy({ RuntimeDetector.matches(layout.bundle.appendingPathComponent($0.key), root: layout.bundle, hash: $0.value) })
        else { throw GraphicsPayloadError.unavailable }
    }
}

extension RuntimeLayout {
    public func isGraphicsBackendAvailable(_ backend: GraphicsBackend) -> Bool {
        guard let payload = GraphicsPayload(backend: backend) else { return true }
        return (try? payload.validate(layout: self)) != nil
    }
}
