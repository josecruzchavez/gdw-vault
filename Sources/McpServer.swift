import AppKit
import Foundation

/// Servidor MCP por stdio (JSON-RPC delimitado por saltos de línea, estándar de MCP).
/// VS Code lo lanza como: gdw-vault --mcp
final class McpServer {
    private let store = Store.shared

    func run() {
        let input = FileHandle.standardInput
        let source = DispatchSource.makeReadSource(fileDescriptor: input.fileDescriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let chunk = input.availableData
            if chunk.isEmpty {
                source.cancel()
                return
            }
            self.handle(chunk: chunk)
        }
        source.setCancelHandler {
            // EOF en stdin: el cliente cerró la sesión, terminar limpio.
            exit(0)
        }
        source.resume()
        // AppKit exige el hilo principal para NSAlert (la ventana de aviso al
        // entregar un password). dispatchMain() ejecuta los bloques del main
        // queue en un hilo de trabajo, así que usamos el run loop de Cocoa.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var buffer = Data()

    private func handle(chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: Data(lineData), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            respond(to: message)
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func result(_ id: Any, _ value: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": value])
    }

    private func error(_ id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func textContent(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text]]
    }

    private func respond(to message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let id = message["id"] ?? NSNull()
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            result(id, [
                "protocolVersion": params["protocolVersion"] ?? "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": [
                    "name": "gdw-vault-native",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
                ],
            ])
        case "notifications/initialized":
            break
        case "ping":
            result(id, [:])
        case "tools/list":
            result(id, ["tools": toolsManifest()])
        case "tools/call":
            handleCall(id: id, params: params)
        default:
            if !(id is NSNull) {
                error(id, code: -32601, message: "Método no soportado: \(method)")
            }
        }
    }

