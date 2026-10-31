import Foundation

/// Cliente HTTP genérico con sesión (cookie jar en memoria) para conexiones
/// `website` y `api` del vault. El token/password nunca sale de este proceso:
/// se inyecta como cabecera, query param o Basic auth según `details.auth`.
///
/// Política por conexión (`details.mode`), igual que SQL y SSH:
///   lectura → solo GET/HEAD/OPTIONS.
///   info    → bloquea escritura y muestra el curl equivalente.
///   edicion → POST/PUT/PATCH con confirm=true + Touch ID fresco; DELETE bloqueado.
///   unsafe  → cualquier método con confirm=true + Touch ID fresco.
final class HttpClient {
    struct Result {
        let ok: Bool
        let message: String
        let status: Int?
    }

    static let protocols: Set<String> = ["website", "api"]
    static let safeMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]
    static let destructiveMethods: Set<String> = ["DELETE"]
    static let defaultTimeout = 30
    static let maxBody = 20_000

    /// Cookie jar en memoria por conexión: vive lo que vive el servidor MCP.
    private static let jarQueue = DispatchQueue(label: "mx.gdw.vault.http-cookies")
    private static var cookieJars: [Int: [String: String]] = [:]

    private let store = Store.shared
    private let resolver = DbTunnel()

    func request(connectionName: String, method: String = "GET", path: String? = nil,
                 url: String? = nil, headers: [String: String]? = nil,
                 body: String? = nil, bodyJSON: Any? = nil,
                 query: [String: String]? = nil, followRedirects: Bool = true,
                 clearCookies: Bool = false, confirm: Bool = false,
                 timeout: Int = defaultTimeout) -> Result {
        let resolve = resolver.resolveConnection(name: connectionName, protocols: Self.protocols)
        guard case .found(let conn) = resolve else {
            switch resolve {
            case .notFound(let tried):
                return Result(ok: false, message: "No existe una conexión website/api llamada '\(connectionName)'. \(tried)", status: nil)
            case .ambiguous(let candidates):
                return Result(ok: false, message: "Varias conexiones coinciden con '\(connectionName)': \(candidates). Sé más específico.", status: nil)
            default:
                return Result(ok: false, message: "Conexión no encontrada", status: nil)
            }
        }
        let connName = conn["name"] as? String ?? connectionName
        let connId = conn["id"] as? Int ?? 0
        let details = store.detailsDict(from: conn)
        let base = details["url"] ?? ""
        let modeRaw = (details["mode"] ?? "lectura").lowercased()
        let mode = modeRaw == "safe" ? "lectura" : modeRaw

        let verb = method.uppercased()
        guard !verb.isEmpty, verb.allSatisfy({ $0.isLetter }) else {
            return Result(ok: false, message: "Método HTTP inválido: '\(method)'", status: nil)
        }
        let isWrite = !Self.safeMethods.contains(verb)
        let isDestructive = isWrite && Self.destructiveMethods.contains(verb)

        // Política de escritura — antes de tocar el Keychain (fail fast).
        if isWrite {
            switch mode {
            case "edicion":
                if isDestructive {
                    return Result(ok: false, message: """
                    🔒 Modo 'edición': permite POST/PUT/PATCH pero no \(verb). Ejecútalo tú en consola:

                    \(curlHint(conn: conn, details: details, method: verb, path: path, url: url))
                    """, status: nil)
                }
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO EDICIÓN — \(verb) modifica '\(connName)'.
                    Repite la llamada con confirm=true y aprueba el Touch ID.

                    Ruta: \(path ?? url ?? "/")
                    """, status: nil)
                }
            case "unsafe":
                guard confirm else {
                    return Result(ok: false, message: """
                    ⚠️ MODO UNSAFE — \(verb) modifica '\(connName)'.
                    Repite la llamada con confirm=true y aprueba el Touch ID.

                    Ruta: \(path ?? url ?? "/")
                    """, status: nil)
                }
            case "info":
                return Result(ok: false, message: """
                🔒 Modo 'info': no ejecuto peticiones de escritura. Ejecútalo tú en consola:

                \(curlHint(conn: conn, details: details, method: verb, path: path, url: url))
                """, status: nil)
            default:
                return Result(ok: false, message: "🔒 Modo 'lectura': solo GET/HEAD/OPTIONS. Cambia la conexión '\(connName)' a modo 'info', 'edición' o 'unsafe' si lo necesitas.", status: nil)
            }
        }

        // --- URL final -------------------------------------------------
        let requested = url.flatMap { $0.isEmpty ? nil : $0 }
            ?? (path.flatMap { $0.isEmpty ? nil : $0 }.map { join(base: base, path: $0) } ?? (base.isEmpty ? nil : base))
        guard var target = requested else {
            return Result(ok: false, message: "La conexión '\(connName)' no tiene URL guardada y no se indicó 'path'/'url'.", status: nil)
        }
        if !target.lowercased().hasPrefix("http://") && !target.lowercased().hasPrefix("https://") {
            target = "https://" + target
        }
        if var components = URLComponents(string: target), let extraQuery = query, !extraQuery.isEmpty {
            var items = components.queryItems ?? []
            for (key, value) in extraQuery { items.append(URLQueryItem(name: key, value: value)) }
            components.queryItems = items
            target = components.string ?? target
        }
        guard let finalURL = URL(string: target), let scheme = finalURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return Result(ok: false, message: "URL inválida: '\(target)' (solo http/https)", status: nil)
        }

        // --- Autenticación --------------------------------------------
        let usernameForAuth = conn["username"] as? String ?? ""
        let authType = (details["auth"] ?? (usernameForAuth.isEmpty ? "none" : "basic")).lowercased()
        var secret: String?
        var secretsToRedact: [String] = []
        if authType != "none" {
            if let account = conn["keychain_account"] as? String,
               let stored = KeychainStore.shared.getSecret(account: account), !stored.isEmpty {
                secret = stored
                secretsToRedact.append(stored)
            } else {
                return Result(ok: false, message: "La conexión '\(connName)' usa auth '\(authType)' pero no tiene token/password guardado.", status: nil)
            }
        }

        // Touch ID: lectura con ventana de gracia; escritura siempre fresco.
        if secret != nil {
            let granted = isWrite
                ? AuthSession.shared.forceAuthorize(reason: "GDW Vault: \(verb) con el token de \"\(connName)\" (modo \(mode)).")
                : AuthSession.shared.authorize(reason: "GDW Vault: petición \(verb) con el token de \"\(connName)\".")
            guard granted else {
                return Result(ok: false, message: "Touch ID rechazado", status: nil)
            }
            if let account = conn["keychain_account"] as? String, !account.isEmpty {
                AuthSession.shared.markSecretUsed(account: account)
            }
        }

        // --- Request ---------------------------------------------------
        var request = URLRequest(url: finalURL)
        request.httpMethod = verb
        request.timeoutInterval = TimeInterval(max(5, min(120, timeout)))
        var allHeaders: [String: String] = [
            "User-Agent": "GDWVault/1.0",
            "Accept": "*/*",
        ]
        for (key, value) in headers ?? [:] { allHeaders[key] = value }

        if let bodyJSON, body == nil {
            request.httpBody = try? JSONSerialization.data(withJSONObject: bodyJSON, options: [])
            if allHeaders.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                allHeaders["Content-Type"] = "application/json"
            }
        } else if let body {
            request.httpBody = Data(body.utf8)
            if allHeaders.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                allHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
            }
        }

        if let secret {
            switch authType {
            case "basic":
                let user = conn["username"] as? String ?? ""
                guard !user.isEmpty else {
                    return Result(ok: false, message: "auth=basic requiere 'username' en la conexión '\(connName)'.", status: nil)
                }
                let token = Data("\(user):\(secret)".utf8).base64EncodedString()
                // El header Basic lleva el secreto en base64: también se redacta.
                secretsToRedact.append(token)
                allHeaders["Authorization"] = "Basic \(token)"
            case "bearer":
                allHeaders["Authorization"] = "Bearer \(secret)"
            case "header":
                let headerName = details["header_name"] ?? "Authorization"
                allHeaders[headerName] = secret
            case "query":
                let param = details["query_param"] ?? "token"
                if var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
                    var items = components.queryItems ?? []
                    items.append(URLQueryItem(name: param, value: secret))
                    components.queryItems = items
                    request.url = components.url
                }
            default:
                break
            }
        }

        // --- Cookies de la sesión --------------------------------------
        if clearCookies {
            Self.jarQueue.sync { Self.cookieJars[connId] = [:] }
        }
        let cookies = Self.jarQueue.sync { Self.cookieJars[connId] ?? [:] }
        if !cookies.isEmpty,
           allHeaders.keys.first(where: { $0.lowercased() == "cookie" }) == nil {
            allHeaders["Cookie"] = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
        for (key, value) in allHeaders { request.setValue(value, forHTTPHeaderField: key) }

        // --- Ejecución -------------------------------------------------
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval + 10
        let delegate = RedirectController(follow: followRedirects)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var responseData: Data?
        var response: HTTPURLResponse?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, rawResponse, error in
            responseData = data
            response = rawResponse as? HTTPURLResponse
            failure = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .timedOut {
            task.cancel()
            return Result(ok: false, message: "La petición excedió el timeout de \(Int(request.timeoutInterval))s", status: nil)
        }
        if let failure {
            return Result(ok: false, message: "Error de red: \(failure.localizedDescription)", status: nil)
        }
        guard let response else {
            return Result(ok: false, message: "Sin respuesta HTTP", status: nil)
        }

        // --- Cookies nuevas --------------------------------------------
        if let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"), !setCookie.isEmpty {
            let parsed = Self.parseSetCookie(setCookie)
            if !parsed.isEmpty {
                Self.jarQueue.sync {
                    var jar = Self.cookieJars[connId] ?? [:]
                    for (name, value) in parsed { jar[name] = value }
                    Self.cookieJars[connId] = jar
                }
            }
        }

        // --- Salida ----------------------------------------------------
        let rawBody = responseData.flatMap { String(data: $0, encoding: .utf8) }
            ?? responseData.map { "(cuerpo binario: \($0.count) bytes)" }
            ?? ""
        var text = OutputText.redact(OutputText.truncate(rawBody, limit: Self.maxBody),
                                     secrets: secretsToRedact)
        if !followRedirects, (300...399).contains(response.statusCode) {
            text += "\n\n(redirección no seguida; usa follow_redirects=true para seguirla)"
        }

        var info: [String: Any] = [
            "ok": (200...399).contains(response.statusCode),
            "status": response.statusCode,
            "url": response.url?.absoluteString ?? target,
            "method": verb,
            "body": text,
            "auth": AuthSession.shared.statsDescription(),
        ]
        let interesting = ["content-type", "content-length", "location", "server", "allow", "www-authenticate"]
        var responseHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = (key as? String ?? "").lowercased()
            if interesting.contains(name) { responseHeaders[name] = "\(value)" }
        }
        if !responseHeaders.isEmpty { info["headers"] = responseHeaders }
        let jarCount = Self.jarQueue.sync { Self.cookieJars[connId]?.count ?? 0 }
        if jarCount > 0 { info["cookies"] = jarCount }

        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return Result(ok: (200...399).contains(response.statusCode), message: json, status: response.statusCode)
        }
        return Result(ok: false, message: "No se pudo serializar la respuesta", status: response.statusCode)
    }

    // MARK: - Helpers

    private func join(base: String, path: String) -> String {
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return path
        }
        guard !base.isEmpty else { return path }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = path.hasPrefix("/") ? path : "/" + path
        return trimmedBase + trimmedPath
    }

    private func curlHint(conn: [String: Any], details: [String: String],
                          method: String, path: String?, url: String?) -> String {
        let base = details["url"] ?? ""
        let target = url ?? path.map { join(base: base, path: $0) } ?? base
        let auth = (details["auth"] ?? "none").lowercased()
        var flags = "-X \(method)"
        switch auth {
        case "bearer": flags += " -H 'Authorization: Bearer $GDW_SECRET'"
        case "basic": flags += " -u '\(conn["username"] as? String ?? "usuario"):$GDW_SECRET'"
        case "header": flags += " -H '\(details["header_name"] ?? "Authorization"): $GDW_SECRET'"
        default: break
        }
        return "GDW_SECRET=$(gdw-vault exec \"\(conn["name"] as? String ?? "…")\" -- printenv GDW_SECRET) \\\n  curl \(flags) '\(target)'"
    }

    private static let cookieAttributes: Set<String> = [
        "expires", "path", "domain", "max-age", "secure", "httponly",
        "samesite", "priority", "partitioned", "version", "comment",
    ]

    /// `HTTPURLResponse` une varias cabeceras Set-Cookie con comas; se separan
    /// por nombre de cookie ignorando los atributos (Expires también lleva coma).
    static func parseSetCookie(_ raw: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        var buffer = ""
        for part in raw.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let name = trimmed.split(separator: "=", maxSplits: 1).first
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let startsNewCookie = trimmed.contains("=") && !cookieAttributes.contains(name)
            if buffer.isEmpty {
                buffer = trimmed
            } else if startsNewCookie && !buffer.isEmpty {
                pairs.append(contentsOf: parseCookiePair(buffer))
                buffer = trimmed
            } else {
                buffer += "," + trimmed
            }
        }
        if !buffer.isEmpty { pairs.append(contentsOf: parseCookiePair(buffer)) }
        return pairs
    }

    private static func parseCookiePair(_ raw: String) -> [(String, String)] {
        let pair = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let parts = pair.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, !parts[0].isEmpty else { return [] }
        return [(parts[0], parts[1])]
    }
}

/// Controla si se siguen redirecciones 3xx.
private final class RedirectController: NSObject, URLSessionTaskDelegate {
    private let follow: Bool

    init(follow: Bool) {
        self.follow = follow
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(follow ? request : nil)
    }
}
