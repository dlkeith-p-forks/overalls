package dev.overalls.mila.nativeui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private const val FINGERPRINT = "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"

class MilaApprovalTest {
    @Test fun decodesPendingApprovalWithoutPersistingSecrets() {
        val reply = """{"version":1,"status":"approval_required","fingerprint":"$FINGERPRINT","approval_url":"https://overalls.example/ssh/approve/abc"}"""
        val decoded = MilaApprovalInfo.decode(reply.toByteArray())
        assertEquals(
            MilaWhoami.Pending(MilaApprovalInfo("https://overalls.example/ssh/approve/abc", FINGERPRINT)),
            decoded,
        )
    }

    @Test fun refusesForeignOrUnsafeApprovalLinks() {
        val unsafe = listOf(
            "http://overalls.example/ssh/approve/abc",
            "https://user@overalls.example/ssh/approve/abc",
            "https://overalls.example/ssh/approve/abc#fragment",
        )
        unsafe.forEach { url ->
            assertTrue(MilaApprovalInfo.decode(
                """{"version":1,"status":"approval_required","fingerprint":"$FINGERPRINT","approval_url":"$url"}""".toByteArray(),
            ) is MilaWhoami.Invalid)
        }
    }

    @Test fun approvedAndMalformedRepliesAreTyped() {
        assertEquals(MilaWhoami.Approved, MilaApprovalInfo.decode("{\"version\":1,\"status\":\"succeeded\"}".toByteArray()))
        assertEquals(MilaWhoami.Invalid, MilaApprovalInfo.decode("{\"version\":2}".toByteArray()))
    }
}
