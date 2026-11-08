package com.lordxhobo.drift.social

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import android.util.Base64
import java.net.URLEncoder

/**
 * Drift's Firebase project, the same one the iPhone and computer use. Both values are public by design
 * (every Firebase app ships them); access is controlled by the Firestore security rules. Everything goes
 * through Firebase's plain web API, so Drift doesn't need Google services on the phone.
 */
object FirebaseConfig {
    const val PROJECT_ID = "drift-ymp"
    const val API_KEY = "AIzaSyCescn-3XQ1r48CmyUn1E2S2z4YxwVOmP4"
    const val DOCUMENTS_PATH = "projects/$PROJECT_ID/databases/(default)/documents"
    const val DOCUMENTS_URL = "https://firestore.googleapis.com/v1/$DOCUMENTS_PATH"
}

/** Something Drift's server said no to, in plain words. */
class SocialException(val status: Int, message: String) : Exception(message) {
    companion object {
        fun of(status: Int, body: String): SocialException {
            val msg = runCatching {
                ((Json.parseToJsonElement(body) as? JsonObject)?.get("error") as? JsonObject)?.get("message")?.let { (it as JsonPrimitive).content }
            }.getOrNull() ?: ""
            return SocialException(
                status,
                when {
                    status == 403 -> "Drift's server refused this. The security rules may not be set up yet."
                    msg.isNotEmpty() -> msg
                    else -> "Couldn't reach Drift's server."
                },
            )
        }
    }
}

class UsernameTakenException : Exception("That username was just taken.")
class SessionLostException : Exception("Your sign-in expired.")

// MARK: Sign-in (anonymous, no email)

/** The phone's sign-in: an invisible account made on first use, kept in the app's private storage. */
object FirebaseAuth {
    private lateinit var prefs: SharedPreferences
    private var uid: String? = null
    private var refreshToken: String? = null
    private var idToken: String? = null
    private var expiry = 0L

    fun init(context: Context) {
        prefs = context.getSharedPreferences("drift.firebase", Context.MODE_PRIVATE)
        uid = prefs.getString("uid", null)
        refreshToken = prefs.getString("refreshToken", null)
    }

    fun currentUid(): String? = uid

    /** A valid sign-in token, creating the account on first use. Blocking. */
    @Synchronized
    fun token(): String {
        idToken?.let { if (expiry > System.currentTimeMillis() + 60_000) return it }
        val rt = refreshToken
        if (rt != null) refresh(rt) else signUp()
        return idToken ?: throw SocialException(401, "You're not signed in.")
    }

    fun signedInUid(): String {
        token()
        return uid ?: throw SocialException(401, "You're not signed in.")
    }

    /** This phone's sign-in (for linking a computer to the same profile). */
    fun session(): Pair<String, String> {
        token()
        return (uid ?: throw SocialException(401, "You're not signed in.")) to (refreshToken ?: throw SocialException(401, "You're not signed in."))
    }

    private fun signUp() {
        val (status, body) = Net.send(
            "POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FirebaseConfig.API_KEY}",
            """{"returnSecureToken":true}""",
        )
        val d = if (status == 200) Json.parseToJsonElement(body) as? JsonObject else null
        val id = FV.str(d?.get("idToken"))
        val rt = FV.str(d?.get("refreshToken"))
        val local = FV.str(d?.get("localId"))
        if (id == null || rt == null || local == null) throw SocialException.of(status, body)
        store(local, id, rt, FV.str(d?.get("expiresIn")))
    }

    private fun refresh(rt: String) {
        val (status, body) = Net.send(
            "POST", "https://securetoken.googleapis.com/v1/token?key=${FirebaseConfig.API_KEY}",
            "grant_type=refresh_token&refresh_token=" + URLEncoder.encode(rt, "UTF-8"),
            contentType = "application/x-www-form-urlencoded",
        )
        val d = if (status == 200) Json.parseToJsonElement(body) as? JsonObject else null
        val id = FV.str(d?.get("id_token"))
        val newRt = FV.str(d?.get("refresh_token"))
        val user = FV.str(d?.get("user_id"))
        if (id == null || newRt == null || user == null) {
            if (status == 400) throw SessionLostException()
            throw SocialException.of(status, body)
        }
        store(user, id, newRt, FV.str(d?.get("expires_in")))
    }

