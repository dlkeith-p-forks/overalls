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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
fun MilaNativeRoot(adapter: MilaFfiAdapter = UnavailableMilaFfiAdapter) {
    val scope = rememberCoroutineScope()
    var route by remember { mutableStateOf<MilaRoute>(MilaRoute.Machines) }
    var status by remember { mutableStateOf("Ready") }
    fun refresh() { scope.launch { status = when (adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh))) { is MilaFfiResult.Success -> "Connected"; is MilaFfiResult.Failure -> "Native runtime unavailable" } } }
    Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Mila", style = MaterialTheme.typography.headlineSmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({ route = MilaRoute.Machines }) { Text("Machines") }
            Button({ route = MilaRoute.Threads }) { Text("Threads") }
            Button({ route = MilaRoute.Settings }) { Text("Settings") }
            Button(::refresh) { Text("Refresh") }
        }
        Text(status, style = MaterialTheme.typography.labelSmall)
        when (val selected = route) {
            MilaRoute.Machines -> MachineList { route = MilaRoute.Machine(it) }
            is MilaRoute.Machine -> Detail("Machine", selected.id.toString())
            MilaRoute.Threads -> ThreadList { route = MilaRoute.Thread(it) }
            is MilaRoute.Thread -> Detail("Thread", selected.id.toString())
            MilaRoute.Settings -> Detail("Settings", "Runtime settings are managed by the core library.")
        }
    }
    LaunchedEffect(Unit) { refresh() }
}

@Composable private fun MachineList(select: (java.util.UUID) -> Unit) { val id = java.util.UUID.fromString("00000000-0000-0000-0000-000000000001"); Button({ select(id) }) { Text("Development machine") } }
@Composable private fun ThreadList(select: (java.util.UUID) -> Unit) { val id = java.util.UUID.fromString("00000000-0000-0000-0000-000000000003"); Button({ select(id) }) { Text("Recent thread") } }
@Composable private fun Detail(title: String, value: String) { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { Text(title, style = MaterialTheme.typography.titleLarge); Text(value, style = MaterialTheme.typography.bodyMedium) } }
