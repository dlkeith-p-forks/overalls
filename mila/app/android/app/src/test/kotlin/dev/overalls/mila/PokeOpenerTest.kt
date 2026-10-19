package dev.overalls.mila

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Shared vectors from `protocol/test/fixtures/push_pokes.json`, copied inline
 * so the JVM test needs no repository paths. The same vectors test
 * `OverallsProtocol.PushPoke`, `mila_core` and the iOS opener.
 */
class PokeOpenerTest {
    private data class Valid(
        val name: String,
        val devicePrivate: String,
        val devicePublic: String,
        val host: String,
        val poke: String,
        val route: String,
    )

    private data class Invalid(
        val name: String,
        val devicePrivate: String,
        val host: String,
        val poke: String,
        val reason: PokeOpener.Refusal,
    )

    private fun hex(text: String) = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private val valid = listOf(
        Valid(
            "needs input 1",
            "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
            "953562bec9901980512d93093a46a20df80045fcd8224e8f983ab09ac4665c43",
            "control.example.test",
            "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
            "/machines/2f0b8f8e-3c1d-4a8e-9b3e-0c6f1d2a7b11/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12",
        ),
        Valid(
            "needs input 2",
            "588605bf5362e8b7f170c8b2926c4061ab09a7d95c74c6ff9b45140b6787e0de",
            "db253adf1e64b6d3fed7ac50915bee644ba655009eb53ac81447e9f6e5a69c46",
            "control.example.test",
            "AdgAhFkKTFO0D5_KI8HIKOMcYzdwTZZQvlclpFQhzZwKdHTB5-2SmvWA_mbkcyDe5n1tTWh8Oe1jmgoy0JG-ZFkCFBGmzdXTSemTvE8EnmwzOw36eJd_zYcR_xT5YutT9Tv6cfopxl18l3BcYP0ijixzhkzmwXUJxGHhxiqYuFXSQUFw1trC4oyN67rH6jXnTA",
            "/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12",
        ),
    )

    private val invalid = listOf(
        Invalid(
            "tampered ciphertext",
            "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
            "control.example.test",
            "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ukrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
            PokeOpener.Refusal.AUTHENTICATION,
        ),
        Invalid(
            "tampered ephemeral key",
            "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
            "control.example.test",
            "AWU0ylVAFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
            PokeOpener.Refusal.AUTHENTICATION,
        ),
        Invalid(
            "unknown version",
            "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
            "control.example.test",
            "AmU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
            PokeOpener.Refusal.VERSION,
        ),
        Invalid(
            "truncated",
            "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
            "control.example.test",
            "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4",
            PokeOpener.Refusal.LENGTH,
        ),
        Invalid(
            "other deployment",
            "03204de92e11fc8c528139be419065920eb83dbff1a4663bbea455aa6e9702bd",
            "other.example.test",
            "AWU0ylVBFgk84-DCEbfhgeWp-8Dn6rRa2enkrWwB05Rknj8VYyTULw6ktvT8EdB9-7ulrAA_P2lfpER4-bytMbsWM4-DIkUWpFLLYHf6GHg-pIH6ZBx4FP9CPx3yeCBmXJYZeBcX5j4eN016siuvQsifIzA9_b4su9tYuq5XmaPNEvmgGQtT2G8k8LQ1KWHuc8b4Fs6Zmztg0YCpuL1MOBNn582M-P_-_BLDYOevdDIB-6UwXUORRg3u7r4UYGA",
            PokeOpener.Refusal.AUTHENTICATION,
        ),
    )

    @Test
    fun validVectorsOpen() {
        for (vector in valid) {
            assertArrayEquals(vector.name, hex(vector.devicePublic), PokeOpener.publicKey(hex(vector.devicePrivate)))
            assertEquals(
                vector.name,
                PokeOpener.Opening.Opened(PokeOpener.Poke("needs_input", vector.route)),
                PokeOpener.open(vector.poke, vector.host, hex(vector.devicePrivate)),
            )
        }
    }

    @Test
    fun invalidVectorsAreRefused() {
        for (vector in invalid) {
            assertEquals(
                vector.name,
                PokeOpener.Opening.Refused(vector.reason),
                PokeOpener.open(vector.poke, vector.host, hex(vector.devicePrivate)),
            )
        }
    }

    @Test
    fun nonCanonicalEncodingsAreRefused() {
        val vector = valid[0]
        assertEquals(
            PokeOpener.Opening.Refused(PokeOpener.Refusal.ENCODING),
            PokeOpener.open(vector.poke + "=", vector.host, hex(vector.devicePrivate)),
        )
        assertNull(PokeOpener.decodeBase64Url("AB"))
        assertArrayEquals(byteArrayOf(0), PokeOpener.decodeBase64Url("AA"))
    }

    @Test
    fun plaintextSchemaIsExact() {
        assertEquals(
            PokeOpener.Poke("needs_input", "/threads"),
            PokeOpener.decodePlaintext("""{"kind":"needs_input","route":"/threads","v":1}""".toByteArray()),
        )
        for (json in listOf(
            """{"kind":"needs_input","route":"/threads"}""",
            """{"kind":"needs_input","route":"/threads","v":1.0}""",
            """{"kind":"needs_input","route":"/threads","v":true}""",
            """{"kind":"needs_input","route":"/threads","v":1,"v":1}""",
            """{"kind":"agent_done","route":"/threads","v":1}""",
            """{"kind":"needs_input","route":"https://evil.example/","v":1}""",
            """{"kind":"needs_input","route":"/threads","v":1,"title":"x"}""",
            """{"kind":"needs_input","route":"/threads","v":1} x""",
        )) {
            assertNull(json, PokeOpener.decodePlaintext(json.toByteArray()))
        }
    }
}