    private func toolsManifest() -> [[String: Any]] {
        [
            [
                "name": "list_groups",
                "description": "Lista los grupos (carpetas) guardados en el vault local.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "list_connections",
                "description": "Lista conexiones sin revelar secretos. Filtra por group_name o protocol.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "group_name": ["type": "string"],
                        "protocol": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "get_connection",
                "description": "Detalles de una conexión (host, usuario, puerto) sin el secreto. Busca por id o name.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "name": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "get_connection_password",
                "description": "Devuelve el secreto en la respuesta MCP, que puede llegar al chat/modelo. Pide Touch ID local antes de entregarlo.",
                "inputSchema": [
                    "type": "object",
                    "required": ["name"],
                    "properties": ["name": ["type": "string"]],
                ],
            ],
            [
                "name": "create_connection",
                "description": "Crea una conexión en el vault. Campos extra según protocolo: mysql/postgres aceptan 'database' (opcional, se puede pedir después); website acepta 'url'.",
                "inputSchema": [
                    "type": "object",
                    "required": ["group_name", "name", "protocol"],
                    "properties": [
                        "group_name": ["type": "string"],
                        "name": ["type": "string"],
                        "protocol": ["type": "string", "enum": ConnectionForm.protocols],
                        "host": ["type": "string"],
                        "port": ["type": "integer"],
                        "username": ["type": "string"],
                        "password": ["type": "string"],
                        "database": ["type": "string"],
                        "url": ["type": "string"],
                        "auth": ["type": "string", "enum": ["password", "key"]],
                        "key_name": ["type": "string"],
                        "auth_type": ["type": "string", "enum": ConnectionForm.httpAuthMethods, "description": "Solo website/api: none, basic, bearer, header o query"],
                        "header_name": ["type": "string", "description": "Solo website/api con auth_type=header: nombre de la cabecera"],
                        "query_param": ["type": "string", "description": "Solo website/api con auth_type=query: nombre del parámetro"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "update_connection",
                "description": "Actualiza una conexión existente (por id o name). Los campos omitidos se conservan; password vacío/omitido conserva el secreto actual. auth=key requiere key_name registrada.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "name": ["type": "string"],
                        "new_name": ["type": "string"],
                        "group_name": ["type": "string"],
                        "protocol": ["type": "string", "enum": ConnectionForm.protocols],
                        "host": ["type": "string"],
                        "port": ["type": "integer"],
                        "username": ["type": "string"],
                        "password": ["type": "string"],
                        "database": ["type": "string"],
                        "url": ["type": "string"],
                        "auth": ["type": "string", "enum": ["password", "key"]],
                        "key_name": ["type": "string"],
                        "auth_type": ["type": "string", "enum": ConnectionForm.httpAuthMethods, "description": "Solo website/api: none, basic, bearer, header o query"],
                        "header_name": ["type": "string", "description": "Solo website/api con auth_type=header: nombre de la cabecera"],
                        "query_param": ["type": "string", "description": "Solo website/api con auth_type=query: nombre del parámetro"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "delete_connection",
                "description": "Elimina una conexión (por id o name) y su secreto del Keychain. Pide Touch ID local antes de borrar.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "name": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "list_keys",
                "description": "Lista las llaves de acceso SSH guardadas (nombre y rutas de los archivos, sin contenido).",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "db_query",
                "description": "Ejecuta SQL en una base de datos MySQL o PostgreSQL del vault. Solo requiere 'db_name' (coincidencia parcial, p.ej. 'cymisa'): si el host es local abre túnel SSH por una conexión ssh/sftp del mismo grupo; sin ssh en el grupo conecta directo. POLÍTICA POR CONEXIÓN (campo 'Modo SQL'): lectura (default) solo SELECT/SHOW; info bloquea escritura y muestra el comando de consola; edicion permite INSERT/UPDATE con confirm=true pero bloquea DELETE/DROP/TRUNCATE/ALTER; unsafe permite todo con confirm=true. TOUCH ID: lectura = ventana de gracia de 15 min; cualquier escritura = SIEMPRE Touch ID fresco. Opcional: 'ssh_name' para forzar el puente, 'database' para el esquema.",
                "inputSchema": [
                    "type": "object",
                    "required": ["db_name", "sql"],
                    "properties": [
                        "db_name": ["type": "string", "description": "Nombre de la conexión mysql destino (coincidencia parcial aceptada)"],
                        "sql": ["type": "string", "description": "Sentencias SQL separadas por ';'"],
                        "ssh_name": ["type": "string", "description": "Opcional: conexión ssh/sftp para el túnel; si se omite se elige del mismo grupo"],
                        "database": ["type": "string", "description": "Esquema; si se omite usa el 'database' de la conexión mysql"],
                        "confirm": ["type": "boolean", "description": "Solo modo unsafe: confirma explícitamente ejecutar SQL destructivo (además pide Touch ID)"],
                    ],
                ],
            ],
            [
                "name": "ssh_exec",
                "description": "Ejecuta por SSH comandos de una allowlist acotada de lectura o cambios conocidos. Programas no reconocidos e intérpretes se consideran ejecución nativa y requieren modo unsafe + Touch ID fresco; el motivo de Touch ID informa que el proceso conserva los permisos de la cuenta SSH. No es un sandbox. Los nombres de archivos sensibles solo detectan referencias explícitas. Opcional: timeout (5-300, default 60).",
                "inputSchema": [
                    "type": "object",
                    "required": ["ssh_name", "command"],
                    "properties": [
                        "ssh_name": ["type": "string", "description": "Nombre de la conexión ssh/sftp (coincidencia parcial aceptada)"],
                        "command": ["type": "string", "description": "Comando a ejecutar en el servidor remoto"],
                        "confirm": ["type": "boolean", "description": "Confirma cambios y lecturas explícitas de archivos sensibles; no se requiere para ejecución nativa en modo unsafe"],
                        "timeout": ["type": "integer", "description": "Segundos de espera máximo (5-300, default 60)"],
                    ],
                ],
            ],
            [
                "name": "ssh_native_exec",
                "description": "Ejecuta explícitamente código nativo/remoto (frameworks, intérpretes, scripts o comandos compuestos) con los permisos de la cuenta SSH. Solo funciona en modo unsafe y requiere Touch ID fresco; el motivo de Touch ID indica que el proceso tendrá los permisos de la cuenta. GDW Vault no puede aislar ni predecir lo que hará el proceso.",
                "inputSchema": [
                    "type": "object",
                    "required": ["ssh_name", "command"],
                    "properties": [
                        "ssh_name": ["type": "string", "description": "Nombre de conexión SSH/SFTP"],
                        "command": ["type": "string", "description": "Comando nativo completo que se autorizará y ejecutará"],
                        "timeout": ["type": "integer", "description": "Segundos de espera máximo (5-300, default 60)"],
                    ],
                ],
            ],
            [
                "name": "get_connection_command",
                "description": "Devuelve el comando de terminal para conectarse (ssh/mysql/psql/ftp/url) según el protocolo de la conexión (coincidencia parcial en el nombre). Para autenticación por llave SSH, incluye -i con la ruta registrada, nunca el contenido de la llave. Por defecto no incluye passwords. 'copy_password'=true copia al portapapeles con Touch ID (solo conexiones con password). 'include_password'=true muestra un aviso con opciones de copiar, proceder o cancelar; solo al proceder lo incrusta en el comando devuelto para mysql/postgres. El password podría llegar al chat/modelo.",
                "inputSchema": [
                    "type": "object",
                    "required": ["name"],
                    "properties": [
                        "name": ["type": "string", "description": "Nombre de la conexión (coincidencia parcial aceptada)"],
                        "copy_password": ["type": "boolean", "description": "Copia el password al portapapeles con Touch ID; solo aplica a conexiones con password"],
                         "include_password": ["type": "boolean", "description": "Solicita generar el comando con password (solo mysql/postgres); la app muestra un aviso para copiarlo, proceder y enviarlo en la respuesta MCP, o cancelar"],
                    ],
                ],
            ],
            [
                "name": "run_with_secret",
                "description": "Ejecuta un comando local entregando el secreto por variable de entorno o stdin. Comandos nativos/desconocidos requieren modo unsafe y Touch ID fresco. El proceso local no está aislado por Vault. La salida MCP solo devuelve el código de salida.",
                "inputSchema": [
                    "type": "object",
                    "required": ["name", "command"],
                    "properties": [
                        "name": ["type": "string", "description": "Conexión cuyo secreto se inyecta (coincidencia parcial aceptada)"],
                        "command": ["type": "string", "description": "Comando local; el secreto NO se interpola aquí"],
                        "env_var": ["type": "string", "description": "Nombre de la variable de entorno (default GDW_SECRET)"],
                        "stdin": ["type": "boolean", "description": "Inyectar el secreto por stdin en vez de variable de entorno"],
                        "confirm": ["type": "boolean", "description": "Confirma comandos de escritura o cada acceso a un archivo sensible previamente habilitado; Touch ID se reutiliza por 15 min para lecturas sensibles de esa conexión, las escrituras siempre piden Touch ID fresco"],
                        "timeout": ["type": "integer", "description": "Segundos de espera máximo (5-300, default 60)"],
                    ],
                ],
            ],
            [
                "name": "http_request",
                "description": "Petición HTTP con sesión (cookie jar en memoria) usando una conexión website/api del vault. La URL base y la autenticación salen de la conexión. Las URL absolutas deben conservar el origen configurado; peticiones con credenciales requieren HTTPS y las redirecciones a otros orígenes se bloquean. La URL y la cabecera Location devueltas omiten query, fragmento y userinfo para no exponer tokens. POLÍTICA POR CONEXIÓN (campo 'Modo'): lectura solo GET/HEAD/OPTIONS; info bloquea escritura y muestra el curl equivalente; edicion permite POST/PUT/PATCH con confirm=true; unsafe permite todo con confirm=true; DELETE solo en unsafe. TOUCH ID: lectura con ventana de gracia; escritura siempre fresco. Devuelve status, cabeceras relevantes y cuerpo (recortado a 20k).",
                "inputSchema": [
                    "type": "object",
                    "required": ["name"],
                    "properties": [
                        "name": ["type": "string", "description": "Conexión website/api (coincidencia parcial aceptada)"],
                        "method": ["type": "string", "description": "GET, HEAD, OPTIONS, POST, PUT, PATCH o DELETE (default GET)"],
                        "path": ["type": "string", "description": "Ruta relativa a la URL de la conexión (p.ej. /api/v1/items)"],
                        "url": ["type": "string", "description": "URL absoluta del mismo origen configurado; reemplaza a 'path'"],
                        "headers": ["type": "object", "description": "Cabeceras adicionales (objeto nombre→valor)"],
                        "body": ["type": "string", "description": "Cuerpo como texto"],
                        "body_json": ["type": "object", "description": "Cuerpo JSON (tiene prioridad sobre 'body')"],
                        "query": ["type": "object", "description": "Parámetros de query (objeto nombre→valor)"],
                        "follow_redirects": ["type": "boolean", "description": "Seguir redirecciones 3xx (default true)"],
                        "clear_cookies": ["type": "boolean", "description": "Vaciar el cookie jar de esta conexión antes de la petición"],
                        "confirm": ["type": "boolean", "description": "Solo modos edicion/unsafe: confirma la petición de escritura (además pide Touch ID fresco)"],
                        "timeout": ["type": "integer", "description": "Segundos de espera máximo (5-120, default 30)"],
                    ],
                ],
            ],
        ]
    }

    private func handleCall(id: Any, params: [String: Any]) {
        guard let name = params["name"] as? String else {
            error(id, code: -32602, message: "Falta 'name' en tools/call")
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "list_groups":
            let groups = store.listGroups().map { $0["name"] as? String ?? "" }
            result(id, ["content": textContent(jsonString(["groups": groups]))])

        case "list_keys":
            let keys = store.listKeys().map { row -> [String: Any] in
                var info: [String: Any] = ["id": row["id"] as? Int ?? 0, "name": row["name"] as? String ?? ""]
                if let pub = row["pub_path"] as? String { info["pub_path"] = pub }
                if let secret = row["secret_path"] as? String { info["secret_path"] = secret }
                if let notes = row["notes"] as? String { info["notes"] = notes }
                return info
            }
            result(id, ["content": textContent(jsonString(["keys": keys]))])

        case "list_connections":
            let all = store.listConnections()
            let groupFilter = args["group_name"] as? String
            let protoFilter = args["protocol"] as? String
            let filtered = all.filter { row in
                (groupFilter == nil || (row["group_name"] as? String)?.caseInsensitiveCompare(groupFilter!) == .orderedSame)
                && (protoFilter == nil || (row["protocol"] as? String)?.caseInsensitiveCompare(protoFilter!) == .orderedSame)
            }
            result(id, ["content": textContent(jsonString(["connections": filtered]))])

        case "get_connection":
            guard let conn = lookup(args: args) else {
                result(id, ["content": textContent(jsonString(["ok": false, "error": "Conexión no encontrada"]))])
                return
            }
            var info = conn
            info.removeValue(forKey: "keychain_account")
            result(id, ["content": textContent(jsonString(info))])

        case "get_connection_password":
            guard let conn = lookup(args: args) else {
                result(id, ["content": textContent(jsonString(["ok": false, "error": "Conexión no encontrada"]))])
                return
            }
            let connName = conn["name"] as? String ?? "?"
            let group = conn["group_name"] as? String ?? ""
            let granted = TouchId.authorizeSync(
                reason: "GDW Vault: entregar el secreto de \"\(connName)\" (\(group)) a VS Code."
            )
            guard granted else {
                result(id, ["content": textContent(jsonString(["ok": false, "error": "Touch ID rechazado"]))])
                return
            }
            guard let secret = store.secretFor(connection: conn) else {
                result(id, ["content": textContent(jsonString(["ok": false, "error": "No hay secreto guardado"]))])
                return
            }
            AuthSession.shared.markSecretUsed(account: conn["keychain_account"] as? String ?? "")
            switch promptPasswordDelivery(name: connName) {
            case .cancel:
                result(id, ["content": textContent(jsonString(["ok": false, "error": "Entrega cancelada por el usuario"]))])
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(secret, forType: .string)
                result(id, ["content": textContent(jsonString([
                    "ok": true, "name": connName, "copied": true,
                    "note": "Password copiado al portapapeles (no mostrado). Se borrará cuando copies otra cosa.",
                ]))])
            case .reveal:
                result(id, ["content": textContent(jsonString(["ok": true, "name": connName, "secret": secret]))])
            }

        case "create_connection":
            createConnection(id: id, args: args)

        case "update_connection":
            updateConnection(id: id, args: args)

        case "delete_connection":
            deleteConnection(id: id, args: args)

        case "db_query":
            dbQuery(id: id, args: args)

        case "ssh_exec":
            sshExec(id: id, args: args, nativeExecution: false)

        case "ssh_native_exec":
            sshExec(id: id, args: args, nativeExecution: true)

        case "run_with_secret":
            runWithSecret(id: id, args: args)

        case "http_request":
            httpRequest(id: id, args: args)

        case "get_connection_command":
            connectionCommand(id: id, args: args)

        default:
            result(id, ["content": textContent(jsonString(["ok": false, "error": "Tool desconocida: \(name)"]))])
        }
    }

    private func lookup(args: [String: Any]) -> [String: Any]? {
        if let id = args["id"] as? Int {
            return store.findConnection(id: id)
        }
        if let name = argString(args, "name") {
            // Misma resolución flexible que db_query/ssh_exec: exacta,
            // parcial y difusa (typos). Ambigua → nil (error claro).
            let resolve = DbTunnel().resolveConnection(
                name: name, protocols: Set(ConnectionForm.protocols))
            if case .found(let conn) = resolve { return conn }
            return nil
        }
        return nil
    }

    /// Decisión del usuario sobre cómo entregar un password pedido por un
    /// cliente (p. ej. el chat). Si se muestra en el chat queda comprometido
    /// (historial, logs y contexto del modelo), por eso lo recomendado es
    /// copiarlo al portapapeles.
    private enum PasswordDelivery {
        case copy
        case reveal
        case cancel
    }

    private func promptPasswordDelivery(
        name: String,
        context: String = "Un cliente (p. ej. el chat) ha pedido este password."
    ) -> PasswordDelivery {
        // El handler del source corre en el hilo principal (queue: .main),
        // así que NSAlert puede instanciarse aquí directamente.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Password solicitado — \(name)"
        alert.informativeText = """
        \(context)

        ⚠️ Si se muestra en el chat queda comprometido: queda en el historial, \
        los logs y el contexto del modelo.

        Recomendado: copiarlo al portapapeles (se borra al copiar otra cosa).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copiar al portapapeles")
        alert.addButton(withTitle: "Proceder (mostrar en el chat)")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .copy
        case .alertSecondButtonReturn: return .reveal
        default: return .cancel
        }
    }

    // MARK: - Tools de escritura (CRUD)

    private func fail(_ id: Any, _ message: String) {
        result(id, ["content": textContent(jsonString(["ok": false, "error": message]))])
    }

    private func argString(_ args: [String: Any], _ key: String) -> String? {
        guard let raw = args[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Acepta {nombre: valor} con valores de cualquier tipo JSON y los
    /// normaliza a String (cabeceras y query params).
    private func argStringDict(_ args: [String: Any], _ key: String) -> [String: String]? {
        guard let raw = args[key] as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (name, value) in raw {
            if let string = value as? String {
                result[name] = string
            } else if let number = value as? NSNumber {
                result[name] = number.stringValue
            } else {
                result[name] = "\(value)"
            }
        }
        return result.isEmpty ? nil : result
    }

    private func argPort(_ args: [String: Any]) -> Int? {
        if let port = args["port"] as? Int { return port }
        if let port = (args["port"] as? String).flatMap(Int.init) { return port }
        return nil
    }

    /// Campos específicos por protocolo: database (mysql/postgres) y URL +
    /// autenticación HTTP (website/api).
    private func detailsFor(proto: String, args: [String: Any]) -> [String: String]? {
        var details: [String: String] = [:]
        if ConnectionForm.dbProtocols.contains(proto), let database = argString(args, "database") {
            details["database"] = database
        }
        if ConnectionForm.httpProtocols.contains(proto) {
            if let url = argString(args, "url") { details["url"] = url }
            if let auth = argString(args, "auth_type") { details["auth"] = auth }
            if let header = argString(args, "header_name") { details["header_name"] = header }
            if let param = argString(args, "query_param") { details["query_param"] = param }
        }
        return details.isEmpty ? nil : details
    }

    private func validateHTTPAuth(_ args: [String: Any]) -> String? {
        guard let auth = argString(args, "auth_type") else { return nil }
        guard ConnectionForm.httpAuthMethods.contains(auth) else {
            return "auth_type debe ser uno de: \(ConnectionForm.httpAuthMethods.joined(separator: ", "))"
        }
        return nil
    }

    private func validate(proto: String, database: String?) -> String? {
        guard ConnectionForm.protocols.contains(proto) else {
            return "Protocolo no soportado: \(proto). Válidos: \(ConnectionForm.protocols.joined(separator: ", "))"
        }
        return nil
    }

    private func createConnection(id: Any, args: [String: Any]) {
        guard let groupName = argString(args, "group_name"),
              let name = argString(args, "name"),
              let proto = argString(args, "protocol") else {
            fail(id, "Se requieren 'group_name', 'name' y 'protocol'")
            return
        }
        if let message = validate(proto: proto, database: argString(args, "database")) {
            fail(id, message)
            return
        }
        if let message = validateHTTPAuth(args) {
            fail(id, message)
            return
        }
        var details = detailsFor(proto: proto, args: args) ?? [:]
        var keyId: Int?
        if ConnectionForm.keyProtocols.contains(proto) {
            let auth = argString(args, "auth") ?? "password"
            guard ConnectionForm.authMethods.contains(auth) else {
                fail(id, "auth debe ser 'password' o 'key'")
                return
            }
            details["auth"] = auth
            if auth == "key" {
                guard let keyName = argString(args, "key_name"),
                      let key = store.listKeys().first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(keyName) == .orderedSame }),
                      let foundId = key["id"] as? Int else {
                    fail(id, "auth=key requiere 'key_name' de una llave registrada (usa list_keys)")
                    return
                }
                keyId = foundId
            }
        }
        let connectionId = store.upsertConnection(
            groupId: store.upsertGroup(groupName), name: name,
            host: argString(args, "host"), port: argPort(args),
            protocolType: proto, username: argString(args, "username"),
            secret: argString(args, "password"), notes: argString(args, "notes"),
            details: details.isEmpty ? nil : details, keyId: keyId)
        guard connectionId > 0 else {
            fail(id, "No se pudo crear la conexión (¿nombre duplicado en el grupo?)")
            return
        }
        result(id, ["content": textContent(jsonString(["ok": true, "id": connectionId, "name": name]))])
    }

    private func updateConnection(id: Any, args: [String: Any]) {
        guard let conn = lookup(args: args) else {
            fail(id, "Conexión no encontrada")
            return
        }
        guard let connectionId = conn["id"] as? Int else {
            fail(id, "Conexión inválida")
            return
        }
        let proto = argString(args, "protocol") ?? (conn["protocol"] as? String ?? "sftp")
        // Campos omitidos: conservar los actuales.
        let details = store.detailsDict(from: conn)
        if let message = validate(proto: proto, database: argString(args, "database") ?? details["database"]) {
            fail(id, message)
            return
        }
        if let message = validateHTTPAuth(args) {
            fail(id, message)
            return
        }
        // Reconstruir details según el protocolo final (limpia campos obsoletos si cambió).
        var newDetails: [String: String] = [:]
        if ConnectionForm.dbProtocols.contains(proto),
           let database = argString(args, "database") ?? details["database"] {
            newDetails["database"] = database
        }
        if ConnectionForm.httpProtocols.contains(proto) {
            if let url = argString(args, "url") ?? details["url"] { newDetails["url"] = url }
            if let auth = argString(args, "auth_type") ?? details["auth"] { newDetails["auth"] = auth }
            if let header = argString(args, "header_name") ?? details["header_name"] { newDetails["header_name"] = header }
            if let param = argString(args, "query_param") ?? details["query_param"] { newDetails["query_param"] = param }
        }
        var keyId: Int?
        if ConnectionForm.keyProtocols.contains(proto) {
            let auth = argString(args, "auth") ?? details["auth"] ?? "password"
            guard ConnectionForm.authMethods.contains(auth) else {
                fail(id, "auth debe ser 'password' o 'key'")
                return
            }
            newDetails["auth"] = auth
            if auth == "key" {
                if let keyName = argString(args, "key_name") {
                    guard let key = store.listKeys().first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(keyName) == .orderedSame }),
                          let foundId = key["id"] as? Int else {
                        fail(id, "No existe una llave registrada con el nombre '\(keyName)' (usa list_keys)")
                        return
                    }
                    keyId = foundId
                } else if let existingKeyId = conn["key_id"] as? Int {
                    keyId = existingKeyId
                } else {
                    fail(id, "auth=key requiere 'key_name' de una llave registrada (usa list_keys)")
                    return
                }
            }
        }
        let groupId = argString(args, "group_name").map { store.upsertGroup($0) }
            ?? (conn["group_id"] as? Int ?? 0)
        let name = argString(args, "new_name") ?? (conn["name"] as? String ?? "")
        let ok = store.updateConnection(
            id: connectionId, groupId: groupId, name: name,
            host: argString(args, "host") ?? (conn["host"] as? String),
            port: argPort(args) ?? (conn["port"] as? Int),
            protocolType: proto,
            username: argString(args, "username") ?? (conn["username"] as? String),
            secret: argString(args, "password"),
            notes: argString(args, "notes") ?? (conn["notes"] as? String),
            details: newDetails.isEmpty ? nil : newDetails, keyId: keyId)
        guard ok else {
            fail(id, "No se pudo actualizar la conexión (¿nombre duplicado en el grupo?)")
            return
        }
        result(id, ["content": textContent(jsonString(["ok": true, "id": connectionId, "name": name]))])
    }

    private func deleteConnection(id: Any, args: [String: Any]) {
        guard let conn = lookup(args: args) else {
            fail(id, "Conexión no encontrada")
            return
        }
        guard let connectionId = conn["id"] as? Int else {
            fail(id, "Conexión inválida")
            return
        }
        let connName = conn["name"] as? String ?? "?"
        let group = conn["group_name"] as? String ?? ""
        let granted = TouchId.authorizeSync(
            reason: "GDW Vault: eliminar la conexión \"\(connName)\" (\(group)) y su secreto del Keychain."
        )
        guard granted else {
            fail(id, "Touch ID rechazado")
            return
        }
        guard store.deleteConnection(id: connectionId) else {
            fail(id, "No se pudo eliminar la conexión")
            return
        }
        result(id, ["content": textContent(jsonString(["ok": true, "id": connectionId, "deleted": connName]))])
    }

    private func dbQuery(id: Any, args: [String: Any]) {
        guard let dbName = argString(args, "db_name"),
              let sql = argString(args, "sql") else {
            fail(id, "Se requieren 'db_name' y 'sql'")
            return
        }
        let tunnel = DbTunnel()
        let outcome = tunnel.query(
            sshName: argString(args, "ssh_name"), dbName: dbName, sql: sql,
            database: argString(args, "database"),
            confirm: args["confirm"] as? Bool ?? false)
        result(id, ["content": textContent(jsonString([
            "ok": outcome.ok,
            "output": outcome.message,
            "auth": AuthSession.shared.statsDescription(),
        ]))])
    }

    private func sshExec(id: Any, args: [String: Any], nativeExecution: Bool) {
        guard let sshName = argString(args, "ssh_name"),
              let command = argString(args, "command") else {
            fail(id, "Se requieren 'ssh_name' y 'command'")
            return
        }
        let timeout = (args["timeout"] as? Int) ?? 60
        let outcome = SshRunner().exec(
            sshName: sshName, command: command,
            confirm: args["confirm"] as? Bool ?? false,
            timeout: timeout,
            nativeExecution: nativeExecution)
        result(id, ["content": textContent(jsonString([
            "ok": outcome.ok,
            "output": outcome.message,
            "auth": AuthSession.shared.statsDescription(),
        ]))])
    }

    private func runWithSecret(id: Any, args: [String: Any]) {
        guard let name = argString(args, "name"),
              let command = argString(args, "command") else {
            fail(id, "Se requieren 'name' y 'command'")
            return
        }
        let outcome = SecretBroker().run(
            connectionName: name, command: command,
            envVar: argString(args, "env_var"),
            viaStdin: args["stdin"] as? Bool ?? false,
            confirm: args["confirm"] as? Bool ?? false,
            timeout: (args["timeout"] as? Int) ?? SecretBroker.defaultTimeout)
        result(id, ["content": textContent(jsonString([
            "ok": outcome.ok,
            "output": outcome.message,
            "auth": AuthSession.shared.statsDescription(),
        ]))])
    }

    private func httpRequest(id: Any, args: [String: Any]) {
        guard let name = argString(args, "name") else {
            fail(id, "Se requiere 'name'")
            return
        }
        let method = argString(args, "method") ?? "GET"
        let outcome = HttpClient().request(
            connectionName: name,
            method: method,
            path: argString(args, "path"),
            url: argString(args, "url"),
            headers: argStringDict(args, "headers"),
            body: argString(args, "body"),
            bodyJSON: args["body_json"],
            query: argStringDict(args, "query"),
            followRedirects: args["follow_redirects"] as? Bool ?? true,
            clearCookies: args["clear_cookies"] as? Bool ?? false,
            confirm: args["confirm"] as? Bool ?? false,
            timeout: (args["timeout"] as? Int) ?? HttpClient.defaultTimeout)
        // Éxito: la respuesta ya es un objeto JSON. Errores de política/red
        // llegan como texto: se normalizan para que el cliente parsee igual.
        if outcome.message.hasPrefix("{"), outcome.message.hasSuffix("}") {
            result(id, ["content": textContent(outcome.message)])
            return
        }
        var payload: [String: Any] = [
            "ok": false,
            "output": outcome.message,
            "error": outcome.message,
            "auth": AuthSession.shared.statsDescription(),
        ]
        if let status = outcome.status { payload["status"] = status }
        result(id, ["content": textContent(jsonString(payload))])
    }

    private func connectionCommand(id: Any, args: [String: Any]) {
        guard let name = argString(args, "name") else {
            fail(id, "Se requiere 'name'")
            return
        }
        let allProtocols = Set(ConnectionForm.protocols)
        let resolve = DbTunnel().resolveConnection(name: name, protocols: allProtocols)
        guard case .found(let conn) = resolve else {
            switch resolve {
            case .notFound(let tried):
                fail(id, "No existe una conexión llamada '\(name)'. \(tried)")
            case .ambiguous(let candidates):
                fail(id, "Varias conexiones coinciden con '\(name)': \(candidates). Sé más específico.")
            default:
                fail(id, "Conexión no encontrada")
            }
            return
        }
        let connName = conn["name"] as? String ?? name
        let usesKeyAuth = store.detailsDict(from: conn)["auth"] == "key"
        let wantsInline = args["include_password"] as? Bool ?? false
        let wantsClipboard = args["copy_password"] as? Bool ?? false

        var command = ConnectionCommandBuilder.build(conn)
        var sugerencia = usesKeyAuth
            ? "El comando usa la ruta de la llave privada configurada; no expone el contenido de la llave."
            : "Por seguridad el password no va en el comando (quedaría en el historial de la terminal). Opciones: 'copy_password'=true lo copia al portapapeles con Touch ID; conéctate y pégalo cuando la terminal lo pida."
        var ok = command != nil

        if command == nil {
            sugerencia = usesKeyAuth
                ? "No se encontró una ruta de llave privada válida en la llave registrada. Revisa «Llaves de acceso…»."
                : "No hay un comando disponible para este protocolo."
        }

        if wantsInline || wantsClipboard {
            if usesKeyAuth {
                fail(id, "La conexión usa una llave SSH, no un password. El comando ya incluye la ruta de la llave.")
                return
            }
            let granted = AuthSession.shared.forceAuthorize(
                reason: "GDW Vault: entregar el password de \"\(connName)\" para el comando de conexión."
            )
            guard granted, let secret = store.secretFor(connection: conn), !secret.isEmpty else {
                fail(id, wantsInline || wantsClipboard ? "Touch ID rechazado o sin password guardado" : "Error")
                return
            }
            if wantsInline {
                guard let withPass = ConnectionCommandBuilder.build(conn, password: secret) else {
                    ok = false
                    sugerencia = "Este protocolo no acepta password en el comando (ssh/ftp). Usa 'copy_password'=true para copiarlo al portapapeles y pégalo cuando la terminal lo pida."
                    result(id, ["content": textContent(jsonString([
                        "ok": ok,
                        "command": command ?? "(sin comando para este protocolo)",
                        "sugerencia": sugerencia,
                        "auth": AuthSession.shared.statsDescription(),
                    ]))])
                    return
                }
                switch promptPasswordDelivery(
                    name: connName,
                    context: "El asistente pidió generar un comando con este password incluido."
                ) {
                case .cancel:
                    fail(id, "Generación del comando con password cancelada por el usuario")
                    return
                case .copy:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret, forType: .string)
                    sugerencia = "📋 Password copiado al portapapeles; el comando devuelto no lo incluye. Pégalo cuando la terminal lo solicite. Se borrará cuando copies otra cosa."
                case .reveal:
                    command = withPass
                    sugerencia = "⚠️ El comando incluye el password en la respuesta MCP: puede quedar en el historial del chat y de la terminal."
                }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(secret, forType: .string)
                sugerencia = "📋 Password copiado al portapapeles — pégalo cuando la terminal lo pida. Se borrará cuando copies otra cosa."
            }
        }

        result(id, ["content": textContent(jsonString([
            "ok": ok,
            "command": command ?? "(sin comando para este protocolo)",
            "sugerencia": sugerencia,
            "auth": AuthSession.shared.statsDescription(),
        ]))])
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
