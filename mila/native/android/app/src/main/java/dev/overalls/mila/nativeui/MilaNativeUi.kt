package dev.overalls.mila.nativeui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

internal data class MachineCommandChoice(val label: String, val command: String)

/**
 * @cc [owner:ghuntley,label:architecture] android-machine-command-catalog
 * Every machine command presented by the Android shell MUST be classified through the closed
 * Rust command catalog before it is shown as selected; the UI must not invent operation tags.
 */
internal val machineCommandChoices = listOf(
    MachineCommandChoice("List", "ls"),
    MachineCommandChoice("Show", "show"),
    MachineCommandChoice("New", "new"),
    MachineCommandChoice("Resize", "resize"),
    MachineCommandChoice("Start", "start"),
    MachineCommandChoice("Stop", "stop"),
    MachineCommandChoice("Pause", "pause"),
    MachineCommandChoice("Resume", "resume"),
    MachineCommandChoice("Delete", "rm"),
    MachineCommandChoice("Share add", "share add"),
    MachineCommandChoice("Share remove", "share remove"),
    MachineCommandChoice("Web show", "web show"),
    MachineCommandChoice("Web set", "web set"),
)

/** Commands exposed by the Rust thread catalog; arguments are intentionally not accepted here. */
internal val threadCommandChoices = listOf(
    "List" to "thread ls",
    "Show" to "thread show",
    "Turns" to "thread turns",
    "Prompt" to "thread prompt",
    "Answer" to "thread answer",
    "Plan approve" to "thread plan approve",
    "Plan revise" to "thread plan revise",
    "Mode" to "thread mode",
    "Read" to "thread read",
)

/**
 * @cc [owner:ghuntley,label:security] android-native-deployment-selection
 * The Android shell MUST offer only persisted or user-validated deployments. It MUST NOT invent a
 * host, call the session-material provider without a selected deployment, or pass a different host
 * to that provider than the one selected by the user.
 */
