package com.lordxhobo.drift.social

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Linking Drift on a computer to this phone's profile, so both share one library. Same as the iPhone:
 * the computer shows a code and posts it (with its public key) to pairings/{code}. The phone answers
 * with its sign-in, encrypted so only that computer can read it (P-256 key agreement, HKDF-SHA256,
 * AES-GCM).
 */
object ComputerLink {
    class Request(val code: String, val device: String, val key: ByteArray)

    class LinkException(message: String) : Exception(message)

    private const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /** Upper-case, without the dash or anything that can't be in a code. */
    fun normalize(s: String): String = s.uppercase().filter { it in ALPHABET }.take(8)

    suspend fun lookUp(raw: String): Request = withContext(Dispatchers.IO) {
        val code = normalize(raw)
        if (code.length != 8) throw LinkException("That code wasn't found. Check it against the one on your computer.")
        if (Social.me == null) throw LinkException("Create a Drift profile first. Your library syncs through it.")
        val f = FV.fields(Firestore.get("pairings/$code"))
            ?: throw LinkException("That code wasn't found. Check it against the one on your computer.")
        if (FV.data(f, "box") != null) throw LinkException("That code was already used. Make a new one on your computer.")
        val created = FV.long(f, "createdAt") ?: 0
        if (System.currentTimeMillis() - created > 10 * 60_000) throw LinkException("That code has expired. Make a new one on your computer.")
        val key = FV.data(f, "desktopKey") ?: throw LinkException("That code wasn't found. Check it against the one on your computer.")
        Request(code, FV.string(f, "device") ?: "your computer", key)
    }

    suspend fun link(r: Request) = withContext(Dispatchers.IO) {
        if (Social.me == null) throw LinkException("Create a Drift profile first. Your library syncs through it.")
        val (uid, refreshToken) = FirebaseAuth.session()
        val plain = buildJsonObject {
            put("uid", uid)
            put("refreshToken", refreshToken)
        }.toString().toByteArray()
        val (phoneKey, box) = seal(plain, r.key, r.code)
        Firestore.patch(
            "pairings/${r.code}",
            mapOf("phoneKey" to FV.bytes(phoneKey), "box" to FV.bytes(box)),
            mask = listOf("phoneKey", "box"),
        )
    }

    /** Encrypts for the computer's key. Returns this phone's public key (X9.63) and nonce + ciphertext + tag. */
    fun seal(plain: ByteArray, desktopKey: ByteArray, code: String): Pair<ByteArray, ByteArray> {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"))
        val mine = gen.generateKeyPair()
        val myPublic = mine.public as ECPublicKey

        // The computer's key: 0x04, then X and Y (32 bytes each).
        if (desktopKey.size != 65 || desktopKey[0] != 4.toByte()) throw LinkException("That code wasn't found. Check it against the one on your computer.")
        val point = ECPoint(BigInteger(1, desktopKey.copyOfRange(1, 33)), BigInteger(1, desktopKey.copyOfRange(33, 65)))
        val theirs = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, myPublic.params))

        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(mine.private)
        agreement.doPhase(theirs, true)
        val secret = agreement.generateSecret()
        val key = hkdf(secret, code.toByteArray(), "drift-pairing-v1".toByteArray(), 32)

        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        val sealed = cipher.doFinal(plain) // ciphertext + tag

        val x963 = byteArrayOf(4) + fixed(myPublic.w.affineX) + fixed(myPublic.w.affineY)
        return x963 to (nonce + sealed)
    }

    /** A coordinate as exactly 32 bytes. */
    private fun fixed(n: BigInteger): ByteArray {
        val b = n.toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size)
            else -> ByteArray(32 - b.size) + b
        }
    }

    /** HKDF with SHA-256 (RFC 5869). */
    fun hkdf(secret: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = extract.doFinal(secret)
        val expand = Mac.getInstance("HmacSHA256")
        expand.init(SecretKeySpec(prk, "HmacSHA256"))
        var out = ByteArray(0)
        var block = ByteArray(0)
        var counter = 1
        while (out.size < length) {
            expand.update(block)
            expand.update(info)
            expand.update(counter.toByte())
            block = expand.doFinal()
            out += block
            counter++
        }
        return out.copyOf(length)
    }
}