    private fun store(uid: String, id: String, refresh: String, expiresIn: String?) {
        this.uid = uid
        idToken = id
        refreshToken = refresh
        expiry = System.currentTimeMillis() + (expiresIn?.toLongOrNull() ?: 3600L) * 1000
        prefs.edit().putString("uid", uid).putString("refreshToken", refresh).apply()
    }

    /** Forget this phone's account (used when deleting the profile). */
    @Synchronized
    fun forget() {
        uid = null
        idToken = null
        refreshToken = null
        expiry = 0
        prefs.edit().clear().apply()
    }
}

// MARK: Firestore (web API)

object Firestore {
    private fun url(path: String, query: List<Pair<String, String>> = emptyList()): String {
        val q = query.joinToString("&") { (k, v) -> k + "=" + URLEncoder.encode(v, "UTF-8") }
        return "${FirebaseConfig.DOCUMENTS_URL}/$path" + if (q.isEmpty()) "" else "?$q"
    }

    /** One document, or null when it doesn't exist. Blocking. */
    fun get(path: String): JsonObject? {
        val (status, body) = Net.send("GET", url(path), token = FirebaseAuth.token())
        if (status == 404) return null
        if (status != 200) throw SocialException.of(status, body)
        return Json.parseToJsonElement(body) as? JsonObject
    }

    /** Create or update. `mask` limits it to those fields; `mustNotExist` makes it create-only. */
    fun patch(path: String, fields: Map<String, JsonElement>, mask: List<String>? = null, mustNotExist: Boolean = false) {
        val q = mutableListOf<Pair<String, String>>()
        mask?.forEach { q.add("updateMask.fieldPaths" to it) }
        if (mustNotExist) q.add("currentDocument.exists" to "false")
        val body = buildJsonObject { put("fields", JsonObject(fields)) }.toString()
        val (status, text) = Net.send("PATCH", url(path, q), body, token = FirebaseAuth.token())
        if (mustNotExist && (status == 400 || status == 409)) throw UsernameTakenException()
        if (status != 200) throw SocialException.of(status, text)
    }

    /** The names of a collection's documents (their last path part). Blocking. */
    fun listNames(path: String): List<String> = list(path, listOf("updatedAt")).map { it.first }

    /** A collection's documents: name (last path part) and only the asked fields. Blocking. */
    fun list(path: String, fields: List<String>): List<Pair<String, JsonObject?>> {
        val out = mutableListOf<Pair<String, JsonObject?>>()
        var page: String? = null
        do {
            val q = mutableListOf("pageSize" to "300")
            fields.forEach { q.add("mask.fieldPaths" to it) }
            page?.let { q.add("pageToken" to it) }
            val (status, body) = Net.send("GET", url(path, q), token = FirebaseAuth.token())
            if (status == 404) return out
            if (status != 200) throw SocialException.of(status, body)
            val d = Json.parseToJsonElement(body) as? JsonObject
            (d?.get("documents") as? JsonArray).orEmpty().forEach { doc ->
                val o = doc as? JsonObject
                FV.str(o?.get("name"))?.let { out.add(it.substringAfterLast('/') to FV.fields(o)) }
            }
            page = FV.str(d?.get("nextPageToken"))
        } while (page != null)
        return out
    }

    /** A structured query (where, orderBy, limit) over a collection. Returns the documents found. */
    fun query(structured: JsonObject, parent: String = ""): List<JsonObject> {
        val url = if (parent.isEmpty()) "${FirebaseConfig.DOCUMENTS_URL}:runQuery" else "${FirebaseConfig.DOCUMENTS_URL}/$parent:runQuery"
        val body = buildJsonObject { put("structuredQuery", structured) }.toString()
        val (status, text) = Net.send("POST", url, body, token = FirebaseAuth.token())
        if (status != 200) throw SocialException.of(status, text)
        return (Json.parseToJsonElement(text) as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.get("document") as? JsonObject }
    }

