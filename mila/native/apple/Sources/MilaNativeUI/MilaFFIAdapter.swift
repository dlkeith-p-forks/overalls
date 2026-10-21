import Foundation
import MilaFFIShim

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
        guard url.host != nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let page = parts.first else { return nil }
        let tail = Array(parts.dropFirst())
        switch page.lowercased() {
        case "machines":
            guard let id = tail.first else { return tail.isEmpty ? .machines : nil }
            guard tail.count == 1, let uuid = UUID(uuidString: id) else { return nil }
            return .machine(id: uuid)
        case "threads":
            guard let id = tail.first else { return tail.isEmpty ? .threads : nil }
            guard tail.count == 1, let uuid = UUID(uuidString: id) else { return nil }
            return .thread(id: uuid)
        case "settings":
            return tail.isEmpty ? .settings : nil
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

public struct MilaSnapshotMachine: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let desiredState: String
    public let observedState: String?
    public let pinned: Bool
    public let owner: String?
    public let read: Bool
    public let write: Bool
    public let manage: Bool

    enum CodingKeys: String, CodingKey { case id, name, desiredState = "desired_state", observedState = "observed_state", pinned, owner, read, write, manage }
}

public enum MilaMachineAction: UInt16, CaseIterable, Sendable {
    case start, stop, pause, resume, pin, unpin, delete

    public var title: String { rawValue == MilaMachineAction.delete.rawValue ? "Delete" : String(describing: self).capitalized }
    fileprivate var token: String {
        switch self { case .start: "start"; case .stop: "stop"; case .pause: "pause"; case .resume: "resume"; case .pin: "pin"; case .unpin: "unpin"; case .delete: "rm" }
    }
}

public struct MilaMachineActions: Equatable, Sendable {
    public let values: [MilaMachineAction]
    fileprivate init(bits: UInt16) { values = MilaMachineAction.allCases.filter { bits & (1 << $0.rawValue) != 0 } }
}

/// Presentation records can only be constructed after Rust validation and policy projection.
public struct MilaMachinePresentation: Identifiable, Equatable, Sendable {
    public var id: UUID { machine.id }
    public let machine: MilaSnapshotMachine
    public let actions: MilaMachineActions
    fileprivate init(machine: MilaSnapshotMachine, actions: MilaMachineActions) {
        self.machine = machine
        self.actions = actions
    }
}

public struct MilaValidatedSnapshot: Equatable, Sendable {
    public let machines: [MilaMachinePresentation]
    public let metadata: MilaSnapshotMetadata
    fileprivate init(machines: [MilaMachinePresentation], metadata: MilaSnapshotMetadata) {
        self.machines = machines
        self.metadata = metadata
    }
}

public struct MilaSnapshotMetadata: Equatable, Sendable {

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
    case actionNotAllowed
}

private enum MilaRustFFI {
    static func getVersion(_ version: UnsafeMutablePointer<MilaFfiAbiVersion>) -> Int32 {
        mila_ffi_get_version(version).rawValue
    }
    static func formatRoute(_ input: UnsafePointer<CChar>, _ output: MilaRouteOutput) -> Int32 {
        mila_route_format(input, output).rawValue
    }
    static func validateSnapshot(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ host: UnsafePointer<CChar>, _ port: UInt16, _ hasPort: UInt8, _ summary: UnsafeMutablePointer<MilaSnapshotSummary>) -> Int32 {
        mila_snapshot_validate(bytes, length, host, port, hasPort, summary).rawValue
    }
    static func machineActions(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ host: UnsafePointer<CChar>, _ port: UInt16, _ hasPort: UInt8, _ index: UInt32, _ actions: UnsafeMutablePointer<MilaMachineActions>) -> Int32 {
        var raw = MilaFFIShim.MilaMachineActions(bits: 0)
        let status = mila_snapshot_machine_actions(bytes, length, host, port, hasPort, index, &raw).rawValue
        actions.pointee = MilaMachineActions(bits: raw.bits)
        return status
    }
    static func command(_ action: UnsafePointer<CChar>, _ machine: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>?, _ output: MilaRouteOutput) -> Int32 {
        mila_session_command_format(action, machine, request, output).rawValue
    }
}

/// Adapter for the stable C ABI exported by `mila-ffi`.
/// The host must link the Rust library; no Rust-owned memory is retained by this value.
public struct LinkedMilaFFIAdapter: MilaFFIAdapter, Sendable {
    public init() {}

