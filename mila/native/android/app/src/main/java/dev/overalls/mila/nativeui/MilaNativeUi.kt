package dev.overalls.mila.nativeui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
fun MilaNativeRoot(adapter: MilaFfiAdapter = UnavailableMilaFfiAdapter) {
    val scope = rememberCoroutineScope()
    val status = remember { mutableStateOf("Ready") }
    Column(
        modifier = Modifier.padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Mila", style = MaterialTheme.typography.titleLarge)
        Text("Native Mila", style = MaterialTheme.typography.bodyMedium)
        Text(status.value, style = MaterialTheme.typography.labelSmall)
        Button(
            onClick = {
                scope.launch {
                    status.value = when (adapter.call(MilaFfiRequest(MilaFfiOperation.Bootstrap))) {
                        is MilaFfiResult.Success -> "Connected"
                        is MilaFfiResult.Failure -> "Native runtime unavailable"
                    }
                }
            },
        ) {
            Text("Check native bridge")
        }
    }
}