    /** Several documents at once; missing ones are left out. */
    fun batchGet(paths: List<String>): List<JsonObject> {
        if (paths.isEmpty()) return emptyList()
        val out = mutableListOf<JsonObject>()
        for (chunk in paths.chunked(100)) {
            val body = buildJsonObject {
                put("documents", JsonArray(chunk.map { JsonPrimitive("${FirebaseConfig.DOCUMENTS_PATH}/$it") }))
            }.toString()
            val (status, text) = Net.send("POST", "${FirebaseConfig.DOCUMENTS_URL}:batchGet", body, token = FirebaseAuth.token())
            if (status != 200) throw SocialException.of(status, text)
            (Json.parseToJsonElement(text) as? JsonArray).orEmpty().forEach { r ->
                ((r as? JsonObject)?.get("found") as? JsonObject)?.let { out.add(it) }
            }
        }
        return out
    }

    fun delete(path: String) {
        val (status, body) = Net.send("DELETE", url(path), token = FirebaseAuth.token())
        if (status != 200 && status != 404) throw SocialException.of(status, body)
    }
}

/** Building and reading Firestore's typed values. */
object FV {
    fun s(v: String): JsonElement = buildJsonObject { put("stringValue", v) }
    fun b(v: Boolean): JsonElement = buildJsonObject { put("booleanValue", v) }
    fun i(v: Long): JsonElement = buildJsonObject { put("integerValue", v.toString()) }
    fun bytes(d: ByteArray): JsonElement = buildJsonObject { put("bytesValue", Base64.encodeToString(d, Base64.NO_WRAP)) }
    val nul: JsonElement get() = buildJsonObject { put("nullValue", JsonNull) }
    fun strings(v: List<String>): JsonElement =
        buildJsonObject { put("arrayValue", buildJsonObject { put("values", JsonArray(v.map { s(it) })) }) }

    fun d(v: Double): JsonElement = buildJsonObject { put("doubleValue", v) }
    fun map(fields: Map<String, JsonElement>): JsonElement =
        buildJsonObject { put("mapValue", buildJsonObject { put("fields", JsonObject(fields)) }) }
    fun array(values: List<JsonElement>): JsonElement =
        buildJsonObject { put("arrayValue", buildJsonObject { put("values", JsonArray(values)) }) }

    fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    /** A map field's own fields. */
    fun mapFields(f: JsonObject?, k: String): JsonObject? = ((value(f, k, "mapValue") as? JsonObject)?.get("fields")) as? JsonObject

    /** An array field's values (each a typed value). */
    fun values(f: JsonObject?, k: String): List<JsonObject> =
        ((value(f, k, "arrayValue") as? JsonObject)?.get("values") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }

    /** A number that may be stored as an integer or a double. */
    fun number(f: JsonObject?, k: String): Double? =
        str(value(f, k, "doubleValue"))?.toDoubleOrNull() ?: str(value(f, k, "integerValue"))?.toDoubleOrNull()

    /** The document's ID (last part of its name). */
    fun id(doc: JsonObject): String = str(doc["name"])?.substringAfterLast('/') ?: ""

    fun fields(doc: JsonObject?): JsonObject? = doc?.get("fields") as? JsonObject

    private fun value(f: JsonObject?, k: String, kind: String): JsonElement? = (f?.get(k) as? JsonObject)?.get(kind)

    fun string(f: JsonObject?, k: String): String? = str(value(f, k, "stringValue"))
    fun bool(f: JsonObject?, k: String): Boolean? = str(value(f, k, "booleanValue"))?.toBooleanStrictOrNull()
    fun long(f: JsonObject?, k: String): Long? = str(value(f, k, "integerValue"))?.toLongOrNull()
    fun data(f: JsonObject?, k: String): ByteArray? =
        str(value(f, k, "bytesValue"))?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() }

    fun stringArray(f: JsonObject?, k: String): List<String> =
        ((value(f, k, "arrayValue") as? JsonObject)?.get("values") as? JsonArray).orEmpty()
            .mapNotNull { str((it as? JsonObject)?.get("stringValue")) }
}