@Composable
fun MilaNativeRoot(
    adapter: MilaFfiAdapter = LinkedMilaFfiAdapter(),
    materialProvider: MilaSessionMaterialProvider? = null,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val sessionMaterialProvider = remember(materialProvider, context) {
        materialProvider ?: AndroidMilaSessionMaterialProvider(context)
    }
    var route by remember { mutableStateOf<MilaRoute>(MilaRoute.Machines) }
    var connection by remember { mutableStateOf<MilaSessionConnection>(MilaSessionConnection.Idle) }
    val deploymentStore = remember { MilaSharedPreferencesDeploymentStore(LocalContext.current.getSharedPreferences("mila.deployment", 0)) }
    val savedDeployment = remember { deploymentStore.read() }
    val deployment = remember { MilaDeploymentSelection(listOfNotNull(savedDeployment)) }
    var selectedDeployment by remember { mutableStateOf(deployment.selected) }
    var deploymentEntries by remember { mutableStateOf(deployment.deployments) }
    var hostInput by remember { mutableStateOf(selectedDeployment?.host.orEmpty()) }
    var hostInvalid by remember { mutableStateOf(false) }
    val signIn = remember { MilaSignInController(adapter, deploymentStore) }
    val machineDetail = remember { MilaMachineDetailController(adapter) }
    val threadDetail = remember { MilaThreadDetailController(adapter) }
    var signInState by remember { mutableStateOf<MilaSignInState>(MilaSignInState.SignedOut) }
    fun refresh() { scope.launch {
        connection = MilaSessionConnection.Refreshing
        connection = MilaSessionRefresher.refresh(adapter)
    } }
    val status = when (connection) {
        MilaSessionConnection.Idle -> MilaStrings.text(MilaMessage.Ready)
        MilaSessionConnection.Refreshing -> MilaStrings.text(MilaMessage.Connecting)
        is MilaSessionConnection.Connected -> MilaStrings.text(MilaMessage.Connected)
        is MilaSessionConnection.Failed -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
    }
    val listing = (signInState as? MilaSignInState.SignedIn)?.listing ?: (connection as? MilaSessionConnection.Connected)?.listing
    machineDetail.setSession(signInState is MilaSignInState.SignedIn, listing)
    Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(MilaStrings.text(MilaMessage.AppName), style = MaterialTheme.typography.headlineSmall)
        MilaDeploymentPicker(
            deployments = deploymentEntries,
            selected = selectedDeployment,
            host = hostInput,
            invalidHost = hostInvalid,
            onHostChanged = {
                hostInput = it
                hostInvalid = false
            },
            onSelect = { selected ->
                deployment.select(selected.host, selected.port)
                deploymentStore.write(selected)
                selectedDeployment = selected
                hostInput = selected.label
                hostInvalid = false
            },
            onAdd = {
                parseMilaDeploymentHost(hostInput).fold(
                    onSuccess = { added ->
                        deployment.add(added)
                        deployment.select(added.host, added.port)
                        deploymentStore.write(added)
                        deploymentEntries = deployment.deployments
                        selectedDeployment = added
                        hostInput = added.label
                        hostInvalid = false
                    },
                    onFailure = { hostInvalid = true },
                )
            },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({
                selectedDeployment?.let { selected ->
                    scope.launch {
                        signInState = MilaSignInState.Connecting(selected)
                        sessionMaterialProvider.resolve(selected).fold(
                            onSuccess = { material ->
                                signIn.signIn(selected, material.config, material.signer)
                                signInState = signIn.state
                            },
                            onFailure = {
                                signInState = MilaSignInState.Failed(selected, MilaFfiError.Unavailable)
                            },
                        )
                    }
                }
            }, enabled = selectedDeployment != null) { Text(MilaStrings.text(MilaMessage.SignIn)) }
            Button({ route = MilaRoute.Machines }) { Text(MilaStrings.text(MilaMessage.Machines)) }
            Button({ route = MilaRoute.Threads }) { Text(MilaStrings.text(MilaMessage.Threads)) }
            Button({ route = MilaRoute.Settings }) { Text(MilaStrings.text(MilaMessage.Settings)) }
            Button(::refresh) { Text(MilaStrings.text(MilaMessage.Refresh)) }
        }
        Text(status, style = MaterialTheme.typography.labelSmall)
        if (signInState is MilaSignInState.SignedIn) Text(MilaStrings.text(MilaMessage.Connected), style = MaterialTheme.typography.labelSmall)
        when (val selected = route) {
            MilaRoute.Machines -> MachineList(adapter, status, listing) { route = MilaRoute.Machine(it.id); machineDetail.select(it.id) }
            is MilaRoute.Machine -> MachineDetail(machineDetail, selected.id, adapter)
            MilaRoute.Threads -> ThreadList(adapter)
            is MilaRoute.Thread -> ThreadDetail(threadDetail, selected.id)
            MilaRoute.Settings -> MilaSettingsScreen()
        }
        if (route == MilaRoute.Machines && signInState is MilaSignInState.SignedIn) TerminalControls(adapter)
    }
    LaunchedEffect(Unit) {
        val saved = selectedDeployment
        if (saved != null) {
            sessionMaterialProvider.resolve(saved).onSuccess { material ->
                signIn.signIn(saved, material.config, material.signer)
                signInState = signIn.state
            }
        }
    }
}

@Composable
private fun MilaDeploymentPicker(
    deployments: List<MilaDeployment>,
    selected: MilaDeployment?,
    host: String,
    invalidHost: Boolean,
    onHostChanged: (String) -> Unit,
    onSelect: (MilaDeployment) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.Deployments), style = MaterialTheme.typography.titleMedium)
        deployments.forEach { deployment ->
            Button({ onSelect(deployment) }, enabled = deployment != selected) {
                Text(deployment.label, style = MaterialTheme.typography.bodyMedium)
            }
        }
        OutlinedTextField(
            value = host,
            onValueChange = onHostChanged,
            label = { Text(MilaStrings.text(MilaMessage.DeploymentHost)) },
            placeholder = { Text(MilaStrings.text(MilaMessage.DeploymentHostHint)) },
            isError = invalidHost,
            singleLine = true,
        )
        if (invalidHost) {
            Text(MilaStrings.text(MilaMessage.InvalidHost), style = MaterialTheme.typography.labelSmall)
        }
        Button({ onAdd() }, enabled = host.isNotBlank()) {
            Text(MilaStrings.text(MilaMessage.AddDeployment))
        }
    }
}

