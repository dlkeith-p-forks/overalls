package dev.overalls.mila.nativeui

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONObject
import java.net.URI

/** A browser approval link and its device-key fingerprint, retained only in memory. */
data class MilaApprovalInfo(val url: String, val fingerprint: String) {
    init {
        require(url.length in 1..2048) { "invalid approval URL" }
        val parsed = URI(url)
        require(parsed.scheme.equals("https", ignoreCase = true)) { "approval URL must use HTTPS" }
        require(parsed.userInfo == null) { "approval URL user info refused" }
        require(!parsed.host.isNullOrBlank() && parsed.fragment == null) { "approval URL host or fragment invalid" }
        require(fingerprint.matches(FINGERPRINT)) { "invalid approval fingerprint" }
    }

    companion object {
        private val FINGERPRINT = Regex("^SHA256:[A-Za-z0-9+/]{43}$")

        fun decode(bytes: ByteArray): MilaWhoami = runCatching {
            require(bytes.size <= 64 * 1024) { "whoami response too large" }
            val value = JSONObject(bytes.toString(Charsets.UTF_8))
            require(value.optInt("version", -1) == 1) { "invalid whoami version" }
            when (value.optString("status")) {
                "approval_required" -> MilaWhoami.Pending(
                    MilaApprovalInfo(value.getString("approval_url"), value.getString("fingerprint")),
                )
                "succeeded" -> MilaWhoami.Approved
                else -> MilaWhoami.Refused
            }
        }.getOrElse { MilaWhoami.Invalid }
    }
}

sealed interface MilaWhoami {
    data object Approved : MilaWhoami
    data class Pending(val approval: MilaApprovalInfo) : MilaWhoami
    data object Refused : MilaWhoami
    data object Invalid : MilaWhoami
}

/** Opens only a Rust-validated HTTPS approval URL; it never submits credentials. */
fun interface MilaApprovalBrowser {
    fun open(approval: MilaApprovalInfo): Boolean
}

class AndroidMilaApprovalBrowser(private val context: Context) : MilaApprovalBrowser {
    override fun open(approval: MilaApprovalInfo): Boolean = runCatching {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(approval.url)).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        true
    }.getOrDefault(false)
}
