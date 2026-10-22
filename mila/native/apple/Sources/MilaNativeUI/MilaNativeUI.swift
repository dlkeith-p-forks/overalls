import SwiftUI

/// Native presentation shell. Machine records are supplied by the validated Rust snapshot boundary.
public struct MilaNativeRootView: View {
    private let adapter: any MilaFFIAdapter
    @State private var selection: MilaRoute = .machines
    @State private var machines: [MilaMachinePresentation] = []
    @State private var status = MilaStrings.text(.ready)

    public init(adapter: any MilaFFIAdapter = LinkedMilaFFIAdapter(), snapshot: MilaValidatedSnapshot? = nil) {
        self.adapter = adapter
        _machines = State(initialValue: snapshot?.machines ?? [])
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(MilaStrings.text(.machines), systemImage: "desktopcomputer").tag(MilaRoute.machines)
                Label(MilaStrings.text(.threads), systemImage: "bubble.left.and.bubble.right").tag(MilaRoute.threads)
                Label(MilaStrings.text(.settings), systemImage: "gearshape").tag(MilaRoute.settings)
            }.navigationTitle(MilaStrings.text(.appName))
        } detail: {
            Group {
                switch selection {
                case .machines: MachinesView(machines: machines) { selection = .machine(id: $0) }
                case .machine(let id): MachineDetailView(machine: machines.first { $0.id == id }, adapter: adapter)
                case .threads: ThreadsView(adapter: adapter, select: { selection = .thread(id: $0) })
                case .thread(let id): ThreadDetailView(id: id)
                case .settings: SettingsView(adapter: adapter)
                }
            }
            .toolbar { ToolbarItem { Button(MilaStrings.text(.refresh)) { Task { await refresh() } } } }
            .safeAreaInset(edge: .bottom) { Text(status).font(.caption).foregroundStyle(.secondary).padding(4) }
        }.milaDesignSystem().task { await refresh() }
    }

    private func refresh() async {
        do { let snapshot = try await adapter.refreshSnapshot(); machines = snapshot.machines; status = MilaStrings.text(.snapshotLoaded) }
        catch { status = MilaStrings.text(.noSnapshotLoaded); machines = [] }
    }
}

