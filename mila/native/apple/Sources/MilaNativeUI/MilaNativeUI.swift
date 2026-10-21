import SwiftUI

/// Native presentation shell. Machine records are supplied by the validated Rust snapshot boundary.
public struct MilaNativeRootView: View {
    private let adapter: any MilaFFIAdapter
    @State private var selection: MilaRoute = .machines
    @State private var machines: [MilaMachinePresentation] = []
    @State private var status = "Ready"

    public init(adapter: any MilaFFIAdapter = LinkedMilaFFIAdapter(), snapshot: MilaValidatedSnapshot? = nil) {
        self.adapter = adapter
        _machines = State(initialValue: snapshot?.machines ?? [])
    }

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
                case .threads: ThreadsView(adapter: adapter, select: { selection = .thread(id: $0) })
                case .thread(let id): ThreadDetailView(id: id)
                case .settings: SettingsView()
                }
            }
            .toolbar { ToolbarItem { Button("Refresh") { Task { await refresh() } } } }
            .safeAreaInset(edge: .bottom) { Text(status).font(.caption).foregroundStyle(.secondary).padding(4) }
        }.task { await refresh() }
    }

    private func refresh() async {
        do { let snapshot = try await adapter.refreshSnapshot(); machines = snapshot.machines; status = "Snapshot loaded" }
        catch { status = "No snapshot loaded"; machines = [] }
    }
}

private struct MachinesView: View {
    let machines: [MilaMachinePresentation]
    let select: (UUID) -> Void
    var body: some View {
        List {
            if machines.isEmpty { ContentUnavailableView("No machines", systemImage: "desktopcomputer", description: Text("Connect to a deployment to load a validated snapshot.")) }
            ForEach(machines) { machine in
                Button { select(machine.id) } label: {
                    VStack(alignment: .leading) { Text(machine.machine.name); Text(machine.machine.observedState ?? "unknown").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Machines")
    }
}

private struct MachineDetailView: View {
    let machine: MilaMachinePresentation?
    let adapter: any MilaFFIAdapter
    @State private var status = ""
    @State private var classified = ""
    @State private var showTerminal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let machine {
                Text(machine.machine.name).font(.title)
                Text(machine.id.uuidString).font(.caption)
                Text(machine.machine.observedState ?? "unknown").foregroundStyle(.secondary)
                Button("Open terminal") { showTerminal = true }.disabled(!machine.machine.write)
                ForEach(machine.actions.values, id: \.self) { action in
                    Button(action.title) {
                        Task {
                            do {
                                try await adapter.submit(action, machine: machine, requestID: UUID())
                                status = "Action submitted"
                            } catch { status = "Action not submitted" }
                        }
                    }
                }
                HStack {
                    ForEach(["show", "resize", "share show", "web show"], id: \.self) { command in
                        Button(command) {
                            do { classified = String(describing: try adapter.classifyMachineCommand(command)) }
                            catch { classified = "Rejected by Rust" }
                        }
                    }
                }
                Text(classified).font(.caption).foregroundStyle(.secondary)
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("Machine unavailable", systemImage: "questionmark") }
        }.padding().sheet(isPresented: $showTerminal) { MilaTerminalView() }
    }

}
private struct ThreadsView: View {
    let adapter: any MilaFFIAdapter
    let select: (UUID) -> Void
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Threads").font(.title)
            Text("Commands are classified by Rust before execution.").font(.caption).foregroundStyle(.secondary)
            ForEach(["threads list", "threads read"], id: \.self) { command in
                Button(command) {
                    do { status = String(describing: try adapter.classifyThreadCommand(command)) }
                    catch { status = "Unavailable" }
                }
            }
            Text(status).font(.caption)
            ContentUnavailableView("No threads", systemImage: "bubble.left", description: Text("Connect to a deployment to load threads."))
        }.padding()
    }
}
private struct ThreadDetailView: View { let id: UUID; var body: some View { Text("Thread \(id.uuidString)").padding() } }
private struct SettingsView: View { var body: some View { Form { Text("Runtime and deployment settings are managed by the core library.").foregroundStyle(.secondary) }.navigationTitle("Settings") } }

@MainActor public struct MilaNativeApp: App {
    private let adapter: any MilaFFIAdapter
    public init() { adapter = LinkedMilaFFIAdapter() }
    public init(adapter: any MilaFFIAdapter) { self.adapter = adapter }
    public var body: some Scene { WindowGroup { MilaNativeRootView(adapter: adapter) } }
}


private struct MilaTerminalView: View {
    @StateObject private var terminal = MilaTerminalController()
    @State private var command = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal").font(.title2)
            ScrollView { Text(String(decoding: terminal.output, as: UTF8.self)).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity).background(.black).foregroundStyle(.green)
            HStack { TextField("Input", text: $command).onSubmit { send() }; Button("Send") { send() }; Button("Reconnect") { Task { await terminal.reconnect() } } }
            Text("\(String(describing: terminal.state)) · \(terminal.columns)x\(terminal.rows)").font(.caption).foregroundStyle(.secondary)
        }.padding().task { await terminal.attach() }.onDisappear { Task { await terminal.close() } }
    }
    private func send() { let data = Data(command.utf8); command = ""; Task { await terminal.sendInput(data) } }
}