    public func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        throw MilaFFIError.unavailable
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
    public func validateSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> MilaSnapshotMetadata {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var summary = MilaSnapshotSummary(machine_count: 0, saved_at: 0)
        let status = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return host.withCString { hostPointer in
                withUnsafeMutablePointer(to: &summary) { summaryPointer in
                    MilaRustFFI.validateSnapshot(base, data.count, hostPointer, port ?? 0, port == nil ? 0 : 1, summaryPointer)
                }
            }
        }
        switch status {
        case 0: return MilaSnapshotMetadata(machineCount: summary.machine_count, savedAt: summary.saved_at)
        case -4: throw MilaFFIError.invalidRoute
        default: throw MilaFFIError.unavailable
        }
    }

    public func machineActions(_ data: Data, host: String, port: UInt16? = nil, index: UInt32) throws -> MilaMachineActions {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var raw = MilaMachineActions(bits: 0)
        let status = data.withUnsafeBytes { bytes -> Int32 in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return host.withCString { hostPointer in
                withUnsafeMutablePointer(to: &raw) { MilaRustFFI.machineActions(base, data.count, hostPointer, port ?? 0, port == nil ? 0 : 1, index, $0) }
            }
        }
        guard status == 0 else { throw MilaFFIError.unavailable }
        return raw
    }

    public func formatMachineAction(_ action: MilaMachineAction, machineID: UUID, requestID: UUID? = nil) throws -> String {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var output = [UInt8](repeating: 0, count: 512); var written = 0
        let status = output.withUnsafeMutableBufferPointer { buffer in
            action.token.withCString { actionPtr in machineID.uuidString.lowercased().withCString { machinePtr in
                if let requestID { return ("porsche-" + requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")).withCString { req in withUnsafeMutablePointer(to: &written) { MilaRustFFI.command(actionPtr, machinePtr, req, MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: $0)) } } }
                return withUnsafeMutablePointer(to: &written) { MilaRustFFI.command(actionPtr, machinePtr, nil, MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: $0)) }
            }}
        }
        guard status == 0 else { throw status == -3 ? MilaFFIError.outputTooSmall : MilaFFIError.unavailable }
        return String(decoding: output.prefix(written), as: UTF8.self)
    }

    public func decodeSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> [MilaSnapshotMachine] {
        _ = try validateSnapshot(data, host: host, port: port)
        let decoder = JSONDecoder()
        let object = try decoder.decode(MilaSnapshotEnvelope.self, from: data)
        return object.machines
    }

    /// @cc [owner:ghuntley,label:security] mila-apple-rust-policy
    /// Every displayed machine action MUST come from Rust for the same validated snapshot index.
    public func projectSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> MilaValidatedSnapshot {
        let metadata = try validateSnapshot(data, host: host, port: port)
        let machines = try decodeSnapshot(data, host: host, port: port)
        let projected = try machines.enumerated().map { index, machine in
            MilaMachinePresentation(machine: machine, actions: try machineActions(data, host: host, port: port, index: UInt32(index)))
        }
        return MilaValidatedSnapshot(machines: projected, metadata: metadata)
    }

    public func refreshSnapshot() async throws -> MilaValidatedSnapshot {
        throw MilaFFIError.unavailable
    }

    /// @cc [owner:ghuntley,label:security] mila-apple-no-fabricated-submission
    /// Formatting MUST NOT be reported as submission; absent an authenticated session, actions fail unavailable.
    public func submit(_ action: MilaMachineAction, machine: MilaMachinePresentation, requestID: UUID) async throws {
        guard machine.actions.values.contains(action) else { throw MilaFFIError.actionNotAllowed }
        _ = try formatMachineAction(action, machineID: machine.id, requestID: requestID)
        throw MilaFFIError.unavailable
    }

    private func abiCompatible() -> Bool {
        var version = MilaFfiAbiVersion(major: 0, minor: 0)
        return MilaRustFFI.getVersion(&version) == 0 && version.major == 1
    }
}

/**
 * @cc [owner:ghuntley,label:security] mila-apple-ffi-typed-boundary
 * The Apple UI MUST exchange typed requests and validated snapshot projections with the Rust
 * adapter; raw pointers, credentials, and terminal bytes MUST NOT appear in this interface.
 */
private struct MilaSnapshotEnvelope: Codable { let machines: [MilaSnapshotMachine] }

public protocol MilaFFIAdapter: Sendable {
    func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse
    func refreshSnapshot() async throws -> MilaValidatedSnapshot
    func submit(_ action: MilaMachineAction, machine: MilaMachinePresentation, requestID: UUID) async throws
}

public extension MilaFFIAdapter {
    func refreshSnapshot() async throws -> MilaValidatedSnapshot { throw MilaFFIError.unavailable }
    func submit(_ action: MilaMachineAction, machine: MilaMachinePresentation, requestID: UUID) async throws { throw MilaFFIError.unavailable }
}

/// Explicit placeholder until generated UniFFI bindings are linked by the host application.
public struct UnavailableMilaFFIAdapter: MilaFFIAdapter, Sendable {
    public init() {}

    public func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse {
        _ = request
        throw MilaFFIError.unavailable
    }
}
