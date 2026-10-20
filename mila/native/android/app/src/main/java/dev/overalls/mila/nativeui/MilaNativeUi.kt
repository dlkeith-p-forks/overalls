package dev.overalls.mila.nativeui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
fun MilaNativeRoot(adapter: MilaFfiAdapter = UnavailableMilaFfiAdapter) {
    val scope = rememberCoroutineScope()
    Column(
        modifier = Modifier.padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Mila", style = MaterialTheme.typography.titleLarge)
        Text("Native UI scaffold", style = MaterialTheme.typography.bodyMedium)
        Button(
            onClick = {
                scope.launch {
                    adapter.call(MilaFfiRequest(MilaFfiOperation.Bootstrap))
                }
            },
        ) {
            Text("Check native bridge")
        }
    }
}
