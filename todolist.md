# GDW Vault — TodoList

## Pendientes

- [ ] **Implementar sincronización fiable entre Macs**
  La sincronización por snapshot de iCloud está desactivada temporalmente; el menú
  y los disparadores automáticos fueron retirados para que el uso local no dependa
  de iCloud. Evaluar CloudKit/`CKSyncEngine`, conservar SQLite como almacenamiento
  local, cifrar secretos del lado de la app y definir conflictos, borrados,
  migración desde snapshots anteriores y pruebas con Macs conectadas/desconectadas.

- [ ] **Instalador de un solo comando (`install-online.sh`)**
  Crear un script que permita instalar la app con:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/josecruzchavez/gdw-vault/main/install-online.sh | bash
  ```
  El script debe:
  1. Detectar sistema y arquitectura (`uname -s`, `uname -m` — arm64/x86_64)
  2. Verificar prerrequisitos (Xcode Command Line Tools: `xcode-select -p`, instalar on-demand si falta)
  3. Clonar el repo a un directorio temporal
  4. Compilar con `swiftc Sources/*.swift` (igual que `build.sh`) — compilado local = sin cuarentena de Gatekeeper, no requiere cuenta de Developer ni notarización
  5. Instalar `.app` en `/Applications` + LaunchAgent + symlink `gdw-vault` al PATH
  6. Modo de actualización: `gdw-vault update` (git pull + recompilar + reinstalar)

  Contexto: los instaladores de un comando (Homebrew, rustup, Deno) usan el
  patrón `curl | bash` con detección de OS/arquitectura. Compilar en la
  máquina del usuario evita el bloqueo de Gatekeeper que sufren los .dmg
  sin notarización.

## Completados

- [x] **`run_with_secret` — broker de inyección de secretos** (v1.5.0): el secreto se entrega
  a un CLI local por variable de entorno (`env_var`, default `GDW_SECRET`) o stdin, nunca por
  argumentos ni en la respuesta; se redacta el valor (y su base64 en Basic) de la salida.
  Misma política de modos y Touch ID que `ssh_exec`; llave SSH → inyecta la ruta de la llave.
  CLI equivalente: `gdw-vault exec "Nombre" -- <comando>`.
- [x] **`http_request` — HTTP/API genérico con sesión** (v1.5.0): protocolo `api` (URL +
  `auth_type`: none/basic/bearer/header/query), cookie jar en memoria por conexión,
  redirects opcionales, `DELETE` solo en modo `unsafe`, cuerpo recortado a 20 KB y
  redacción del token. Formulario con «Auth HTTP» y «Header/param».
- [x] Propagación de passwords por snapshot (sync v3) implementada previamente; actualmente desactivada
  y pendiente de reemplazo por una sincronización fiable entre Macs.
- [x] Reglas de seguridad SQL (modos lectura/info/edición/unsafe) — `db_query`
- [x] Reglas de seguridad SSH (mismos modos) — `ssh_exec`
- [x] Soporte PostgreSQL en `db_query`
- [x] Ventana de gracia Touch ID (15 min) + auditoría `auth`
- [x] Icono de barra de menús con logo GDW (template image)
- [x] Icono de app con logo + llaves
- [x] Botón «Copiar comando de conexión» en el menú
- [x] Herramienta MCP `get_connection_command` con sugerencia de portapapeles
- [x] Limpieza de repos obsoletos (gdw-vault-vscode-extension, mcp-touchid-hello, gdw-vault Laravel)
- [x] Smoke test E2E del MCP (`tests/smoke_test.py`, 17 pruebas desatendidas + 4 interactivas con `--interactive`)
- [x] Sincronización anterior mediante snapshot en iCloud Drive e iCloud Keychain; actualmente desactivada mientras se diseña la siguiente implementación.
- [x] Cifrado de secretos en snapshots anteriores (AES-256-GCM); se conserva como antecedente, pero la app ya no importa ni exporta esos snapshots.
