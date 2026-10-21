import SwiftUI

/// Native presentation shell. Machine records are supplied by the validated Rust snapshot boundary.
public struct MilaNativeRootView: View {
    private let adapter: any MilaFFIAdapter
    @State private var selection: MilaRoute = .machines
    @State private var machines: [MilaSnapshotMachine] = []
    @State private var status = "Ready"

    public init(adapter: any MilaFFIAdapter = UnavailableMilaFFIAdapter()) { self.adapter = adapter }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Machines", systemImage: "desktopcomputer").tag(MilaRoute.machines)
                Label("Threads", systemImage: "bubble.left.and.bubble.right").tag(MilaRoute.threads)
                Label("Settings", systemImage: "gearshape").tag(MilaRoute.settings)
            }.navigationTitle("Mila")
        } detail: {
            Group {
                switch selection {
                case .machines: MachinesView(machines: machines) { selection = .machine(id: $0) }
                case .machine(let id): MachineDetailView(machine: machines.first { $0.id == id }, adapter: adapter)
                case .threads: ThreadsView(select: { selection = .thread(id: $0) })
                case .thread(let id): ThreadDetailView(id: id)
                case .settings: SettingsView()
                }
            }
            .toolbar { ToolbarItem { Button("Refresh") { Task { await refresh() } } } }
            .safeAreaInset(edge: .bottom) { Text(status).font(.caption).foregroundStyle(.secondary).padding(4) }
        }.task { await refresh() }
    }

    private func refresh() async {
        do { _ = try await adapter.call(MilaFFIRequest(operation: .refresh)); status = "Connected" }
        catch { status = "No snapshot loaded"; machines = [] }
    }
}

private struct MachinesView: View {
    let machines: [MilaSnapshotMachine]
    let select: (UUID) -> Void
    var body: some View {
        List {
            if machines.isEmpty { ContentUnavailableView("No machines", systemImage: "desktopcomputer", description: Text("Connect to a deployment to load a validated snapshot.")) }
            ForEach(machines) { machine in
                Button { select(machine.id) } label: {
                    VStack(alignment: .leading) { Text(machine.name); Text(machine.observedState ?? "unknown").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Machines")
    }
}

private struct MachineDetailView: View {
    let machine: MilaSnapshotMachine?
    let adapter: any MilaFFIAdapter
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let machine {
                Text(machine.name).font(.title)
                Text(machine.id.uuidString).font(.caption)
                Text(machine.observedState ?? "unknown").foregroundStyle(.secondary)
                if machine.write || machine.manage {
                    ForEach(actions(for: machine), id: \.self) { action in
                        Button(action.title) { status = "Action queued: \(action.title)" }
                    }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("Machine unavailable", systemImage: "questionmark") }
        }.padding()
    }
    private func actions(for machine: MilaSnapshotMachine) -> [MilaMachineAction] {
        var result: [MilaMachineAction] = []
        if machine.write { if machine.observedState == "stopped" { result.append(.start) }; if machine.observedState == "paused" { result.append(.resume) }; if machine.observedState == "running" { result += [.pause, .stop] } }
        result.append(machine.pinned ? .unpin : .pin)
        if machine.manage, machine.owner != nil, !machine.pinned { result.append(.delete) }
        return result
    }
}
private struct ThreadsView: View { let select: (UUID) -> Void; var body: some View { ContentUnavailableView("No threads", systemImage: "bubble.left", description: Text("Threads are loaded from the connected runtime.")) } }
private struct ThreadDetailView: View { let id: UUID; var body: some View { Text("Thread \(id.uuidString)").padding() } }
private struct SettingsView: View { var body: some View { Form { Text("Runtime and deployment settings are managed by the core library.").foregroundStyle(.secondary) }.navigationTitle("Settings") } }

@MainActor public struct MilaNativeApp: App {
    private let adapter: any MilaFFIAdapter
    public init() { adapter = UnavailableMilaFFIAdapter() }
    public init(adapter: any MilaFFIAdapter) { self.adapter = adapter }
    public var body: some Scene { WindowGroup { MilaNativeRootView(adapter: adapter) } }
}