private struct MachinesView: View {
    let machines: [MilaMachinePresentation]
    let select: (UUID) -> Void
    var body: some View {
        List {
            if machines.isEmpty { ContentUnavailableView(MilaStrings.text(.machinesEmpty), systemImage: "desktopcomputer", description: Text(MilaStrings.text(.machinesHint))) }
            ForEach(machines) { machine in
                Button { select(machine.id) } label: {
                    VStack(alignment: .leading) { Text(machine.machine.name); Text(machine.machine.observedState ?? "unknown").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle(MilaStrings.text(.machines))
    }
}

private struct MachineDetailView: View {
    let machine: MilaMachinePresentation?
    let adapter: any MilaFFIAdapter
    @StateObject private var workflow: MilaMachineWorkflow
    @State private var classified = ""
    @State private var showTerminal = false
    @State private var webURL = ""
    @StateObject private var webControls = MilaWebControlsController()
    @State private var showWeb = false
    @State private var sharePrincipal = ""
    @StateObject private var sharing: MilaMachineSharingController
    init(machine: MilaMachinePresentation?, adapter: any MilaFFIAdapter) {
        self.machine = machine
        self.adapter = adapter
        _workflow = StateObject(wrappedValue: MilaMachineWorkflow(adapter: adapter))
        _sharing = StateObject(wrappedValue: MilaMachineSharingController(adapter: adapter))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let machine {
                Text(machine.machine.name).font(.title)
                Text(machine.id.uuidString).font(.caption)
                Text(machine.machine.observedState ?? "unknown").foregroundStyle(.secondary)
                Button(MilaStrings.text(.openTerminal)) { showTerminal = true }.disabled(!machine.machine.write)
                HStack {
                    TextField(MilaStrings.text(.sharePrincipal), text: $sharePrincipal)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(MilaStrings.text(.shareAdd)) { sharing.submit(principal: sharePrincipal) }
                        .disabled(!machine.machine.write || sharePrincipal.isEmpty)
                    Button(MilaStrings.text(.shareRemove)) { sharing.submit(principal: sharePrincipal, remove: true) }
                        .disabled(!machine.machine.write || sharePrincipal.isEmpty)
                }
                Text(shareStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(MilaStrings.text(.webPlaceholder), text: $webURL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button(MilaStrings.text(.webOpen)) { showWeb = webControls.set(webURL) }.disabled(webURL.isEmpty)
                }
                if webControls.error != nil { Text(MilaStrings.text(.webInvalid)).font(.caption).foregroundStyle(.secondary) }
                ForEach(machine.actions.values, id: \.self) { action in
                    Button(action.title) {
                        workflow.submit(action, machine: machine)
                    }
                    .disabled(!isIdle)
                }
                HStack {
                    ForEach(["show", "resize", "share show", "web show"], id: \.self) { command in
                        Button(command) {
                            do { classified = String(describing: try adapter.classifyMachineCommand(command)) }
                            catch { classified = MilaStrings.text(.rejectedByRust) }
                        }
                    }
                }
                Text(classified).font(.caption).foregroundStyle(.secondary)
                Text(mutationStatus).font(.caption).foregroundStyle(.secondary)
                .onAppear { sharing.setSession(signedIn: true, machine: machine) }
            } else { ContentUnavailableView(MilaStrings.text(.machineUnavailable), systemImage: "questionmark") }
        }.padding().sheet(isPresented: $showTerminal) { MilaTerminalView() }
        #if canImport(WebKit)
        .sheet(isPresented: $showWeb) { if let endpoint = webControls.endpoint { MilaWebView(endpoint: endpoint) } }
        #endif
    }

    private var isIdle: Bool {
        if case .idle = workflow.state { return true }
        return false
    }

    private var shareStatus: String {
        switch sharing.state {
        case .signedOut: return MilaStrings.text(.runtimeUnavailable)
        case .idle: return MilaStrings.text(.ready)
        case .submitting: return MilaStrings.text(.connecting)
        case .applied(_, _, let remove): return remove ? MilaStrings.text(.shareRemoved) : MilaStrings.text(.shareAdded)
        case .failed: return MilaStrings.text(.actionNotSubmitted)
        }
    }

    private var mutationStatus: String {
        switch workflow.state {
        case .idle: return MilaStrings.text(.ready)
        case .submitting: return MilaStrings.text(.connecting)
        case .applied: return MilaStrings.text(.actionSubmitted)
        case .failed: return MilaStrings.text(.actionNotSubmitted)
        }
    }

}
private struct ThreadsView: View {
    let adapter: any MilaFFIAdapter
    let select: (UUID) -> Void
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MilaStrings.text(.threads)).font(.title)
            Text(MilaStrings.text(.commandsRust)).font(.caption).foregroundStyle(.secondary)
            ForEach(["threads list", "threads read"], id: \.self) { command in
                Button(command) {
                    do { status = String(describing: try adapter.classifyThreadCommand(command)) }
                    catch { status = MilaStrings.text(.unavailable) }
                }
            }
            Text(status).font(.caption)
            ContentUnavailableView(MilaStrings.text(.noThreads), systemImage: "bubble.left", description: Text(MilaStrings.text(.threadsHint)))
        }.padding()
    }
}
private struct ThreadDetailView: View { let id: UUID; var body: some View { Text("\(MilaStrings.text(.threads)) \(id.uuidString)").padding() } }
private struct SettingsView: View {
    let adapter: any MilaFFIAdapter
    @AppStorage("mila.appearance") private var appearance = "system"
    @AppStorage("mila.appLockEnabled") private var appLockEnabled = false
    @State private var notificationToken = ""
    @State private var notificationEndpoint = ""
    @State private var notificationStatus = ""
    @State private var notificationsEnabled = false
    var body: some View {
        Form {
            Section(MilaStrings.text(.appearance)) {
                Picker(MilaStrings.text(.appearance), selection: $appearance) {
                    Text(MilaStrings.text(.appearanceSystem)).tag("system")
                    Text(MilaStrings.text(.appearanceLight)).tag("light")
                    Text(MilaStrings.text(.appearanceDark)).tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section(MilaStrings.text(.lockTitle)) {
                Toggle(MilaStrings.text(.lockTitle), isOn: $appLockEnabled)
                    .disabled(true)
                Text(MilaStrings.text(.lockUnavailable)).font(.caption).foregroundStyle(.secondary)
            }
            Section(MilaStrings.text(.notificationsTitle)) {
                Text(MilaStrings.text(.notificationsExplain)).font(.caption)
                SecureField("Device token", text: $notificationToken)
                    .textContentType(.oneTimeCode)
                TextField("https://deployment.example/push", text: $notificationEndpoint)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button(notificationsEnabled ? MilaStrings.text(.notificationsTurnOff) : MilaStrings.text(.notificationsTurnOn)) {
                        if notificationsEnabled {
                            notificationsEnabled = false
                            notificationStatus = MilaStrings.text(.notificationsTurnOff)
                        } else {
                            let controller = MilaNotificationController(adapter: adapter, appID: "com.overalls.mila", deployment: "current")
                            controller.register(token: notificationToken, endpoint: notificationEndpoint)
                            notificationsEnabled = controller.state == .on
                            notificationStatus = notificationsEnabled ? MilaStrings.text(.notificationsTurnOn) : MilaStrings.text(.runtimeUnavailable)
                            notificationToken = ""
                        }
                    }
                    Text(notificationsEnabled ? "[on]" : "[off]").font(.caption)
                }
                Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink(MilaStrings.text(.sshKeysTitle)) {
                MilaSSHKeysView(controller: MilaSSHKeysController(
                    loader: { try await adapter.listSSHKeys() },
                    revoker: { keyID in
                        let key = MilaSSHKey(id: keyID, fingerprint: "", algorithm: "")
                        try await adapter.revokeSSHKey(key, requestID: UUID())
                    }
                ))
            }
            Text(MilaStrings.text(.runtimeUnavailable)).foregroundStyle(.secondary)
        }.navigationTitle(MilaStrings.text(.settings))
    }
}

public struct MilaSSHKeysView: View {
    @StateObject private var controller: MilaSSHKeysController
    public init(controller: MilaSSHKeysController) { _controller = StateObject(wrappedValue: controller) }
    public var body: some View {
        List {
            Text(MilaStrings.text(.sshKeysExplain)).font(.caption)
            switch controller.state {
            case .signedOut: Text(MilaStrings.text(.sshKeysEmpty))
            case .loading: ProgressView()
            case .failed: Text(MilaStrings.text(.runtimeUnavailable))
            case .loaded(let keys):
                if keys.isEmpty { Text(MilaStrings.text(.sshKeysEmpty)) }
                ForEach(keys) { key in
                    HStack {
                        VStack(alignment: .leading) { Text(key.label ?? MilaStrings.text(.sshKeysTitle)); Text(key.fingerprint).font(.caption); Text("\(MilaStrings.text(.sshKeyAlgorithm)): \(key.algorithm)").font(.caption) }
                        Spacer()
                        if key.isCurrentDevice { Text(MilaStrings.text(.sshKeyThisDevice)).font(.caption) }
                        Button(MilaStrings.text(.sshKeyRevoke)) { Task { await controller.revoke(key) } }.disabled(key.isCurrentDevice)
                    }
                }
            }
        }.navigationTitle(MilaStrings.text(.sshKeysTitle)).task { await controller.load(signedIn: true) }
    }
}

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
            Text(MilaStrings.text(.terminal)).font(.title2)
            ScrollView { Text(String(decoding: terminal.output, as: UTF8.self)).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity).background(.black).foregroundStyle(.green)
            HStack { TextField(MilaStrings.text(.input), text: $command).onSubmit { send() }; Button(MilaStrings.text(.send)) { send() }; Button(MilaStrings.text(.reconnect)) { Task { await terminal.reconnect() } } }
            Text("\(String(describing: terminal.state)) · \(terminal.columns)x\(terminal.rows)").font(.caption).foregroundStyle(.secondary)
        }.padding().task { await terminal.attach() }.onDisappear { Task { await terminal.close() } }
    }
    private func send() { let data = Data(command.utf8); command = ""; Task { await terminal.sendInput(data) } }
}
