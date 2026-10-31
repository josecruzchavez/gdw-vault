import AppKit
import Darwin
import Foundation

private let databaseServiceName = "mx.gdw.vault.db.\(getuid())"

@objc protocol DatabaseServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

final class DatabaseService: NSObject, NSXPCListenerDelegate, DatabaseServiceProtocol {
    private var listener: NSXPCListener?

    func start() {
        let listener = NSXPCListener(machServiceName: databaseServiceName)
        listener.delegate = self
        self.listener = listener
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DatabaseServiceProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func perform(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let operation = object["operation"] as? String,
                  let sql = object["sql"] as? String else {
                throw DatabaseIPCError.invalidRequest
            }
            let params = object["params"] as? [Any] ?? []
            let store = Store.shared
            let value: Any
            switch operation {
            case "query":
                value = store.query(sql, params)
            case "run":
                value = store.run(sql, params)
            case "exec":
                store.exec(sql)
                value = true
            case "transaction":
                guard let rawStatements = object["statements"] as? [[String: Any]] else {
                    throw DatabaseIPCError.invalidRequest
                }
                let statements = try rawStatements.map { statement -> DatabaseStatement in
                    guard let sql = statement["sql"] as? String else {
                        throw DatabaseIPCError.invalidRequest
                    }
                    return DatabaseStatement(sql: sql, params: statement["params"] as? [Any] ?? [])
                }
                value = store.performTransactionLocally(statements)
            default:
                throw DatabaseIPCError.unsupportedOperation(operation)
            }
            reply(try JSONSerialization.data(withJSONObject: ["value": value], options: [.fragmentsAllowed]), nil)
        } catch {
            NSLog("GDW Vault database service error: %@", error.localizedDescription)
            let response = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
            reply(response, error.localizedDescription)
        }
    }
}

final class DatabaseIPCClient {
    static let shared = DatabaseIPCClient()

    private init() {}

    func perform(operation: String, sql: String = "", params: [Any] = [],
                 statements: [DatabaseStatement]? = nil) -> Any? {
        do {
            var payload: [String: Any] = [
                "operation": operation,
                "sql": sql,
                "params": params
            ]
            if let statements {
                payload["statements"] = statements.map { ["sql": $0.sql, "params": $0.params] }
            }
            let request = try JSONSerialization.data(withJSONObject: payload)
            let connection = NSXPCConnection(machServiceName: databaseServiceName, options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: DatabaseServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            let semaphore = DispatchSemaphore(value: 0)
            var responseData: Data?
            var responseError: String?
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                responseError = error.localizedDescription
                semaphore.signal()
            } as? DatabaseServiceProtocol
            guard let proxy else {
                NSLog("GDW Vault database IPC error: no se pudo crear el proxy XPC")
                return nil
            }
            proxy.perform(request) { data, error in
                responseData = data
                responseError = error
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                NSLog("GDW Vault database IPC error: tiempo de espera agotado")
                return nil
            }
            if let responseError {
                NSLog("GDW Vault database IPC error: %@", responseError)
                return nil
            }
            guard let responseData,
                  let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                NSLog("GDW Vault database IPC error: respuesta inválida")
                return nil
            }
            if let error = response["error"] as? String {
                NSLog("GDW Vault database IPC error: %@", error)
                return nil
            }
            return response["value"]
        } catch {
            NSLog("GDW Vault database IPC error: %@", error.localizedDescription)
            return nil
        }
    }
}

private enum DatabaseIPCError: LocalizedError {
    case invalidRequest
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Solicitud de base de datos inválida"
        case .unsupportedOperation(let operation):
            return "Operación de base de datos no admitida: \(operation)"
        }
    }
}
