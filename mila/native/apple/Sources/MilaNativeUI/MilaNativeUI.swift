import SwiftUI

/// The native presentation shell. All data actions cross the typed Rust adapter seam.
public struct MilaNativeRootView: View {
    private let adapter: any MilaFFIAdapter
    @State private var selection: MilaRoute = .machines
    @State private var status = "Ready"

    public init(adapter: any MilaFFIAdapter = UnavailableMilaFFIAdapter()) {
        self.adapter = adapter
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Machines", systemImage: "desktopcomputer").tag(MilaRoute.machines)
                Label("Threads", systemImage: "bubble.left.and.bubble.right").tag(MilaRoute.threads)
                Label("Settings", systemImage: "gearshape").tag(MilaRoute.settings)
            }
            .navigationTitle("Mila")
        } detail: {
            Group {
                switch selection {
                case .machines: MachinesView(select: { selection = .machine(id: $0) })
                case .machine(let id): MachineDetailView(id: id)
                case .threads: ThreadsView(select: { selection = .thread(id: $0) })
                case .thread(let id): ThreadDetailView(id: id)
                case .settings: SettingsView()
                }
            }
            .toolbar { ToolbarItem(placement: .automatic) {
                Button("Refresh") { Task { await refresh() } }
            }}
            .safeAreaInset(edge: .bottom) { Text(status).font(.caption).foregroundStyle(.secondary).padding(4) }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        do { _ = try await adapter.call(MilaFFIRequest(operation: .refresh)); status = "Connected" }
        catch { status = "Native runtime unavailable" }
    }
}

private struct MachinesView: View {
    let select: (UUID) -> Void
    var body: some View {
        List {
            Section("Machines") {
                ForEach([("Development", UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), ("Production", UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)], id: \.1) { machine in
                    Button(machine.0) { select(machine.1) }
                }
            }
        }.navigationTitle("Machines")
    }
}
private struct MachineDetailView: View { let id: UUID; var body: some View { VStack(alignment: .leading, spacing: 12) { Text("Machine").font(.title); Text(id.uuidString).font(.caption); Text("Overview"); Text("Choose a machine action from the connected runtime.").foregroundStyle(.secondary) }.padding() } }
private struct ThreadsView: View {
    let select: (UUID) -> Void
    var body: some View { List { ForEach([UUID(uuidString: "00000000-0000-0000-0000-000000000003")!], id: \.self) { id in Button("Recent thread") { select(id) } } }.navigationTitle("Threads") }
}
private struct ThreadDetailView: View { let id: UUID; var body: some View { VStack(alignment: .leading) { Text("Thread").font(.title); Text(id.uuidString).font(.caption); Text("No messages loaded") }.padding() } }
private struct SettingsView: View { var body: some View { Form { Section("Connection") { Text("Runtime and deployment settings are managed by the core library.").foregroundStyle(.secondary) } }.navigationTitle("Settings") } }

public struct MilaNativeApp: App {
    private let adapter: any MilaFFIAdapter
    public init(adapter: any MilaFFIAdapter = UnavailableMilaFFIAdapter()) { self.adapter = adapter }
    public var body: some Scene { WindowGroup { MilaNativeRootView(adapter: adapter) } }
}
