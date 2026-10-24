import Foundation
import Security

/// Drift's Firebase project. Both values are public by design (every Firebase app ships them);
/// access is controlled by the Firestore security rules.
enum FirebaseConfig {
    static let projectID = "drift-ymp"
    static let apiKey = "AIzaSyCescn-3XQ1r48CmyUn1E2S2z4YxwVOmP4"
    static let documentsPath = "projects/\(projectID)/databases/(default)/documents"
    static let documentsURL = "https://firestore.googleapis.com/v1/\(documentsPath)"
}

enum SocialError: LocalizedError {
    case server(Int, String)
    case notSignedIn
    case usernameTaken
    case sessionLost

    var errorDescription: String? {
        switch self {
        case .server(403, _): return "Drift's server refused this. The security rules may not be set up yet."
        case .server(_, let msg): return msg.isEmpty ? "Couldn't reach Drift's server." : msg
        case .notSignedIn: return "You're not signed in."
        case .usernameTaken: return "That username was just taken."
        case .sessionLost: return "Your sign-in expired."
        }
    }
}

// MARK: Keychain

/// The sign-in is kept in the iPhone's Keychain, so it survives re-signing and reinstalling Drift.
enum Keychain {
    private static let service = "drift.firebase"
    private static let account = "session"

    struct Session: Codable {
        var uid: String
        var refreshToken: String
    }

    static func load() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ s: Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // Readable in the background after the first unlock (activity updates while locked).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }
}

// MARK: HTTP

enum HTTP {
    /// Sends a request and returns the status code and the decoded JSON (if any).
    static func send(_ method: String, _ url: URL, json: Any? = nil, form: String? = nil,
                     token: String? = nil) async throws -> (Int, Any?) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(form.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var body: Any?
        if !data.isEmpty { body = try? JSONSerialization.jsonObject(with: data) }
        return (status, body)
    }

