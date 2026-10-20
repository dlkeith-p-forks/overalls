import Foundation

/// Operations exposed by the generated Rust FFI binding.
public enum MilaFFIOperation: String, Codable, Sendable {
    case bootstrap
    case refresh
}

/// Navigation targets accepted from external activation. Credentials and commands are excluded.
public enum MilaRoute: Equatable, Sendable {
    case machines
    case machine(id: UUID)
    case threads
    case thread(id: UUID)
    case settings
}

public enum MilaRouteParser {
    public static func parse(_ value: String) -> MilaRoute? {
        guard let url = URL(string: value), url.scheme == "overalls",
              url.user == nil, url.fragment == nil, url.query == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (url.host?.lowercased(), parts) {
        case ("machines", []): return .machines
        case ("machines", [let id]) where UUID(uuidString: id) != nil:
            return .machine(id: UUID(uuidString: id)!)
        case ("threads", []): return .threads
        case ("threads", [let id]) where UUID(uuidString: id) != nil:
            return .thread(id: UUID(uuidString: id)!)
        case ("settings", []): return .settings
        default: return nil
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

public enum MilaFFIError: Error, Equatable, Sendable {
    case unavailable
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
