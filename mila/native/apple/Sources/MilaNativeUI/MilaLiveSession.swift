import Foundation
import MilaFFIShim

public enum MilaSessionError: Error, Equatable, Sendable {
    case invalidInput
    case transport(Int32)
    case outputTooSmall
    case staleHandle
    case unavailable
}

/// A typed owner for a Rust live session. The handle is closed exactly once.
public final class MilaLiveSession: @unchecked Sendable {
    private let signer: MilaDeviceSigner
    private let host: String
    private let port: UInt16
    private var handle: UInt64
    private let lock = NSLock()

    public init(trust: Data, host: String, port: UInt16, timeoutMilliseconds: UInt32 = 15_000, signer: MilaDeviceSigner) throws {
        guard !trust.isEmpty, !host.isEmpty else { throw MilaSessionError.invalidInput }
        self.signer = signer
        self.host = host
        self.port = port
        var connected: UInt64 = 0
        let status: Int32 = trust.withUnsafeBytes { trustRaw in
            host.utf8CString.withUnsafeBufferPointer { hostBuffer in
                let key = Array(signer.openSSHPublicKey.utf8)
                return key.withUnsafeBufferPointer { keyBuffer in
                    mila_session_connect(trustRaw.bindMemory(to: UInt8.self).baseAddress, trust.count,
                                          hostBuffer.baseAddress, host.utf8.count,
                                          keyBuffer.baseAddress, key.count, port, timeoutMilliseconds,
                                          milaAppleSessionSigner, UInt(bitPattern: Unmanaged.passUnretained(signer).toOpaque()), &connected)
                }
            }
        }
        guard status == 0 else { throw Self.error(status) }
        guard connected != 0 else { throw MilaSessionError.unavailable }
        self.handle = connected
    }

    deinit { close() }

    public func refresh() throws -> Data {
        let current = try validHandle()
        let status = mila_session_read_machines(current, 0)
        guard status == 0 else { throw Self.error(status) }
        return try copyListing(current)
    }

    public func machineAction(machine: UUID, action: String, requestID: UUID) throws {
        let current = try validHandle()
        let machineBytes = Array(machine.uuidString.lowercased().utf8)
        let actionBytes = Array(action.utf8)
        let requestBytes = Array(("porsche-" + requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")).utf8)
        let status = machineBytes.withUnsafeBufferPointer { m in actionBytes.withUnsafeBufferPointer { a in requestBytes.withUnsafeBufferPointer { r in
            mila_session_machine_action(current, m.baseAddress, m.count, a.baseAddress, a.count, r.baseAddress, r.count)
        } } }
        guard status == 0 else { throw Self.error(status) }
    }

    public func readMore() throws -> Data {
        let current = try validHandle()
        let status = mila_session_read_machines(current, 1)
        guard status == 0 else { throw Self.error(status) }
        return try copyListing(current)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { return }
        _ = mila_session_close(handle)
        handle = 0
    }

    private func validHandle() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { throw MilaSessionError.staleHandle }
        return handle
    }

    private func copyListing(_ handle: UInt64) throws -> Data {
        var required = 0
        var status = mila_session_listing(handle, nil, 0, &required)
        guard status == 0 || status == -3, required > 0, required <= 1_048_576 else { throw Self.error(status) }
        var bytes = [UInt8](repeating: 0, count: required)
        status = mila_session_listing(handle, &bytes, bytes.count, &required)
        guard status == 0 else { throw Self.error(status) }
        return Data(bytes.prefix(required))
    }

    private static func error(_ status: Int32) -> MilaSessionError {
        switch status { case -3: return .outputTooSmall; case -10: return .staleHandle; case -11, -12, -13, -14: return .transport(status); case -4, -1: return .invalidInput; default: return .transport(status) }
    }
}

private func milaAppleSessionSigner(_ context: UInt, _ message: UnsafePointer<UInt8>?, _ length: Int, _ signature: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard context != 0, let message, let signature, length > 0, length <= 65_536 else { return -1 }
    do {
        let signer = Unmanaged<MilaDeviceSigner>.fromOpaque(UnsafeRawPointer(bitPattern: context)!).takeUnretainedValue()
        let raw = try signer.sign(message: Data(bytes: message, count: length))
        guard raw.count == 64 else { return -1 }
        raw.copyBytes(to: signature, count: 64)
        return 0
    } catch { return -1 }
}
