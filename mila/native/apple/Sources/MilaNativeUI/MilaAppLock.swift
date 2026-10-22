import Foundation
import LocalAuthentication
import SwiftUI

public enum MilaAppLockState: Equatable, Sendable {
    case unavailable
    case locked
    case unlocked
    case failed
}

public protocol MilaBiometricEvaluator: Sendable {
    func availability() -> Bool
    func authenticate(reason: String) async -> Bool
}

private struct LocalAuthenticationEvaluator: MilaBiometricEvaluator {
    func availability() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

@MainActor
public final class MilaAppLockController: ObservableObject {
    @Published public private(set) var state: MilaAppLockState
    private let evaluator: any MilaBiometricEvaluator
    private let reason: String

    public init(enabled: Bool = false, reason: String = MilaStrings.text(.lockExplain), evaluator: any MilaBiometricEvaluator = LocalAuthenticationEvaluator()) {
        self.evaluator = evaluator
        self.reason = reason
        guard enabled, evaluator.availability() else {
            self.state = enabled ? .unavailable : .unlocked
            return
        }
        self.state = .locked
    }

    public var isEnabled: Bool { state != .unlocked && state != .unavailable }
    public var canEnable: Bool { evaluator.availability() }

    public func setEnabled(_ enabled: Bool) async {
        guard enabled else { state = .unlocked; return }
        guard evaluator.availability() else { state = .unavailable; return }
        state = .locked
        await unlock()
    }

    public func unlock() async {
        guard state == .locked || state == .failed else { return }
        state = await evaluator.authenticate(reason: reason) ? .unlocked : .failed
    }

    public func lock() {
        guard canEnable else { state = .unavailable; return }
        state = .locked
    }
}

public struct MilaAppLockView<Content: View>: View {
    @ObservedObject private var controller: MilaAppLockController
    private let content: () -> Content

    public init(controller: MilaAppLockController, @ViewBuilder content: @escaping () -> Content) {
        self.controller = controller
        self.content = content
    }

    public var body: some View {
        Group {
            switch controller.state {
            case .unlocked: content()
            case .unavailable:
                ContentUnavailableView(MilaStrings.text(.lockUnavailable), systemImage: "lock.open")
            case .locked, .failed:
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                    Text(MilaStrings.text(.lockTitle)).font(.title2)
                    Button(MilaStrings.text(.lockUnlock)) { Task { await controller.unlock() } }
                    if controller.state == .failed { Text(MilaStrings.text(.lockFailed)).font(.caption) }
                }.padding()
            }
        }
    }
}
