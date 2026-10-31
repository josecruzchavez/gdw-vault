# Guía práctica de instalación y MCP

Esta guía explica cómo instalar GDW Vault, configurar el servidor MCP y usarlo
con conexiones SSH, MySQL y las APIs de Magento, WordPress y Joomla. Los
ejemplos de consultas son de solo lectura; las credenciales se guardan en la
app, no en el chat ni en el archivo de configuración MCP.

## 1. Instalar GDW Vault

La app debe ejecutarse localmente en macOS; las conexiones pueden apuntar a
servidores remotos.

### Opción recomendada: instalador `.pkg`

Descarga el [instalador más reciente desde GitHub Releases](https://github.com/josecruzchavez/gdw-vault/releases/latest).
El `.pkg` instala la app y configura los componentes necesarios para CLI/MCP.

### Opción Homebrew

```bash
brew install --cask josecruzchavez/gdw-vault/gdw-vault
```

El Cask instala la app en `/Applications` y configura el servicio local. Para
instalaciones desde `.dmg` o `.zip`, sigue los pasos de
[configuración del CLI en el README](./README.md#configurar-el-cli-después-de-instalar-el-dmg-o-zip).

Abre GDW Vault y comprueba que aparece su icono en la barra de menús. La app y
el servicio local deben estar instalados para que el cliente MCP pueda acceder
a la bóveda.

## 2. Guardar conexiones en la app

Antes de usar el chat, crea las conexiones en GDW Vault. Usa nombres claros y
separa producción, pruebas y desarrollo; por ejemplo, `Tienda producción —
lectura`.

### Conexión SSH

En el formulario de conexiones, selecciona el protocolo **ssh** e indica grupo,
nombre, host, puerto (normalmente `22`) y usuario. Elige autenticación por
password o una llave SSH registrada en GDW Vault. Para empezar, conserva el
modo **lectura** y utiliza una cuenta remota con permisos mínimos.

### Conexión MySQL

Selecciona **mysql** e indica host, puerto (normalmente `3306`), usuario, base
de datos y password. Si la base solo es accesible desde un servidor SSH, guarda
la conexión de base de datos en el mismo grupo que la conexión SSH; también
puedes indicar explícitamente `ssh_name` en una llamada `db_query`.

El modo SQL inicial es **lectura**: permite `SELECT`, `SHOW`, `DESCRIBE` y
`EXPLAIN`. Las escrituras requieren cambiar el modo de esa conexión y aprobar
Touch ID.

### Conexión a una API o sitio

Selecciona **api** (o **website**) y configura la URL base. Para conexiones con
credenciales usa siempre `https://`. GDW Vault admite autenticación sin secreto,
Basic, Bearer, una cabecera personalizada o un parámetro de query. Escribe el
token o password en el formulario de la app; no lo incluyas en prompts, ejemplos
ni archivos `mcp.json`.

Deja el modo **lectura** mientras configuras la conexión. En ese modo HTTP
permite únicamente `GET`, `HEAD` y `OPTIONS`.

## 3. Configurar MCP en VS Code / GitHub Copilot

Para tener GDW Vault disponible en todos tus workspaces de GitHub Copilot, usa
la [extensión GDW Vault MCP en Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=JosCruzChvez.gdw-vault-mcp).
Su comando **GDW Vault: Instalar MCP para GitHub Copilot** agrega el servidor a
`$COPILOT_HOME/mcp-config.json` o, si esa variable no está definida,
`~/.copilot/mcp-config.json`. Mantiene las otras entradas y no guarda
credenciales en ese archivo.

Si prefieres configurarlo manualmente para un solo workspace, crea o edita
`.vscode/mcp.json`:

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

Guarda el archivo y ejecuta **MCP: Reload Servers** desde la paleta de comandos
de VS Code. Comprueba la conexión pidiendo al asistente que liste los grupos o
conexiones disponibles; esas herramientas no devuelven passwords.

La configuración `.vscode/mcp.json` es específica de VS Code y se conserva por
compatibilidad. Para otros clientes MCP, registra el servidor como **stdio**
con el ejecutable de GDW Vault y el argumento `--mcp`; la ubicación y el formato
del archivo dependen del cliente. Cada cliente inicia un proceso MCP
independiente. Las consultas y cambios de la bóveda se envían por XPC al
servicio local de la app; no configures el cliente para abrir directamente el
archivo SQLite.


## 4. Ejemplos de uso

Los siguientes bloques muestran los argumentos que el cliente envía a la
herramienta MCP. Puedes pedir la misma operación en lenguaje natural; por
ejemplo: “Usa la conexión `Servidor web — lectura` y consulta el espacio en
disco. No cambies archivos”.

### Consultar un servidor SSH

`ssh_exec` requiere el nombre de la conexión y un comando. `df -h` está dentro
de los comandos de lectura reconocidos:

```json
{
  "ssh_name": "Servidor web — lectura",
  "command": "df -h"
}
```

También puedes comprobar el directorio remoto:

```json
{
  "ssh_name": "Servidor web — lectura",
  "command": "pwd"
}
```

Los programas no reconocidos, intérpretes y comandos compuestos se consideran
ejecución nativa: requieren modo **unsafe** y Touch ID fresco. Esa ejecución
usa los permisos de la cuenta SSH y no está aislada por GDW Vault.

### Consultar MySQL

`db_query` recibe el nombre de la conexión y SQL. Si la base guardada en la
conexión es la correcta, puedes omitir `database`:

```json
{
  "db_name": "MySQL tienda — lectura",
  "sql": "SHOW TABLES;"
}
```

Para listar algunas entradas de WordPress, reemplaza `wp_posts` si el sitio usa
otro prefijo de tablas:

```json
{
  "db_name": "MySQL WordPress — lectura",
  "database": "wordpress",
  "sql": "SELECT ID, post_title, post_status FROM wp_posts ORDER BY post_date DESC LIMIT 10;"
}
```

Evita consultar tablas de usuarios o hashes de passwords si no son necesarios.
Para una base accesible a través de SSH, puedes precisar el puente así:

```json
{
  "db_name": "MySQL tienda — lectura",
  "ssh_name": "Servidor web — lectura",
  "sql": "SHOW TABLES;"
}
```

### WordPress: listar entradas

Configura la URL base como `https://blog.ejemplo.com` y usa autenticación
**Basic** con un usuario de permisos mínimos y una **Application Password**
creada para la integración. WordPress documenta este método para solicitudes
REST sobre HTTPS; no uses el password habitual de la cuenta.

```json
{
  "name": "WordPress — lectura",
  "method": "GET",
  "path": "/wp-json/wp/v2/posts",
  "query": {
    "per_page": "5",
    "_fields": "id,date,slug,title,status"
  }
}
```

Para consultar una entrada concreta, cambia `path` por
`/wp-json/wp/v2/posts/123` y sustituye `123` por su ID.

### Magento / Adobe Commerce: listar productos

Para Magento Open Source o Adobe Commerce PaaS, configura la URL base con el
prefijo REST de la tienda, por ejemplo
`https://tienda.ejemplo.com/rest/default`, y guarda un token Bearer con solo
los permisos de API necesarios:

```json
{
  "name": "Magento — lectura",
  "method": "GET",
  "path": "/V1/products",
  "query": {
    "searchCriteria[pageSize]": "5"
  }
}
```

Si la instalación usa otro código de tienda, reemplaza `default` en la URL
base. Adobe Commerce as a Cloud Service usa OAuth 2; GDW Vault envía el token
Bearer que guardaste, pero no obtiene ni renueva tokens automáticamente.

### Joomla: listar artículos

Configura la URL base como `https://joomla.ejemplo.com`. En la conexión API,
elige autenticación **Header**, indica `X-Joomla-Token` como nombre de cabecera
y guarda el token de API de Joomla como secreto. La API y los permisos
correspondientes deben estar habilitados en el sitio.

```json
{
  "name": "Joomla — lectura",
  "method": "GET",
  "path": "/api/index.php/v1/content/articles",
  "headers": {
    "Accept": "application/vnd.api+json"
  }
}
```

Para consultar un artículo concreto, cambia `path` por
`/api/index.php/v1/content/articles/123` y sustituye `123` por su ID.

## 5. Permisos y solución de problemas

- **MCP no aparece en VS Code:** confirma que la ruta de `command` existe,
  abre GDW Vault y ejecuta **MCP: Reload Servers**.
- **Conexión no encontrada o ambigua:** usa el nombre completo de la conexión;
  GDW Vault acepta coincidencias parciales, pero un nombre único evita errores.
- **Error HTTP 401/403:** revisa el método de autenticación, el secreto guardado
  en la app y los permisos de la cuenta del CMS. Las credenciales HTTP requieren
  HTTPS y no se envían a otro origen.
- **La operación de escritura se bloquea:** HTTP `POST`/`PUT`/`PATCH` requiere
  modo **edición** o **unsafe**, `confirm: true` y Touch ID fresco. `DELETE`
  solo está permitido en **unsafe**. En SQL y SSH también se aplican los modos
  y límites propios de cada conexión.
- **La respuesta HTTP es larga:** GDW Vault limita el cuerpo devuelto a 20 000
  caracteres.

Mantén el modo **lectura** siempre que sea suficiente. Las herramientas de
lectura no hacen que un comando SSH arbitrario sea seguro: solo una lista
acotada de comandos se considera lectura; lo demás requiere autorización
explícita. Las llaves privadas nunca se devuelven al chat.

## Referencias oficiales

- [WordPress REST API: autenticación y Application Passwords](https://developer.wordpress.org/rest-api/using-the-rest-api/authentication/)
- [WordPress REST API: entradas](https://developer.wordpress.org/rest-api/reference/posts/)
- [Adobe Commerce: búsquedas en endpoints REST](https://developer.adobe.com/commerce/webapi/rest/use-rest/performing-searches)
- [Adobe Commerce as a Cloud Service: autenticación REST](https://developer.adobe.com/commerce/webapi/rest/authentication/)
- [Joomla: Web Services y endpoints API](https://manual.joomla.org/docs/5.4/general-concepts/webservices/)
