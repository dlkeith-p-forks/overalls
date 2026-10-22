import Foundation
import Combine

public struct MilaSharePrincipal: Equatable, Sendable {
    public let value: String
    public init(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...256).contains(value.utf8.count), !value.unicodeScalars.contains(where: { $0.properties.isControl }) else {
            throw MilaMachineSharingError.invalidPrincipal
        }
        self.value = value
    }
}

public enum MilaMachineSharingError: Error, Equatable, Sendable {
    case invalidPrincipal
    case signedOut
    case noMachine
    case unavailable
}

public enum MilaMachineSharingState: Equatable, Sendable {
    case signedOut
    case idle
    case submitting(machineID: UUID, principal: MilaSharePrincipal, remove: Bool)
    case applied(machineID: UUID, principal: MilaSharePrincipal, remove: Bool)
    case failed(machineID: UUID?, principal: MilaSharePrincipal?, remove: Bool, error: MilaMachineSharingError)
}

@MainActor
public final class MilaMachineSharingController: ObservableObject {
    @Published public private(set) var state: MilaMachineSharingState = .signedOut
    private let adapter: any MilaFFIAdapter
    private var machine: MilaMachinePresentation?
    private var authenticated = false
    private var task: Task<Void, Never>?

    public init(adapter: any MilaFFIAdapter) { self.adapter = adapter }
    deinit { task?.cancel() }

    public func setSession(signedIn: Bool, machine: MilaMachinePresentation?) {
        authenticated = signedIn
        self.machine = signedIn ? machine : nil
        state = signedIn ? (machine == nil ? .idle : .idle) : .signedOut
    }

    public func select(machine: MilaMachinePresentation?) {
        guard authenticated else { return }
        self.machine = machine
        state = .idle
    }

    public func submit(principal raw: String, remove: Bool = false, requestID: UUID = UUID()) {
        guard authenticated else { state = .failed(machineID: machine?.id, principal: nil, remove: remove, error: .signedOut); return }
        guard let machine else { state = .failed(machineID: nil, principal: nil, remove: remove, error: .noMachine); return }
        let principal: MilaSharePrincipal
        do { principal = try MilaSharePrincipal(raw) }
        catch { state = .failed(machineID: machine.id, principal: nil, remove: remove, error: .invalidPrincipal); return }
        state = .submitting(machineID: machine.id, principal: principal, remove: remove)
        task = Task { [adapter] in
            do {
                try await adapter.submitShare(principal, machine: machine, remove: remove, requestID: requestID)
                guard !Task.isCancelled else { return }
                state = .applied(machineID: machine.id, principal: principal, remove: remove)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(machineID: machine.id, principal: principal, remove: remove, error: (error as? MilaMachineSharingError) ?? .unavailable)
            }
        }
    }

    public func reset() { task?.cancel(); task = nil; state = authenticated ? .idle : .signedOut }
}
