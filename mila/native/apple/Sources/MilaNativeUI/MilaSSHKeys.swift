import Foundation

public struct MilaSSHKey: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fingerprint: String
    public let algorithm: String
    public let label: String?
    public let isCurrentDevice: Bool

    public init(id: UUID, fingerprint: String, algorithm: String, label: String? = nil, isCurrentDevice: Bool = false) {
        self.id = id; self.fingerprint = fingerprint; self.algorithm = algorithm; self.label = label; self.isCurrentDevice = isCurrentDevice
    }
}

public enum MilaSSHKeysState: Equatable, Sendable { case signedOut, loading, loaded([MilaSSHKey]), failed }

@MainActor public final class MilaSSHKeysController: ObservableObject {
    @Published public private(set) var state: MilaSSHKeysState = .signedOut
    private let loader: () async throws -> [MilaSSHKey]
    private let revoker: (UUID) async throws -> Void

    public init(loader: @escaping () async throws -> [MilaSSHKey], revoker: @escaping (UUID) async throws -> Void) {
        self.loader = loader; self.revoker = revoker
    }

    public func load(signedIn: Bool) async {
        guard signedIn else { state = .signedOut; return }
        state = .loading
        do { state = .loaded(try await loader()) } catch { state = .failed }
    }

    /// @cc [owner:ghuntley,label:security] mila-apple-ssh-revoke
    /// Revocation targets only the selected opaque key identity and refreshes the list after success.
    public func revoke(_ key: MilaSSHKey) async {
        guard case .loaded = state else { return }
        // The signer currently in use cannot be revoked from this session: doing
        // so would strand the authenticated device and differs across platforms.
        guard !key.isCurrentDevice else { return }
        do { try await revoker(key.id); await load(signedIn: true) } catch { state = .failed }
    }
}