@Composable
private fun MilaSettingsScreen() {
    val context = LocalContext.current
    val controller = remember { MilaSettingsController(MilaSharedPreferencesStore(context.getSharedPreferences("mila.settings", 0))) }
    var settings by remember { mutableStateOf(controller.load()) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.Settings), style = MaterialTheme.typography.titleLarge)
        Text("${MilaStrings.text(MilaMessage.Appearance)}: ${settings.appearance}")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MilaAppearance.entries.forEach { appearance ->
                Button({ settings = settings.copy(appearance = appearance); controller.save(settings) }) { Text(appearance.name) }
            }
        }
        Text("${MilaStrings.text(MilaMessage.Locale)}: ${settings.locale}")
    }
}

@Composable private fun TerminalControls(adapter: MilaFfiAdapter) {
    var result by remember { mutableStateOf("Terminal idle") }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(MilaStrings.text(MilaMessage.Terminal), style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({ result = if (adapter.terminalAttach(0, 80, 24, true).isSuccess) "Attached" else "Attach rejected" }) { Text(MilaStrings.text(MilaMessage.Attach)) }
            Button({ result = if (adapter.terminalInput(0, true).isSuccess) "Input ready" else "Input rejected" }) { Text(MilaStrings.text(MilaMessage.Input)) }
            Button({ result = if (adapter.terminalResize(80, 24, true).isSuccess) "Resized" else "Resize rejected" }) { Text(MilaStrings.text(MilaMessage.Resize)) }
        }
        Text(result, style = MaterialTheme.typography.labelSmall)
    }
}

@Composable private fun MachineList(adapter: MilaFfiAdapter, status: String, listing: MilaSessionListing?, onSelect: (MilaMachineRow) -> Unit) {
    var classified by remember { mutableStateOf<MilaMachineCommand?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(status, style = MaterialTheme.typography.bodyMedium)
        listing?.machines?.forEach { machine ->
            Button({ onSelect(machine) }) { Text("${machine.name} · ${machine.status}", style = MaterialTheme.typography.bodyMedium) }
        }
        Text(MilaStrings.text(MilaMessage.MachineActions), style = MaterialTheme.typography.titleMedium)
        machineCommandChoices.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { choice ->
                    Button({ classified = adapter.machineCommandKind(choice.command).getOrNull() }) {
                        Text(choice.label)
                    }
                }
            }
        }
        Text(classified?.name ?: MilaStrings.text(MilaMessage.NoAction), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable private fun MachineDetail(controller: MilaMachineDetailController, id: java.util.UUID, adapter: MilaFfiAdapter) {
    val scope = rememberCoroutineScope()
    val state = controller.state
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.MachineActions), style = MaterialTheme.typography.titleLarge)
        Text(id.toString(), style = MaterialTheme.typography.labelSmall)
        val machine = when (state) {
            is MilaMachineMutationState.Ready -> state.machine
            is MilaMachineMutationState.Submitting -> state.machine
            is MilaMachineMutationState.Applied -> state.machine
            is MilaMachineMutationState.Failed -> state.machine
            else -> null
        }
        if (machine != null) Text("${machine.name} · ${machine.status}")
        machineCommandChoices.filter { it.command in setOf("start", "stop", "pause", "resume", "rm", "resize") }.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { choice ->
                    Button({
                        controller.select(id)
                        controllerSelect(controller, choice.command, scope)
                    }) { Text(choice.label) }
                }
            }
        }
        MachineSharingControls(adapter, machine)
        if (machine != null) MilaWebControls(adapter, machine)
        Text(
            when (val current = controller.state) {
                MilaMachineMutationState.SignedOut -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
                MilaMachineMutationState.Idle -> MilaStrings.text(MilaMessage.NoAction)
                is MilaMachineMutationState.Ready -> "Ready"
                is MilaMachineMutationState.Submitting -> "Submitting ${current.command.name}"
                is MilaMachineMutationState.Applied -> "Applied ${current.command.name}"
                is MilaMachineMutationState.Failed -> current.reason
            },
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

@Composable
private fun MachineSharingControls(adapter: MilaFfiAdapter, machine: MilaMachineRow?) {
    var principal by remember { mutableStateOf("") }
    var result by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    // Sharing commands are classified and submitted by the typed controller.
    val controller = remember { MilaMachineSharingController(adapter) }
    if (machine != null) { controller.setSession(true, MilaSessionListing(listOf(machine), false)); controller.setMachine(machine) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedTextField(value = principal, onValueChange = { principal = it }, label = { Text(MilaStrings.text(MilaMessage.SharePrincipal)) })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({ scope.launch { result = if (controller.submit(principal)) MilaStrings.text(MilaMessage.ShareAdded) else MilaStrings.text(MilaMessage.ShareRejected) } }) { Text(MilaStrings.text(MilaMessage.ShareAdd)) }
            Button({ scope.launch { result = if (controller.submit(principal, remove = true)) MilaStrings.text(MilaMessage.ShareRemoved) else MilaStrings.text(MilaMessage.ShareRejected) } }) { Text(MilaStrings.text(MilaMessage.ShareRemove)) }
        }
        if (result.isNotEmpty()) Text(result, style = MaterialTheme.typography.labelSmall)
    }
}