    static func errorMessage(_ body: Any?) -> String {
        ((body as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? ""
    }
}

// MARK: Sign-in (anonymous, no email)

actor FirebaseAuth {
    static let shared = FirebaseAuth()

    private var uid: String?
    private var refreshToken: String?
    private var idToken: String?
    private var expiry = Date.distantPast

    init() {
        if let s = Keychain.load() {
            uid = s.uid
            refreshToken = s.refreshToken
        }
    }

    func currentUID() -> String? { uid }

    /// A valid sign-in token, creating the (invisible) account on first use.
    func token() async throws -> String {
        if let idToken, expiry > Date().addingTimeInterval(60) { return idToken }
        if let refreshToken {
            try await refresh(refreshToken)
        } else {
            try await signUp()
        }
        guard let idToken else { throw SocialError.notSignedIn }
        return idToken
    }

    func signedInUID() async throws -> String {
        _ = try await token()
        guard let uid else { throw SocialError.notSignedIn }
        return uid
    }

    private func signUp() async throws {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(FirebaseConfig.apiKey)")!
        let (status, body) = try await HTTP.send("POST", url, json: ["returnSecureToken": true])
        guard status == 200, let d = body as? [String: Any],
              let id = d["idToken"] as? String, let rt = d["refreshToken"] as? String,
              let localId = d["localId"] as? String else {
            throw SocialError.server(status, HTTP.errorMessage(body))
        }
        store(uid: localId, id: id, refresh: rt, expiresIn: d["expiresIn"])
    }

    private func refresh(_ rt: String) async throws {
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(FirebaseConfig.apiKey)")!
        let encoded = rt.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rt
        let (status, body) = try await HTTP.send("POST", url, form: "grant_type=refresh_token&refresh_token=\(encoded)")
        guard status == 200, let d = body as? [String: Any],
              let id = d["id_token"] as? String, let newRT = d["refresh_token"] as? String,
              let userID = d["user_id"] as? String else {
            if status == 400 { throw SocialError.sessionLost }
            throw SocialError.server(status, HTTP.errorMessage(body))
        }
        store(uid: userID, id: id, refresh: newRT, expiresIn: d["expires_in"])
    }

    private func store(uid: String, id: String, refresh: String, expiresIn: Any?) {
        self.uid = uid
        idToken = id
        refreshToken = refresh
        let secs = Double((expiresIn as? String) ?? "") ?? (expiresIn as? Double) ?? 3600
        expiry = Date().addingTimeInterval(secs)
        Keychain.save(Keychain.Session(uid: uid, refreshToken: refresh))
    }

    /// Forget this device's account (used when deleting the profile).
    func forget() {
        uid = nil
        idToken = nil
        refreshToken = nil
        expiry = .distantPast
        Keychain.delete()
    }
}

// MARK: Firestore (REST)

enum Firestore {
    private static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(string: "\(FirebaseConfig.documentsURL)/\(path)")!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    /// One document's raw JSON, or nil when it doesn't exist.
    static func get(_ path: String) async throws -> [String: Any]? {
        let token = try await FirebaseAuth.shared.token()
        let (status, body) = try await HTTP.send("GET", url(path), token: token)
        if status == 404 { return nil }
        guard status == 200 else { throw SocialError.server(status, HTTP.errorMessage(body)) }
        return body as? [String: Any]
    }

    /// Create or update. `mask` limits the update to those fields; `mustNotExist` makes it create-only.
    static func patch(_ path: String, fields: [String: Any], mask: [String]? = nil,
                      mustNotExist: Bool = false) async throws {
        let token = try await FirebaseAuth.shared.token()
        var q = (mask ?? []).map { URLQueryItem(name: "updateMask.fieldPaths", value: $0) }
        if mustNotExist { q.append(URLQueryItem(name: "currentDocument.exists", value: "false")) }
        let (status, body) = try await HTTP.send("PATCH", url(path, query: q), json: ["fields": fields], token: token)
        if mustNotExist, status == 400 || status == 409 { throw SocialError.usernameTaken }
        guard status == 200 else { throw SocialError.server(status, HTTP.errorMessage(body)) }
    }

    static func delete(_ path: String) async throws {
        let token = try await FirebaseAuth.shared.token()
        let (status, body) = try await HTTP.send("DELETE", url(path), token: token)
        guard status == 200 || status == 404 else { throw SocialError.server(status, HTTP.errorMessage(body)) }
    }

    /// Runs a query on a collection and returns the matching documents.
    static func query(_ structured: [String: Any]) async throws -> [[String: Any]] {
        let token = try await FirebaseAuth.shared.token()
        let u = URL(string: "\(FirebaseConfig.documentsURL):runQuery")!
        let (status, body) = try await HTTP.send("POST", u, json: ["structuredQuery": structured], token: token)
        guard status == 200 else { throw SocialError.server(status, HTTP.errorMessage(body)) }
        return ((body as? [[String: Any]]) ?? []).compactMap { $0["document"] as? [String: Any] }
    }

    /// Several documents at once (e.g. everyone you follow).
    static func batchGet(_ paths: [String]) async throws -> [[String: Any]] {
        guard !paths.isEmpty else { return [] }
        let token = try await FirebaseAuth.shared.token()
        let u = URL(string: "\(FirebaseConfig.documentsURL):batchGet")!
        let names = paths.map { "\(FirebaseConfig.documentsPath)/\($0)" }
        let (status, body) = try await HTTP.send("POST", u, json: ["documents": names], token: token)
        guard status == 200 else { throw SocialError.server(status, HTTP.errorMessage(body)) }
        return ((body as? [[String: Any]]) ?? []).compactMap { $0["found"] as? [String: Any] }
    }
}

/// Building and reading Firestore's typed values.
enum FV {
    static func s(_ v: String) -> [String: Any] { ["stringValue": v] }
    static func b(_ v: Bool) -> [String: Any] { ["booleanValue": v] }
    static func i(_ v: Int) -> [String: Any] { ["integerValue": String(v)] }
    static func bytes(_ d: Data) -> [String: Any] { ["bytesValue": d.base64EncodedString()] }
    static var null: [String: Any] { ["nullValue": NSNull()] }
    static func strings(_ v: [String]) -> [String: Any] { ["arrayValue": ["values": v.map { s($0) }]] }
    static func map(_ fields: [String: Any]) -> [String: Any] { ["mapValue": ["fields": fields]] }

    static func string(_ f: [String: Any]?, _ k: String) -> String? {
        (f?[k] as? [String: Any])?["stringValue"] as? String
    }
    static func bool(_ f: [String: Any]?, _ k: String) -> Bool? {
        (f?[k] as? [String: Any])?["booleanValue"] as? Bool
    }
    static func int(_ f: [String: Any]?, _ k: String) -> Int? {
        let v = (f?[k] as? [String: Any])?["integerValue"]
        if let s = v as? String { return Int(s) }
        return v as? Int
    }
    static func data(_ f: [String: Any]?, _ k: String) -> Data? {
        ((f?[k] as? [String: Any])?["bytesValue"] as? String).flatMap { Data(base64Encoded: $0) }
    }
    static func stringArray(_ f: [String: Any]?, _ k: String) -> [String] {
        let values = ((f?[k] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]]
        return (values ?? []).compactMap { $0["stringValue"] as? String }
    }
    static func mapFields(_ f: [String: Any]?, _ k: String) -> [String: Any]? {
        ((f?[k] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any]
    }
}
