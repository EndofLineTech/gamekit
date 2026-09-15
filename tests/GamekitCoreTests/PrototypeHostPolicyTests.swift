import Testing
@testable import GamekitCore

@Suite("Prototype host scope")
struct PrototypeHostPolicyTests {
    @Test("Apple silicon on macOS 27 is in scope")
    func evaluatedTarget() {
        #expect(PrototypeHostPolicy.failures(macOSMajorVersion: 27, architecture: .arm64).isEmpty)
    }

    @Test("Neither older nor unvalidated future macOS releases are accepted", arguments: [15, 26, 28, 29])
    func operatingSystemBoundary(major: Int) {
        #expect(PrototypeHostPolicy.failures(macOSMajorVersion: major, architecture: .arm64)
            == [.operatingSystem(actualMajor: major)])
    }

    @Test("Intel and unknown architectures are outside scope", arguments: [HostArchitecture.x86_64, .unknown])
    func architectureBoundary(architecture: HostArchitecture) {
        #expect(PrototypeHostPolicy.failures(macOSMajorVersion: 27, architecture: architecture)
            == [.architecture(architecture)])
    }

    @Test("Independent requirement failures are all reported")
    func reportsBothRequirements() {
        #expect(PrototypeHostPolicy.failures(macOSMajorVersion: 28, architecture: .x86_64)
            == [.operatingSystem(actualMajor: 28), .architecture(.x86_64)])
    }
}