private fun controllerSelect(controller: MilaMachineDetailController, command: String, scope: kotlinx.coroutines.CoroutineScope) {
    val value = MilaMachineCommand.entries.firstOrNull { it.name.equals(command, ignoreCase = true) }
        ?: when (command) { "rm" -> MilaMachineCommand.Delete; else -> null }
        ?: return
    scope.launch { controller.submit(value) }
}

@Composable private fun ThreadDetail(controller: MilaThreadDetailController, id: java.util.UUID) {
    val scope = rememberCoroutineScope()
    var input by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value = input, onValueChange = { if (it.length <= 4096) input = it }, label = { Text(MilaStrings.text(MilaMessage.Input)) })
        Text(MilaStrings.text(MilaMessage.ThreadCommands), style = MaterialTheme.typography.titleLarge)
        Text(id.toString(), style = MaterialTheme.typography.labelSmall)
        threadCommandChoices.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { (label, raw) ->
                    Button({
                        val command = when (raw) {
                            "thread ls" -> MilaThreadCommand.List
                            "thread show" -> MilaThreadCommand.Show
                            "thread turns" -> MilaThreadCommand.Turns
                            "thread prompt" -> MilaThreadCommand.Prompt
                            "thread answer" -> MilaThreadCommand.Answer
                            "thread plan approve" -> MilaThreadCommand.PlanApprove
                            "thread plan revise" -> MilaThreadCommand.PlanRevise
                            "thread mode" -> MilaThreadCommand.Mode
                            "thread read" -> MilaThreadCommand.Read
                            else -> null
                        }
                        if (command != null) scope.launch {
                            val payload = input.takeIf { command == MilaThreadCommand.Prompt || command == MilaThreadCommand.Answer || command == MilaThreadCommand.PlanRevise }
                            controller.submit(command, payload)
                        }
                    }) { Text(label) }
                }
            }
        }
        Text(
            when (val state = controller.state) {
                MilaThreadActionState.SignedOut -> MilaStrings.text(MilaMessage.RuntimeUnavailable)
                MilaThreadActionState.Idle -> MilaStrings.text(MilaMessage.NoCommand)
                is MilaThreadActionState.Ready -> "Ready"
                is MilaThreadActionState.Submitting -> "Submitting ${state.command.name}"
                is MilaThreadActionState.Applied -> "Applied ${state.command.name}"
                is MilaThreadActionState.Failed -> state.reason
            }, style = MaterialTheme.typography.labelSmall,
        )
    }
}
@Composable private fun ThreadList(adapter: MilaFfiAdapter) {
    var classified by remember { mutableStateOf<MilaThreadCommand?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(MilaStrings.text(MilaMessage.ThreadCommands), style = MaterialTheme.typography.titleLarge)
        Text("Commands are classified by Rust before execution.", style = MaterialTheme.typography.bodyMedium)
        threadCommandChoices.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { (label, command) ->
                    Button({ classified = adapter.threadCommandKind(command).getOrNull() }) {
                        Text(label)
                    }
                }
            }
        }
        Text(classified?.name ?: MilaStrings.text(MilaMessage.NoCommand), style = MaterialTheme.typography.bodyMedium)
    }
}
@Composable private fun Detail(title: String, value: String) { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { Text(title, style = MaterialTheme.typography.titleLarge); Text(value, style = MaterialTheme.typography.bodyMedium) } }
