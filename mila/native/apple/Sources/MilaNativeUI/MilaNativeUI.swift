import SwiftUI

/// The native presentation seam. The existing Flutter runner can embed this view while the
/// generated Rust adapter is integrated in a later change.
public struct MilaNativeRootView: View {
    private let adapter: any MilaFFIAdapter
    @State private var status = "Ready"

    public init(adapter: any MilaFFIAdapter = UnavailableMilaFFIAdapter()) {
        self.adapter = adapter
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Mila")
                .font(.title2)
            Text("Native Mila")
                .foregroundStyle(.secondary)
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("Check native bridge") {
                Task {
                    do { _ = try await adapter.call(MilaFFIRequest(operation: .bootstrap)); status = "Connected" }
                    catch { status = "Native runtime unavailable" }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

/// Host applications provide their own `@main` entry point and inject a real adapter here.
public struct MilaNativeApp: App {
    private let adapter: any MilaFFIAdapter

    public init(adapter: any MilaFFIAdapter = UnavailableMilaFFIAdapter()) {
        self.adapter = adapter
    }

    public var body: some Scene {
        WindowGroup {
            MilaNativeRootView(adapter: adapter)
        }
    }
}
