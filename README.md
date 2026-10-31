# GDW Vault

**Bóveda local de conexiones para macOS, gratis, con integración MCP y
autorización explícita.**

GDW Vault organiza conexiones SSH, SFTP, FTP, bases de datos, sitios web y APIs.
La aplicación nativa está escrita 100% en Swift y no requiere dependencias
externas. Guarda metadatos en **SQLite**, credenciales en el **Llavero de
macOS** y ofrece herramientas MCP para clientes compatibles, además de una CLI.

No es una bóveda compartida ni un servicio en la nube. La sincronización con
iCloud está desactivada; los datos de la bóveda se usan localmente en esta Mac.
Al conectarse a un servidor remoto, la aplicación envía las credenciales
necesarias a ese destino.

- **Versión:** [VERSION](./VERSION)
- **Costo:** gratis; descarga y uso sin costo. Donaciones opcionales.
- **CLI:** `gdw-vault version`
- **Descargar ahora (recomendado):** [instalador `.pkg` v1.6.2](https://github.com/josecruzchavez/gdw-vault/releases/latest/download/GDW-Vault-1.6.2-universal.pkg)
- **Otras descargas y versiones:** [GitHub Releases](https://github.com/josecruzchavez/gdw-vault/releases/latest)
- **Homebrew:** [tap de GDW Vault](https://github.com/josecruzchavez/homebrew-gdw-vault)
- **Código fuente (opcional):** [guía para compilar e instalar](./DEVELOPMENT.md)
- **Cambios:** [CHANGELOG.md](./CHANGELOG.md)
- **Sitio:** [vault.gdw.mx](https://vault.gdw.mx)
- **Guía de releases:** [RELEASING.md](./RELEASING.md)
- **Aviso de uso y seguridad:** [TERMS.md](./TERMS.md)

## Índice

- [Qué problema resuelve](#qué-problema-resuelve)
- [Características](#características)
- [Costo y donaciones](#costo-y-donaciones-pricing)
- [Requisitos](#requisitos)
- [Instalación, actualización y desinstalación](#instalación-actualización-y-desinstalación)
- [Instalación desde una release](#instalación-desde-una-release)
- [Compilar e instalar desde el código fuente](./DEVELOPMENT.md)
- [Uso](#uso)
- [Integración MCP](#integración-mcp)
- [Aviso de uso y seguridad](#aviso-de-uso-y-seguridad)
- [Seguridad y datos](#seguridad-y-datos)
- [Importar desde FileZilla](#importar-desde-filezilla)
- [Ubicación de los datos](#dónde-se-guardan-los-datos)
- [Arquitectura y recuperación](#arquitectura-y-recuperación)
- [Comparativa con herramientas similares](#comparativa-con-herramientas-similares)
- [Limitaciones y siguientes pasos](#limitaciones-y-siguientes-pasos)
- [Historial de versiones](./CHANGELOG.md)

---

## Qué problema resuelve

Cuando trabajas con servidores, bases de datos y servicios web desde distintas
herramientas, necesitas reutilizar conexiones sin copiar passwords a archivos
de configuración o al código del proyecto. GDW Vault mantiene esas conexiones
en un almacén local y permite utilizarlas desde la interfaz, la terminal o un
cliente MCP.

La app aplica controles distintos según la operación: listar datos no equivale
a leer un secreto, y una consulta de lectura no equivale a una escritura
destructiva. Las acciones sensibles requieren confirmación y autenticación local
según el modo de cada conexión.

## Características

- **Almacenamiento local:** SQLite para grupos y metadatos; Llavero de macOS
  para passwords y tokens.
- **Interfaz nativa:** app de barra de estado, administración de conexiones y
  llaves SSH, y pruebas de acceso.
- **Conectividad:** SSH/SFTP/FTP, MySQL, PostgreSQL, sitios web y APIs.
- **Integración MCP:** herramientas para administrar conexiones, consultar
  bases de datos, ejecutar comandos SSH, hacer peticiones HTTP y entregar
  secretos a CLIs locales.
- **Controles por conexión:** modos Lectura, Info, Edición y Unsafe; confirmación
  y Touch ID/contraseña de sesión para operaciones protegidas.
- **Importación:** FileZilla `sites.xml`, incluidas sus carpetas y credenciales.
- **CLI:** listar, importar, eliminar o ejecutar un proceso local con un secreto
  inyectado sin ponerlo en los argumentos.

## Costo y donaciones (Pricing)

**GDW Vault es gratis y no tiene costo de descarga ni de uso.** Precio: **$0**.
Puedes instalarla y usar todas las funciones disponibles sin pago, suscripción
ni compras dentro de la aplicación. Las donaciones son voluntarias, no son
necesarias para usar GDW Vault y no desbloquean funciones.

**English:** GDW Vault is free of charge: **$0 to download, install, and use**.
No payment, subscription, or in-app purchase is required. Donations are
optional and do not unlock features.

## Requisitos

- macOS 13 (Ventura) o posterior.
- Acceso de red a los servidores a los que quieras conectarte.
- Touch ID es opcional: macOS puede pedir la contraseña de inicio de sesión
  como alternativa para autorizar operaciones sensibles.

```
┌─────────────────────────────────────────────────┐
│              GDW Vault (barra de estado)          │
│                                                  │
│  SQLite (vault.db)         Keychain de macOS    │
│  grupos y conexiones  →    passwords cifrados   │
│                                                  │
│  Touch ID para leer secretos                     │
│  Modo MCP: gdw-vault --mcp  →  VS Code/Copilot   │
│  Modo CLI:  gdw-vault list / import              │
└─────────────────────────────────────────────────┘
```

## Instalación, actualización y desinstalación

La aplicación está disponible ya compilada; no necesitas clonar ni compilar el
código para instalarla. Si quieres compilarla desde el código fuente, consulta
la [guía de desarrollo](./DEVELOPMENT.md).

### Instalación completa con Homebrew

```bash
brew install --cask josecruzchavez/gdw-vault/gdw-vault
```

En Homebrew 7, si la primera instalación se detiene porque el cask no es de
confianza, ejecútalo una vez y repite el comando de instalación:

```bash
brew trust --cask josecruzchavez/gdw-vault/gdw-vault
```

El cask instala la app en `/Applications`, registra el LaunchAgent para el
autoinicio y el servicio XPC, y enlaza el comando `gdw-vault` en el directorio
`bin` de Homebrew. Al desinstalarlo con `brew uninstall --cask gdw-vault`, se
retiran esos componentes, pero se conservan la base de datos y las credenciales
del Llavero.

### Instalación desde una release

Descargas directas de la release actual **v1.6.2**:

- [Instalador recomendado `.pkg`](https://github.com/josecruzchavez/gdw-vault/releases/latest/download/GDW-Vault-1.6.2-universal.pkg): instala la app y configura el servicio y la CLI.
- [App `.dmg`](https://github.com/josecruzchavez/gdw-vault/releases/latest/download/GDW-Vault-1.6.2-universal.dmg): abre el disco y arrastra **GDW Vault.app** a **Aplicaciones**.
- [App `.zip`](https://github.com/josecruzchavez/gdw-vault/releases/latest/download/GDW-Vault-1.6.2-universal.zip): alternativa al DMG para instalación manual.
- [Checksums SHA-256](https://github.com/josecruzchavez/gdw-vault/releases/latest/download/SHA256SUMS.txt).

La app universal funciona en Macs Apple Silicon e Intel, y está firmada y
notarizada por Apple. No necesitas clonar el repositorio ni compilar el código.
Consulta [GitHub Releases](https://github.com/josecruzchavez/gdw-vault/releases/latest)
para ver versiones anteriores y sus notas.

El `.pkg` firmado y notarizado ofrece una instalación automatizada; el `.dmg`
y el `.zip` solo instalan la app. Si prefieres Homebrew, el Cask automatiza la
misma configuración.

#### Configurar el CLI después de instalar el `.dmg` o `.zip`

La app debe estar en `/Applications/GDW Vault.app`. Si todavía no existe
`/usr/local/bin/gdw-vault`, ejecuta:

```bash
APP="/Applications/GDW Vault.app"
sudo mkdir -p /usr/local/bin
sudo ln -s "$APP/Contents/MacOS/GDW Vault" /usr/local/bin/gdw-vault
"$APP/Contents/Resources/InstallSupport/setup-launch-agent.sh" install
```

El enlace requiere una cuenta de administrador; el helper registra el inicio
automático y el servicio XPC para CLI/MCP. No vuelvas a crear el enlace si ya
existe. Comprueba el resultado con `which gdw-vault` y `gdw-vault version`.
La configuración del cliente MCP (por ejemplo, VS Code) sigue siendo aparte.

### Desinstalar

Para desinstalar una instalación compilada desde el código fuente, sigue la
[guía de desarrollo](./DEVELOPMENT.md#desinstalar-una-instalación-local).

Si instalaste con Homebrew, ejecuta `brew uninstall --cask gdw-vault`. Para una
instalación desde `.pkg`, ejecuta:

```bash
sudo "/Applications/GDW Vault.app/Contents/Resources/InstallSupport/uninstall-pkg.sh"
```

Detiene el proceso y el LaunchAgent, borra `/Applications/GDW Vault.app`
y el plist de autoinicio. **Conserva** base de datos y Keychain (por seguridad,
para no perder tus accesos por accidente). Para borrarlo todo manualmente:

```bash
rm -rf ~/Library/Application\ Support/GDWVault
# Secretos: Keychain Access → buscar "mx.gdw.vault" → borrar entradas
```

## Uso

### App de barra de estado (GUI)

```bash
open -a "GDW Vault"
```

- Candado verde en la barra de estado.
- Menú con tus grupos (📁) y conexiones por protocolo (🖥 sftp, 📂 ftp, 🌐 web).
- **Administrar conexiones…** → ventana con tabla de todas las conexiones:
  buscador, doble clic para editar, y botones Nueva / Editar / Eliminar.
- **Llaves de acceso…** → ventana para administrar llaves SSH: nombre, ruta
  de la llave pública y de la llave privada (con selector de archivos).
- **Nueva conexión…** (⌘N) → formulario para dar de alta accesos manualmente
  (grupo, nombre, host, puerto, protocolo, usuario, password y notas).
  Los campos extra dependen del protocolo: **mysql/postgres** piden
  «Base de datos» (obligatoria); **website/admin** piden «URL».
  En **ssh/sftp** puedes elegir autenticación por **Password** o por
  **Llave SSH** (elige una de las llaves guardadas) y usar **Probar acceso…**
  para validar la conexión real antes de guardar. La opción independiente
  **Permitir lectura de archivos sensibles** viene desactivada y también puede
  cambiarse desde el detalle de la conexión, sin abrir la edición; si se activa,
  cada llamada que mencione un nombre protegido requiere `confirm=true` y Touch
  ID, sin depender del modo de escritura.
  En **website/api** el campo «Auth HTTP» elige cómo se envía el token
  (sin auth, Basic, token en cabecera, cabecera personalizada o query param);
  «Password / token» guarda el secreto en el Keychain.
- Clic en una conexión → detalles → con password aparece **"Copiar password"**
  (pide Touch ID); con llave SSH, **"Copiar comando de conexión"** incluye
  `-i`. También están **"Editar…"** y **"Eliminar…"** (con confirmación; borra
  el secreto del Keychain si existe).
- **Importar FileZilla (sites.xml)…** con selector de archivos.

### Sincronización entre dispositivos

La sincronización con iCloud está **desactivada temporalmente**. GDW Vault usa
únicamente la base SQLite local y el Keychain de esta Mac; no importa ni exporta
el snapshot de iCloud. Si ya existe un snapshot en iCloud Drive, permanece allí
sin cambios. La sincronización fiable entre Macs queda pendiente de diseño e
implementación.

### CLI (mismo binario)

```bash
gdw-vault list                        # listar conexiones (sin secretos)
gdw-vault import ~/Downloads/sites.xml  # importar FileZilla
gdw-vault delete 14                   # eliminar conexión por id (y su secreto)
gdw-vault exec "Nombre" -- <comando>  # ejecutar con el secreto inyectado
```

## Integración MCP

### Configurar VS Code / Copilot

Añade el servidor a `mcp.json` del cliente. En VS Code, el formato es:

```json
{
  "servers": {
    "gdw-vault": {
      "type": "stdio",
      "command": "/Applications/GDW Vault.app/Contents/MacOS/GDW Vault",
      "args": ["--mcp"]
    }
  }
}
```

La app de barra debe estar instalada y activa. Recarga con **MCP: Reload
Servers**. Cada cliente inicia su proceso MCP por stdio; las consultas y
mutaciones de SQLite se envían por XPC al servicio local de la app. No apuntes
los clientes directamente al archivo de la base de datos.

Herramientas disponibles:

| Tool | Touch ID |
|---|---|
| `list_groups` | No |
| `list_connections` | No |
| `get_connection` | No (host/usuario/puerto, sin secreto) |
| `get_connection_password` | **Sí** — pide huella antes de entregar |
| `create_connection` | No (requiere group_name, name, protocol) |
| `update_connection` | No (campos omitidos se conservan) |
| `delete_connection` | **Sí** — pide huella antes de borrar |
| `list_keys` | No (llaves SSH: nombre y rutas, sin contenido) |
| `db_query` | Lectura: ventana de gracia 15 min · Escritura: **siempre huella fresca** |
| `ssh_exec` | Allowlist de lectura/cambios conocidos · comandos no reconocidos se elevan a ejecución nativa |
| `ssh_native_exec` | **Unsafe + huella fresca** |
| `run_with_secret` | Proceso local con secreto · nativo: Unsafe + huella fresca |
| `http_request` | Ídem — HTTP con sesión y autenticación de la conexión |

**Aviso de privacidad:** `get_connection_password` devuelve intencionalmente el
password en la respuesta MCP tras Touch ID, si el usuario elige «Proceder
(mostrar en el chat)». Asimismo, `get_connection_command(include_password=true)`
muestra un aviso con opciones para copiar, proceder o cancelar; solo «Proceder»
incluye el password en el comando MCP para MySQL/Postgres. Al elegir copiar, el
comando se devuelve sin password y el secreto va al portapapeles. La opción de
proceder puede exponerlo al cliente MCP/modelo; no la elijas si necesitas que el
secreto permanezca fuera del chat.

Campos por protocolo en create/update:

| Protocolo | Campos extra |
|---|---|
| `ssh`, `sftp`, `ftp`, `ftpes`, `ftps` | solo base (host, port, username, password) |
| `mysql`, `postgres` | `database` (opcional, se puede pedir después) |
| `website` | `url` (opcional) |
| `api` | `url`, `auth_type` (`none`/`basic`/`bearer`/`header`/`query`), `header_name`, `query_param` |

Autenticación por llave en ssh/sftp: pasa `auth: "key"` y `key_name`
(nombre de una llave de `list_keys`); `auth: "password"` (default) la quita.

## Seguridad y datos

### Aviso de uso y seguridad

Al iniciar la interfaz de la app, GDW Vault muestra el aviso y requiere
aceptación explícita. El servidor MCP no muestra este aviso al arrancar; sigue
disponible en el menú de la barra de estado como **Seguridad y uso…**. La
aceptación de la interfaz se guarda en las preferencias locales para esta
versión del aviso.

Los clientes MCP pueden invocar herramientas y transmitir al chat/modelo los
datos que estas devuelvan. Algunas acciones permiten entregar secretos
explícitamente. Usa solo conexiones autorizadas, revisa las solicitudes y
protege los secretos y los sistemas remotos.

La aceptación informa al usuario de los riesgos; **no garantiza por sí sola
eximir al desarrollador de responsabilidad ni reemplaza asesoría legal**. Lee
[TERMS.md](./TERMS.md) y consulta asesoría legal antes de distribuir la
aplicación o establecer términos vinculantes en cualquier jurisdicción.

SQLite guarda metadatos de conexión y no usa cifrado a nivel de aplicación.
macOS limita el acceso a los archivos mediante los permisos de la cuenta; otros
procesos ejecutados por el mismo usuario pueden acceder a esos metadatos. Los
passwords y tokens se guardan por separado en el Llavero de macOS.

### Archivos de configuración protegidos por SSH

Las conexiones SSH/SFTP bloquean por defecto comandos que mencionen estos
nombres (sin distinguir mayúsculas/minúsculas; se admiten sufijos de backup).
Si se habilita el permiso por conexión, cada llamada sensible aún requiere
`confirm=true`; Touch ID se solicita al primer acceso y se reutiliza durante
15 minutos para lecturas de esa conexión. Las escrituras siguen requiriendo
Touch ID fresco.

- Globales: `.env` y variantes `.env.*`.
- WordPress/Magento: `wp-config.php`, `env.php`, `local.xml`.
- Joomla/Drupal: `configuration.php`, `settings.php`.
- PrestaShop/Symfony: `parameters.php`, `parameters.yml`, `app_local.php`,
  `credentials.yml.enc`, `decrypt.private.php`.
- TYPO3/Laravel: `LocalConfiguration.php`, `bootstrap/cache/config.php`.
- CodeIgniter: `Database.php`.
- Rails/Spring/ASP.NET: `master.key`, `application*.properties`,
  `application*.yml`/`application*.yaml`, `appsettings*.json`.
- Ghost: `config.production.json`, `config.staging.json` y
  `config.development.json`.
- Llaves privadas SSH: `id_rsa`, `id_ecdsa`, `id_ed25519`, `id_dsa`,
  `ssh_host_*_key` y archivos `.pem`, `.key`, `.p12`, `.pfx` o `.ppk`.

El contenido de llaves privadas se bloquea siempre y no se devuelve al chat,
incluso si está habilitada la lectura de otros archivos sensibles.

Los programas no reconocidos, intérpretes, comandos compuestos y ejecuciones de
frameworks se clasifican genéricamente como **ejecución nativa**; no hace falta
una regla por CMS. `ssh_native_exec` solo funciona en modo `unsafe` y pide Touch
ID fresco directamente, sin un diálogo adicional. El motivo de Touch ID indica
que el proceso conserva los permisos de la cuenta SSH; la autenticación **no es
un sandbox**. `ssh_exec` también eleva comandos no reconocidos o compuestos a
ejecución nativa, para evitar eludir la regla mediante un intérprete dentro de
una cadena.

Para permitir una excepción a la detección de referencias directas, edita la
conexión en la app de barra y activa **Permitir lectura de archivos sensibles**.
Cada referencia detectada requiere `confirm=true` y Touch ID. No se bloquea el
nombre genérico `config.php`, porque aparece en muchas aplicaciones sin contener
necesariamente credenciales.

Este filtro por nombre es una defensa adicional y no sustituye los permisos del
servidor. Solo reconoce referencias explícitas: un framework puede cargar
indirectamente su configuración al arrancar, y el filtro no lo detectará. Para
restringir realmente lo que un programa nativo puede leer o modificar, usa una
cuenta SSH y una cuenta de base de datos con permisos mínimos o un entorno aislado.

### Entrega de secretos a CLIs (`run_with_secret`)

`run_with_secret` entrega el secreto a un proceso local (variable de entorno o
stdin). En llamadas MCP, stdout y stderr se descartan y solo se devuelve el
código de salida, porque una redacción literal no puede detectar todas las
transformaciones posibles del secreto. La CLI local `gdw-vault exec` sí muestra
la salida en la terminal del operador.

```
run_with_secret(name="Producción", command="pg_dump -h $PGHOST -U app mi_db")
run_with_secret(name="API Stripe",  command="curl -s -H 'X-Key: '$GDW_SECRET ...")
```

- `env_var` (default `GDW_SECRET`) elige el nombre de la variable; `stdin=true`
  lo inyecta por entrada estándar (para clientes que lo piden así).
- El valor **no** viaja en los argumentos ni stdout/stderr del proceso MCP se
  incorporan a la respuesta.
- Si la conexión usa llave SSH, se inyecta la **ruta** de la llave privada.
- Aplica la misma política de modos que `ssh_exec` (lectura → solo comandos de
  lectura; `info` bloquea y muestra el comando de consola; `edición`/`unsafe`
  piden `confirm=true` + huella fresca).
- Equivalente para que lo ejecutes tú: `gdw-vault exec "Nombre" -- <comando>`.

### HTTP/API genérico (`http_request`)

Conexiones `website` y `api` tienen URL y autenticación guardadas; el cliente
mantiene un **cookie jar en memoria** por conexión (vive lo que vive el
servidor MCP, nunca se escribe a disco).

```
http_request(name="Panel", path="/api/v1/health")
http_request(name="Panel", method="POST", path="/api/v1/items",
             body_json={"nombre": "x"}, confirm=true)
```

- `auth_type`: `none`, `basic` (usuario + password), `bearer`, `header`
  (`header_name`) o `query` (`query_param`).
- `path` es relativa a la URL de la conexión; `url` acepta una URL absoluta
  del mismo origen. Las peticiones con credenciales requieren HTTPS y las
  redirecciones a otros orígenes no se siguen.
- `follow_redirects`, `query`, `headers`, `clear_cookies` y `timeout` opcionales.
- Política por modo: `lectura` solo GET/HEAD/OPTIONS; `info` bloquea escritura
  y muestra el `curl` equivalente; `edición` permite POST/PUT/PATCH con
  `confirm=true`; `unsafe` permite todo; `DELETE` solo en `unsafe`.
- La respuesta trae `status`, cabeceras relevantes, cuerpo recortado a 20 KB y
  el número de cookies de sesión. Se omiten query, fragmento y userinfo de las
  URL devueltas; el token y su forma base64 se redactan en el cuerpo.
- Las cookies viven **en memoria** del servidor MCP: al reiniciar VS Code la
  sesión se pierde (vuelve a autenticarte con la primera petición).

Limitación conocida: el HTTP sale directo desde esta Mac; para un panel que
solo responde dentro de una red privada usa `db_query`/`ssh_exec` con `curl`
remoto, o expón el servicio por un túnel propio.

### Modos de seguridad por conexión

Cada conexión mysql/postgres/ssh/sftp tiene un campo **«Modo»** en el
formulario que gobierna qué puede ejecutar el MCP (`db_query`, `ssh_exec` y
`ssh_native_exec`):

Aplica a SQL (`db_query`), SSH (`ssh_exec`), CLIs locales (`run_with_secret`) y
HTTP (`http_request`; lo destructivo es `DELETE`).

| Modo | Lectura | Escritura moderada¹ | Destructiva² | Nativa/arbitraria |
|---|---|---|---|---|
| **Lectura** (default) | ✅ allowlist acotada | 🔒 bloqueado | 🔒 bloqueado | 🔒 bloqueada |
| **Info** | ✅ allowlist acotada | 🔒 + comando para consola | 🔒 + comando para consola | 🔒 bloqueada |
| **Edición** | ✅ allowlist acotada | ✅ `confirm=true` + huella fresca | 🔒 + comando para consola | 🔒 bloqueada |
| **Unsafe** | ✅ allowlist acotada | ✅ `confirm=true` + huella fresca | ✅ `confirm=true` + huella fresca | ✅ huella fresca directa |

¹ SQL: `INSERT`, `UPDATE` · SSH: cambios conocidos como `mkdir`, `cp`, `touch`
² SQL: `DELETE`, `DROP`, `TRUNCATE`, `ALTER` · SSH: `rm`, `dd`, `chmod/chown`, `kill`, `systemctl`, `apt`… Los comandos desconocidos o compuestos se elevan a ejecución nativa.

Otras protecciones incluidas:

- **Túnel automático**: si la BD es local y hay ssh/sftp en el mismo grupo,
  `db_query` abre el túnel solo; sin ssh en el grupo, conecta directo.
- **Matching difuso**: los nombres de conexión aceptan typos
  (`loclahost` → `Localhost`).
- **Ventana de gracia**: un Touch ID exitoso autoriza 15 minutos de
  lecturas; cada respuesta trae el campo `auth` con la auditoría
  (`"Touch ID pedido 1 vez, 3 llamadas reutilizaron la autorización"`).
- Macs sin Touch ID piden el password de sesión; sin ninguna
  autenticación configurada, la operación se rechaza.

> **Ejecución compuesta por SSH**: encadenar pasos con `&&` se considera
> ejecución nativa. Solo se ejecuta mediante `ssh_native_exec` en modo `unsafe`
> y pide Touch ID fresco:
>
> ```
> mkdir -p /tmp/inv && echo inicio > /tmp/inv/log.txt && \
> grep ERROR /var/log/app.log >> /tmp/inv/log.txt && cat /tmp/inv/log.txt
> ```
>
> En modo Unsafe la cadena completa se ejecuta como código nativo; revisa cada
> paso antes de autenticar. Touch ID autoriza la operación, pero no inspecciona
> ni separa internamente sus pasos.

## Importar desde FileZilla

Lee `sites.xml` (FileZilla3):

- `<Folder>` anidados → grupos aplanados como `"Padre / Hijo"`.
- `<Server>` → conexión (Name, Host, Port, User, Protocol).
- Protocolos: 0→ftp, 1→sftp, 3→ftpes, 4→ftps, resto→ftp.
- `<Pass encoding="base64">` se decodifica y guarda en el Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, solo este dispositivo).
- Re-importar es seguro: `ON CONFLICT ... DO UPDATE` (no duplica).

## Dónde se guardan los datos

| Dato | Ubicación |
|---|---|
| App instalada | `/Applications/GDW Vault.app` |
| Base de datos | `~/Library/Application Support/GDWVault/vault.db` |
| Secretos | Keychain de sesión, servicio `mx.gdw.vault` |
| Autoinicio | `~/Library/LaunchAgents/mx.gdw.vault.plist` |
| CLI/MCP wrapper | `gdw-vault/gdw-vault` |

## Arquitectura y recuperación

Cada cliente MCP conserva un proceso y un canal stdio independientes, pero no
abre SQLite por su cuenta: las consultas se envían por XPC al servicio
registrado en la sesión del usuario, alojado por la app de barra. El servicio
serializa el acceso a la conexión SQLite; SQLite usa WAL, espera hasta 5
segundos ante un bloqueo y registra errores de consulta. Esto evita que las
instancias de distintos chats compitan directamente por la base.

La app de barra usa un bloqueo de instancia y el LaunchAgent la vuelve a
iniciar tras una salida anormal. Un vigilante detecta si el hilo principal no
responde durante 45 segundos y sale para que LaunchAgent recupere la app. Una
salida normal desde el menú **Salir** no la reinicia. Al instalar o actualizar
con el `.pkg` o Homebrew, se registra el servicio XPC en el LaunchAgent. Para
instalaciones compiladas localmente, consulta la
[guía de desarrollo](./DEVELOPMENT.md). Los errores XPC y SQL se registran en
Console como `GDW Vault`; si la app sigue congelándose, esos registros y el
informe de fallo de macOS ayudarán a identificar la causa concreta.

Las eliminaciones de conexiones y llaves agrupan sus cambios relacionados en
una transacción SQLite, para no dejar tombstones o referencias a medias si una
operación falla.

## Comparativa con herramientas similares

GDW Vault reúne en una aplicación local para macOS la gestión de conexiones y
herramientas MCP para trabajar con SSH/SFTP, bases de datos y servicios HTTP.
Los productos de esta tabla resuelven necesidades relacionadas, pero tienen
enfoques distintos; no son equivalentes directos ni necesariamente excluyentes.

| Producto | Enfoque | Diferencia de enfoque frente a GDW Vault |
|---|---|---|
| [Termius Vault](https://www.termius.com/vault) | Bóvedas cifradas para datos de conexión y opciones para compartirlas con equipos. | Se centra en administrar y usar conexiones SSH; GDW Vault también ofrece herramientas MCP para SSH, SQL y HTTP desde una app local de macOS. |
| [Secretive](https://github.com/maxgoedjen/secretive) | Gestión de llaves SSH con Secure Enclave y autorización local. | Está especializado en llaves SSH. GDW Vault administra conexiones de varios tipos y puede referenciar una llave existente por su ruta; no afirma protegerla con Secure Enclave. |
| [1Password SSH Agent](https://developer.1password.com/docs/ssh/) | Proporciona llaves SSH guardadas en 1Password a clientes SSH. | Complementa el cliente SSH; GDW Vault integra conexiones y herramientas MCP para distintas operaciones, además de SSH. |
| [Infisical MCP Server](https://github.com/Infisical/infisical-mcp-server) | Expone capacidades de una plataforma de secretos a agentes MCP, con restricciones y enmascaramiento configurables. | Es una plataforma de gestión de secretos; GDW Vault está pensado como una app personal de macOS para gestionar conexiones y acceder a servicios. |
| [StrongDM MCP Gateway](https://docs.strongdm.com/ai/mcp-gateway) | Proxy para servidores MCP con políticas y auditoría centralizadas. | Está orientado al control de acceso de organizaciones e infraestructura; GDW Vault prioriza el uso local desde una Mac. |
| [Teleport Session Recording](https://goteleport.com/docs/reference/architecture/session-recording/) | Control y grabación de sesiones SSH y de bases de datos para auditoría. | Se enfoca en el acceso y la auditoría del lado de la infraestructura; no en una bóveda personal de macOS con herramientas MCP. |

El enfoque de GDW Vault es local-first: los metadatos se guardan en SQLite y
los secretos en el Llavero de macOS; la sincronización entre dispositivos está
desactivada. Incluye autorización local y modos de operación por conexión.
Esto describe su diseño, no una afirmación de superioridad o una auditoría de
seguridad comparativa.

La integración MCP tampoco significa que todos los secretos sean invisibles
para el modelo de IA: algunas herramientas pueden devolver explícitamente un
secreto al cliente. Si se usa un modelo remoto, revisa qué datos devuelve cada
herramienta y las políticas del proveedor. El filtro de nombres de archivos
sensible en comandos SSH es heurístico y no sustituye los permisos del servidor.

Consulta el [panorama competitivo detallado](./competitive-landscape.md) para
el alcance, las fuentes y las limitaciones de esta comparación. Las funciones
y condiciones de los productos pueden cambiar; verifica la documentación de
cada proveedor antes de tomar decisiones.

## Limitaciones y siguientes pasos

- Diseñar e implementar sincronización entre Macs (evaluar CloudKit/CKSyncEngine).
  Hasta entonces, la sincronización con iCloud permanece desactivada y los datos
  locales siguen funcionando de forma independiente.
- Instalador remoto mediante `curl` y publicación en Homebrew, con artefactos
  verificables y un flujo de actualización.
- Extensión de VS Code para registrar GDW Vault MCP automáticamente, sin editar
  `.vscode/mcp.json`; evaluar asistentes de configuración para otros clientes
  MCP compatibles.
- Administración de grupos (renombrar/eliminar) desde la GUI.
- Export/backup cifrado.

## Términos de búsqueda / Search terms

GDW Vault es un **gestor de conexiones para macOS** y una **bóveda local de
credenciales** para SSH/SFTP, MySQL, PostgreSQL y APIs. Incluye un **servidor
MCP para VS Code y GitHub Copilot** e importación de conexiones de FileZilla.

**Búsquedas relacionadas:** gestor de conexiones macOS, administrador SSH
para Mac, bóveda local de credenciales, servidor MCP macOS, MCP para VS Code,
MCP para MySQL y PostgreSQL, importar sitios de FileZilla.

**Related search terms:** macOS connection manager, SSH/SFTP manager, local
secrets vault, MCP server for VS Code and GitHub Copilot, MySQL/PostgreSQL MCP
server, FileZilla connection importer.
