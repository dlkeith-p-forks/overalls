package dev.overalls.mila.nativeui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MilaStrings.configure(this)
        setContent {
            MilaTheme { MilaNativeRoot(adapter = LinkedMilaFfiAdapter()) }
        }
    }
}
