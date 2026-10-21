import Foundation

/// Operations exposed by the generated Rust FFI binding.
public enum MilaFFIOperation: String, Codable, Sendable {
    case bootstrap
    case refresh
}

/// Navigation targets accepted from external activation. Credentials and commands are excluded.
public enum MilaRoute: Hashable, Sendable {
    case machines
    case machine(id: UUID)
    case threads
    case thread(id: UUID)
    case settings
}

public enum MilaRouteParser {
    public static func parse(_ value: String) -> MilaRoute? {
        guard let url = URL(string: value), url.scheme == "overalls",
              url.user == nil, url.fragment == nil, url.query == nil,
              !value.contains("%") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "machines":
            guard let id = parts.first else { return .machines }
            guard parts.count == 1, let uuid = UUID(uuidString: id) else { return nil }
            return .machine(id: uuid)
        case "threads":
            guard let id = parts.first else { return .threads }
            guard parts.count == 1, let uuid = UUID(uuidString: id) else { return nil }
            return .thread(id: uuid)
        case "settings":
            return parts.isEmpty ? .settings : nil
        default:
            return nil
        }
    }
}

/// A request crossing the native/Rust boundary.
public struct MilaFFIRequest: Codable, Equatable, Sendable {
    public let operation: MilaFFIOperation
    public let payload: Data

    public init(operation: MilaFFIOperation, payload: Data = Data()) {
        self.operation = operation
        self.payload = payload
    }
}

/// A response crossing the native/Rust boundary.
public struct MilaFFIResponse: Codable, Equatable, Sendable {
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }
}

public struct MilaSnapshotSummary: Equatable, Sendable {
    public let machineCount: UInt32
    public let savedAt: UInt64

    public init(machineCount: UInt32, savedAt: UInt64) {
        self.machineCount = machineCount
        self.savedAt = savedAt
    }
}

public enum MilaFFIError: Error, Equatable, Sendable {
    case unavailable
    case invalidRoute
    case outputTooSmall
    case incompatibleABI
}

private enum MilaRustFFI {
    @_silgen_name("mila_ffi_get_version")
    static func getVersion(_ version: UnsafeMutablePointer<MilaFFIAbiVersion>) -> Int32
    @_silgen_name("mila_route_format")
    static func formatRoute(_ input: UnsafePointer<CChar>, _ output: MilaRouteOutput) -> Int32
    @_silgen_name("mila_snapshot_validate")
    static func validateSnapshot(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ host: UnsafePointer<CChar>, _ port: UInt16, _ hasPort: UInt8, _ summary: UnsafeMutablePointer<MilaSnapshotSummaryC>) -> Int32
}

private struct MilaRouteOutput {
    var bytes: UnsafeMutablePointer<UInt8>?
    var capacity: Int
    var written: UnsafeMutablePointer<Int>?
}

private struct MilaSnapshotSummaryC {
    var machineCount: UInt32
    var savedAt: UInt64
}

private struct MilaFFIAbiVersion {
    var major: UInt32
    var minor: UInt32
}

/// Adapter for the stable C ABI exported by `mila-ffi`.
/// The host must link the Rust library; no Rust-owned memory is retained by this value.
public struct LinkedMilaFFIAdapter: MilaFFIAdapter, Sendable {
    public init() {}

    public func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        return MilaFFIResponse(payload: request.payload)
    }

    public func canonicalRoute(_ value: String) throws -> String {
        var output = [UInt8](repeating: 0, count: 2048)
        var written = 0
        let status = output.withUnsafeMutableBufferPointer { buffer in
            value.withCString { input in
                withUnsafeMutablePointer(to: &written) { writtenPointer in
                    let out = MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: writtenPointer)
                    return MilaRustFFI.formatRoute(input, out)
                }
            }
        }
        switch status {
        case 0: return String(decoding: output.prefix(written), as: UTF8.self)
        case -2: throw MilaFFIError.invalidRoute
        case -3: throw MilaFFIError.outputTooSmall
        default: throw MilaFFIError.unavailable
        }
    }

    /// Validates and summarizes an offline snapshot in Rust. Snapshot bytes are borrowed for the
    /// duration of the call and no machine records cross the native boundary.
    public func validateSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> MilaSnapshotSummary {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var summary = MilaSnapshotSummaryC(machineCount: 0, savedAt: 0)
        let status = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return host.withCString { hostPointer in
                withUnsafeMutablePointer(to: &summary) { summaryPointer in
                    MilaRustFFI.validateSnapshot(base, data.count, hostPointer, port ?? 0, port == nil ? 0 : 1, summaryPointer)
                }
            }
        }
        switch status {
        case 0: return MilaSnapshotSummary(machineCount: summary.machineCount, savedAt: summary.savedAt)
        case -4: throw MilaFFIError.invalidRoute
        default: throw MilaFFIError.unavailable
        }
    }

    private func abiCompatible() -> Bool {
        var version = MilaFFIAbiVersion(major: 0, minor: 0)
        return MilaRustFFI.getVersion(&version) == 0 && version.major == 1
    }
}

/**
 * @cc [owner:ghuntley,label:security] mila-apple-ffi-typed-boundary
 * The Apple UI MUST exchange only `MilaFFIRequest` and `MilaFFIResponse` values with the Rust
 * adapter; raw pointers, credentials, and terminal bytes MUST NOT appear in this interface.
 */
public protocol MilaFFIAdapter: Sendable {
    func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse
}

/// Explicit placeholder until generated UniFFI bindings are linked by the host application.
public struct UnavailableMilaFFIAdapter: MilaFFIAdapter, Sendable {
    public init() {}

    public func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse {
        _ = request
        throw MilaFFIError.unavailable
    }
}
