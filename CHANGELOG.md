# Historial de cambios

## 1.5.0 — 2026-10-19

- **`run_with_secret`**: entrega el secreto de una conexión a un CLI local por
  variable de entorno o stdin, sin exponerlo al chat (redacta el valor y su
  forma base64 en la salida). Misma política de modos y Touch ID que
  `ssh_exec`. Llave SSH → inyecta la ruta de la llave privada.
- **CLI `gdw-vault exec "Nombre" -- <comando>`**: el mismo broker para el
  operador humano (es el comando que sugiere el modo `info`/`lectura`).
- **`http_request`**: cliente HTTP genérico con cookie jar en memoria para
  conexiones `website` y `api`: `basic`, `bearer`, `header` y `query`, redirects
  opcionales, `DELETE` restringido a modo `unsafe`, cuerpo recortado a 20 KB.
- Nuevo protocolo **`api`** (URL + `auth_type`) y campos «Auth HTTP» /
  «Header/param» en el formulario; los modos ahora también gobiernan HTTP.
- `create_connection`/`update_connection` aceptan `auth_type`, `header_name` y
  `query_param`.

## 1.4.4 — 2026-10-06

- Formulario: Protocolo ahora va antes que Nombre (Grupo → Protocolo → Nombre
  → campos del tipo → Host/Puerto/Usuario/Password → Autenticación/Llave → Notas).

## 1.4.3 — 2026-10-06

- Formulario de conexión reordenado: Grupo, Nombre, Protocolo y después los
  campos específicos del tipo (URL para website/admin, Base de datos para
  mysql/postgres), seguidos de Host, Puerto, Usuario, Password,
  Autenticación/Llave (ssh/sftp) y Notas.

## 1.4.2 — 2026-10-06

- Corregido segundo crash (SIGSEGV en `ConnectionManager.show()`): abrir
  ventanas dentro del callstack de cierre del menú de la barra de estado
  corrompía el estado de animación de AppKit. La apertura de las ventanas de
  administración se difirió al siguiente ciclo del run loop
  (`DispatchQueue.main.async`).
- El botón «Cerrar» de ambas ventanas usa `orderOut` (sin animación de cierre),
  evitando la ruta de `_NSWindowTransformAnimation`.

## 1.4.1 — 2026-10-06

- Corregido crash (SIGSEGV) al cerrar las ventanas de «Administrar conexiones»
  y «Llaves de acceso»: la ventana se liberaba en `windowWillClose` mientras la
  animación de cierre seguía activa. Ahora se conserva en caché y reabrir es
  instantáneo.

## 1.4.0 — 2026-10-06

- **Llaves de acceso SSH**: ventana «Llaves de acceso…» con CRUD completo
  (nombre, rutas de llave pública y privada con selector de archivos, notas).
- **Autenticación por llave en conexiones ssh/sftp**: el formulario permite
  elegir entre Password y Llave SSH y seleccionar una llave guardada; se
  almacena en `key_id` (nueva columna con FK a `keys`).
- **Probar acceso…**: valida la conexión real por llave (`ssh -i … BatchMode`)
  o password (vía `/usr/bin/expect`, usando una variable de entorno y no los
  argumentos). Si el password está vacío al editar, usa el guardado con Touch ID.
- MCP: herramienta `list_keys`; `create_connection`/`update_connection`
  aceptan `auth` (`password`/`key`) y `key_name`.
- La ventana de conexiones muestra el tipo de autenticación.

## 1.3.0 — 2026-10-06

- **Ventana «Administrar conexiones…»**: tabla de conexiones con grupo,
  nombre, protocolo, host y usuario; buscador en vivo, doble clic para editar,
  y botones Nueva / Editar / Eliminar con confirmación.
- Reutiliza el formulario y el store del CRUD 1.2.0; la ventana se recarga tras
  cada alta, baja o cambio.

## 1.2.0 — 2026-10-06

- **CRUD completo de conexiones** (GUI + CLI + MCP):
  - Create: formulario «Nueva conexión…» y herramienta MCP `create_connection`.
  - Read: menú/detalles, CLI `list` y herramientas `list_connections` /
    `get_connection`.
  - Update: botón «Editar…» y herramienta MCP `update_connection` (campos
    omitidos se conservan).
  - Delete: botón «Eliminar…» con confirmación, CLI `delete <id>` y herramienta
    MCP `delete_connection` (pide Touch ID y borra el secreto del Keychain).
- **Campos específicos por protocolo** en una columna `details` (JSON con
  migración automática): mysql/postgres → `database`; website/admin → `url`.
- Formulario dinámico que muestra u oculta campos según el protocolo elegido.
- MCP termina limpiamente al cerrar stdin (EOF).

## 1.1.0 — 2026-10-06

- Formulario GUI **«Nueva conexión…»** para crear conexiones manualmente:
  grupo (existente o nuevo), nombre, host, puerto, protocolo, usuario,
  password y notas.
- **Editar…** desde los detalles de una conexión; conserva el secreto del
  Keychain si no se introduce un password nuevo.
- `Store.updateConnection` actualiza por id y conserva `keychain_account`.

## 1.0.0 — 2026-10-06

- App nativa de barra de estado (Swift, sin dependencias externas).
- SQLite local para grupos y conexiones; secretos en el Keychain de macOS.
- Touch ID para leer o copiar secretos, con fallback a la contraseña del equipo.
- Importador de FileZilla `sites.xml` (carpetas anidadas → grupos;
  passwords base64 → Keychain).
- Servidor MCP por stdio: `list_groups`, `list_connections`, `get_connection`
  y `get_connection_password` (Touch ID).
- CLI: `list`, `import <ruta>` y `version`.
- Instalador/desinstalador con LaunchAgent y firma ad-hoc.
