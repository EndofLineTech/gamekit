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
    var revision: String { backend == .dxmt ? "dxmt-0.80-compat2" : "dxvk-macos-1.10.3-compat2" }
    func root(_ layout: RuntimeLayout) -> URL { layout.dataRoot.appendingPathComponent("GraphicsBackends/\(revision)") }
    var hashes: [String: String] {
        if backend == .dxmt {
            return [
                "x86_64-windows/d3d11.dll": "08f9d86cf985b2f0310140aa0c7179b303f73dd4f82d2b9c06d622ae88ef4276",
                "x86_64-windows/d3d10core.dll": "833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26",
                "x86_64-windows/dxgi.dll": "140e9d59c09de2dfddc81bfa44ffea550c2fb7f7c234c52d7efb7ee138451487",
                "x86_64-windows/winemetal.dll": "514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0",
                "i386-windows/d3d11.dll": "faae57658d3a3510ef5a2acf32f0d260a747133fe37262cc2d08ef7664688f6e",
                "i386-windows/d3d10core.dll": "c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f",
                "i386-windows/dxgi.dll": "24db0dc467490dcd0b85b3f33c1ce64ec4a0e974f9ca859cb2fbcd5ff7e8a24b",
                "i386-windows/winemetal.dll": "20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3",
                "x86_64-unix/winemetal.so": "3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca",
            ]
        }
        return [
            "x86_64-windows/d3d11.dll": "82ec183f211309cd0852898aa4ec377884abb8175021f3ba3118e0b0433724e3",
            "x86_64-windows/d3d10core.dll": "57bda05c9ea6dcb167831b7d83b464a90b8645aeccbda39acc53c9ee59d61404",
            "x86_64-windows/dxgi.dll": "732e580910e3b935a030e97799409331b5d759b569afdfad2065ccea6de75186",
            "i386-windows/d3d11.dll": "363728dcf294d4e1a145ecee5c361ed3d7f6d0591d96036fb56f7b36d7636920",
            "i386-windows/d3d10core.dll": "17bcdb55448bc0db4f830bdb34c21398a25ca4b75613c804ee9fcc82a8fc2a79",
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
