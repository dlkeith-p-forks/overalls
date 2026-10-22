package dev.overalls.mila.nativeui
import org.junit.Assert.assertEquals
import org.junit.Test
import androidx.compose.ui.graphics.Color
class MilaDesignSystemTest { @Test fun usesFourTokenMonochromePalette(){ assertEquals(Color(0xFF000000),MilaColors.LightText); assertEquals(Color(0xFFFFFFFF),MilaColors.LightBackground); assertEquals(Color(0xFF666666),MilaColors.LightTextAlt); assertEquals(Color(0xFFEEEEEE),MilaColors.LightBackgroundAlt) } }
