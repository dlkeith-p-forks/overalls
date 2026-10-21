package dev.overalls.mila.nativeui

import org.json.JSONObject
import java.util.UUID

data class MilaMachineRow(val id: UUID, val name: String, val status: String)
data class MilaSessionListing(val machines: List<MilaMachineRow>, val hasMore: Boolean) {
    companion object {
        fun decode(bytes: ByteArray): MilaSessionListing {
            require(bytes.size <= 8 * 1024 * 1024) { "listing exceeds bound" }
            val root = JSONObject(bytes.toString(Charsets.UTF_8))
            val rows = root.optJSONArray("machines") ?: error("machines missing")
            require(rows.length() <= 10_000) { "too many machines" }
            val machines = buildList(rows.length()) {
                for (index in 0 until rows.length()) {
                    val row = rows.optJSONObject(index) ?: error("invalid machine row")
                    val id = runCatching { UUID.fromString(row.getString("id")) }.getOrElse { error("invalid machine id") }
                    add(MilaMachineRow(id, row.optString("name", id.toString()), row.optString("status", "unknown")))
                }
            }
            return MilaSessionListing(machines, root.optBoolean("has_more", false))
        }
    }
}

/** Typed projection of a Rust listing; malformed or oversized native data is refused. */
fun MilaSessionHandle.decodeListing(): MilaSessionListing = MilaSessionListing.decode(listing())
