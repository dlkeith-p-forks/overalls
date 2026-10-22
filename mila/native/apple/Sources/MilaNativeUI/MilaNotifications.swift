import Foundation

/// Registration state for the current Apple device and deployment.
public enum MilaNotificationState: Equatable, Sendable {
    case off
    case registering
    case on
    case failed
}

/// Owns notification registration without retaining or logging the device token.
@MainActor
public final class MilaNotificationController: ObservableObject {
    @Published public private(set) var state: MilaNotificationState = .off

    private let adapter: any MilaFFIAdapter
    private let appID: String
    private let deployment: String

    public init(adapter: any MilaFFIAdapter, appID: String, deployment: String) {
        self.adapter = adapter
        self.appID = appID
        self.deployment = deployment
    }

    /// @cc [owner:ghuntley,label:security] mila-apple-push-token-boundary
    /// Device tokens are borrowed by Rust validation and never retained, displayed, or logged.
    public func register(token: String, endpoint: String, environment: MilaPushEnvironment = .production) {
        guard !token.isEmpty else { state = .failed; return }
        state = .registering
        do {
            try adapter.validatePushRegistration(
                provider: MilaPushProvider.apple.rawValue,
                environment: environment.rawValue,
                token: token,
                appID: appID,
                deployment: deployment,
                endpoint: endpoint
            )
            state = .on
        } catch {
            state = .failed
        }
    }

    public func disable() { state = .off }
}
