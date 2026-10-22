package dev.overalls.mila.nativeui

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

object MilaColors { val LightText=Color(0xFF000000); val LightTextAlt=Color(0xFF666666); val LightBackground=Color(0xFFFFFFFF); val LightBackgroundAlt=Color(0xFFEEEEEE); val DarkText=Color(0xFFFFFFFF); val DarkTextAlt=Color(0xFFAAAAAA); val DarkBackground=Color(0xFF000000); val DarkBackgroundAlt=Color(0xFF111111) }
val MilaMono = FontFamily.Monospace
@Composable fun MilaTheme(content: @Composable () -> Unit) { MaterialTheme(colorScheme = lightColorScheme(primary=MilaColors.LightText, onPrimary=MilaColors.LightBackground, background=MilaColors.LightBackground, onBackground=MilaColors.LightText, surface=MilaColors.LightBackgroundAlt, onSurface=MilaColors.LightText), typography=Typography().copy(bodyLarge=Typography().bodyLarge.copy(fontFamily=MilaMono), bodyMedium=Typography().bodyMedium.copy(fontFamily=MilaMono)), content=content) }
val MilaBorderWidth = 2.dp
