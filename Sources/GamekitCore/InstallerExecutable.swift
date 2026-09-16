import Foundation

/// Structural PE validation is a format check, not Authenticode verification.
enum InstallerExecutable {
    static func validate(_ data: Data) throws {
        func reject() throws -> Never { throw InstallerAcquisitionError.invalidExecutable }
        func number(_ offset: Int, _ width: Int = 2) throws -> Int {
            guard offset >= 0, offset <= data.count - width else { try reject() }
            return (0..<width).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        guard data.count >= 64, try number(0) == 0x5a4d else { try reject() }
        let pe = try number(0x3c, 4)
        guard pe >= 64, pe <= data.count - 24, try number(pe, 4) == 0x4550 else { try reject() }
        let machine = try number(pe + 4), sections = try number(pe + 6)
        let optionalSize = try number(pe + 20), flags = try number(pe + 22)
        let optional = pe + 24
        guard (1...96).contains(sections), flags & 2 != 0, flags & 0x2000 == 0,
              optionalSize >= 224, optional + optionalSize <= data.count else { try reject() }
        let magic = try number(optional)
        guard (machine == 0x14c && magic == 0x10b) || (machine == 0x8664 && magic == 0x20b && optionalSize >= 240)
        else { try reject() }
        let table = optional + optionalSize
        let headers = try number(optional + 60, 4)
        guard table + sections * 40 <= headers, headers <= data.count else { try reject() }
        var hasBody = false
        for section in 0..<sections {
            let size = try number(table + section * 40 + 16, 4)
            let offset = try number(table + section * 40 + 20, 4)
            if size > 0 {
                guard offset >= headers, offset <= data.count, size <= data.count - offset else { try reject() }
                hasBody = true
            }
        }
        guard hasBody else { try reject() }
        // The certificate directory uses file offsets, unlike the other PE directories.
        let directoryCountOffset = magic == 0x10b ? 92 : 108
        if try number(optional + directoryCountOffset, 4) >= 5 {
            let certificate = optional + directoryCountOffset + 4 + 4 * 8
            let offset = try number(certificate, 4), size = try number(certificate + 4, 4)
            if offset != 0 || size != 0 {
                guard size >= 8, offset >= headers, offset <= data.count, size <= data.count - offset else { try reject() }
            }
        }
    }
}
