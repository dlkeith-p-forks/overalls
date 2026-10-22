package dev.overalls.mila.nativeui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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

@Composable
fun MilaNativeRoot(adapter: MilaFfiAdapter = LinkedMilaFfiAdapter()) {
    val scope = rememberCoroutineScope()
    var route by remember { mutableStateOf<MilaRoute>(MilaRoute.Machines) }
    var connection by remember { mutableStateOf<MilaSessionConnection>(MilaSessionConnection.Idle) }
    val deployment = remember { MilaDeploymentSelection(listOf(MilaDeployment("mila.example"))) }
    val signIn = remember { MilaSignInController(adapter) }
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
    val listing = (connection as? MilaSessionConnection.Connected)?.listing
    Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(MilaStrings.text(MilaMessage.AppName), style = MaterialTheme.typography.headlineSmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Deployment: ${deployment.selected?.label ?: "none"}")
            Button({ scope.launch { signIn.signIn(deployment.selected!!); signInState = signIn.state } }) { Text("Sign in") }
            Button({ route = MilaRoute.Machines }) { Text(MilaStrings.text(MilaMessage.Machines)) }
            Button({ route = MilaRoute.Threads }) { Text(MilaStrings.text(MilaMessage.Threads)) }
            Button({ route = MilaRoute.Settings }) { Text(MilaStrings.text(MilaMessage.Settings)) }
            Button(::refresh) { Text(MilaStrings.text(MilaMessage.Refresh)) }
        }
        Text(status, style = MaterialTheme.typography.labelSmall)
        if (signInState is MilaSignInState.SignedIn) Text("Signed in", style = MaterialTheme.typography.labelSmall)
        when (val selected = route) {
            MilaRoute.Machines -> MachineList(adapter, status, listing)
            is MilaRoute.Machine -> Detail("Machine", selected.id.toString())
            MilaRoute.Threads -> ThreadList(adapter)
            is MilaRoute.Thread -> Detail("Thread", selected.id.toString())
            MilaRoute.Settings -> Detail("Settings", "Runtime settings are managed by the core library.")
        }
        if (route == MilaRoute.Machines) TerminalControls(adapter)
    }
    LaunchedEffect(Unit) { refresh() }
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

@Composable private fun MachineList(adapter: MilaFfiAdapter, status: String, listing: MilaSessionListing?) {
    var classified by remember { mutableStateOf<MilaMachineCommand?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(status, style = MaterialTheme.typography.bodyMedium)
        listing?.machines?.forEach { machine -> Text("${machine.name} · ${machine.status}", style = MaterialTheme.typography.bodyMedium) }
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
