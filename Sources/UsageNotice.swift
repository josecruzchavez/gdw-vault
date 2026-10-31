import AppKit

enum UsageNotice {
    private static let version = "2"
    private static let acceptanceKey = "usage_notice_accepted_version"

    private static let title = "Aviso de uso y seguridad"
    private static let text = """
    GDW Vault administra conexiones y permite que clientes MCP, incluidos asistentes de IA, invoquen herramientas locales. Las solicitudes, resultados y datos que una herramienta devuelva pueden llegar al chat y al proveedor del asistente.

    Usa únicamente conexiones y datos para los que tengas autorización. Revisa cada solicitud y resultado; no compartas secretos en chats. Algunas acciones permiten copiar o revelar credenciales y pueden requerir Touch ID. Touch ID confirma una acción local, pero no controla qué hace el cliente MCP con la respuesta ni limita los permisos de un proceso nativo remoto.

    La ejecución nativa por SSH corre con los permisos de la cuenta remota y puede leer o modificar los datos accesibles para ella. Touch ID autentica al usuario, pero no es un sandbox. Los filtros de archivos sensibles solo detectan referencias explícitas y son defensas adicionales; no sustituyen permisos mínimos en los servidores. La app no garantiza que detecte o impida toda exposición, uso no autorizado, pérdida de datos o interrupción. El usuario es responsable de configurar y usar sus accesos de forma segura y conforme a las leyes y acuerdos aplicables.

    Este aviso informa sobre el uso previsto; no es asesoría legal ni garantiza limitar responsabilidades. Consulta asesoría legal para determinar los términos adecuados a tu caso y jurisdicción.
    """

    static var isAccepted: Bool {
        UserDefaults.standard.string(forKey: acceptanceKey) == version
    }

    @discardableResult
    static func requireAcceptance() -> Bool {
        guard !isAccepted else { return true }
        guard present(acceptanceRequired: true) else { return false }
        UserDefaults.standard.set(version, forKey: acceptanceKey)
        return true
    }

    static func presentForReview() {
        _ = present(acceptanceRequired: false)
    }

    private static func present(acceptanceRequired: Bool) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = acceptanceRequired ? .warning : .informational
        if acceptanceRequired {
            alert.addButton(withTitle: "Entiendo y acepto")
            alert.addButton(withTitle: "Salir")
            return alert.runModal() == .alertFirstButtonReturn
        }
        alert.addButton(withTitle: "Cerrar")
        _ = alert.runModal()
        return true
    }
}
