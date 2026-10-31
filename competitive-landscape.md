# Panorama competitivo para GDW Vault

**Fecha de consulta:** 2026-10-30  
**Propósito:** referencia inicial para preparar posteriormente la propuesta de valor de GDW Vault.  
**Alcance:** comparación breve de productos con capacidades cercanas; no es una auditoría de seguridad ni una evaluación exhaustiva de precios o planes.

## Resumen ejecutivo

En esta revisión no se encontró un producto que reúna exactamente las capacidades de GDW Vault en una sola aplicación: gestión local de conexiones en macOS, secretos en Keychain, autorización con Touch ID, herramientas para agentes mediante MCP y políticas por conexión para operaciones SSH y consultas de bases de datos.

Las alternativas cubren partes distintas del problema:

- Clientes SSH con bóveda de credenciales.
- Gestores especializados en llaves SSH y autenticación local.
- Gestores de secretos que exponen herramientas MCP.
- Gateways empresariales para autorizar y auditar llamadas MCP.
- Plataformas de acceso privilegiado para SSH y bases de datos.

## Productos de referencia

| Producto | Capacidades relevantes | Diferencias frente a GDW Vault |
|---|---|---|
| [Termius Vault](https://www.termius.com/vault) | Bóvedas cifradas para datos de conexión; controles de acceso para compartir bóvedas con equipos. | Su foco es la administración y uso de conexiones SSH. No equivale al conjunto de herramientas MCP de GDW Vault para SSH, SQL y HTTP. |
| [Secretive](https://github.com/maxgoedjen/secretive) | App para macOS que protege llaves SSH con Secure Enclave; puede requerir Touch ID y notificar el uso de llaves. | Es especialista en llaves SSH; no es una bóveda general de passwords, conexiones de bases de datos ni un servidor MCP de operaciones. |
| [1Password SSH Agent](https://developer.1password.com/docs/ssh/) | Guarda llaves SSH en una bóveda cifrada y permite autorizar solicitudes SSH, incluidas opciones biométricas como Touch ID. | Proporciona llaves al cliente SSH existente; no sustituye un servidor MCP para administrar conexiones y ejecutar consultas. |
| [Infisical MCP Server](https://github.com/Infisical/infisical-mcp-server) | Integra gestión de secretos con agentes compatibles con MCP. Permite limitar las herramientas expuestas y enmascarar valores secretos mediante configuración. | Es una plataforma de gestión de secretos, no una app personal de barra de menús para sesiones SSH/SQL. Su documentación indica que hay que configurar explícitamente las restricciones y el enmascaramiento. |
| [StrongDM MCP Gateway](https://docs.strongdm.com/ai/mcp-gateway) | Hace de proxy para servidores MCP y ofrece control centralizado, políticas de autorización y auditoría de llamadas. | Está orientado al gobierno de acceso en organizaciones e infraestructura; no a una bóveda personal local en macOS. |
| [Teleport Session Recording](https://goteleport.com/docs/reference/architecture/session-recording/) | Controla y puede grabar sesiones SSH y de bases de datos para auditoría. | Se enfoca en el acceso y la auditoría del lado de la infraestructura; no es una app personal de barra de menús ni un gestor MCP equivalente. |

## Capacidades actuales de GDW Vault que sirven como punto de comparación

- Aplicación de macOS en la barra de menús.
- Metadatos de conexiones en SQLite y secretos en Keychain.
- Autorización local con Touch ID para operaciones sensibles.
- Integración MCP para clientes de agentes.
- Herramientas para conexiones SSH/SFTP, bases de datos y servicios HTTP.
- Modos de operación y confirmaciones por conexión.
- Filtro adicional de nombres de archivos de configuración en comandos SSH; es heurístico y no sustituye los permisos del servidor.

## Posibles ejes de diferenciación

1. **Flujo local-first para una persona desarrolladora:** acceso a conexiones desde macOS sin desplegar una plataforma corporativa.
2. **Puente directo hacia agentes MCP:** los agentes pueden invocar herramientas de acceso con controles locales, en vez de recibir credenciales sin mediación.
3. **Varias clases de acceso en una misma interfaz:** SSH, bases de datos y HTTP.
4. **Consentimiento local para operaciones sensibles:** Touch ID y confirmaciones explícitas.
5. **Políticas por conexión:** distintos límites según el entorno o el acceso configurado.

Estos puntos son hipótesis para posicionamiento, no afirmaciones de superioridad frente a los productos listados.

## Límites y afirmaciones que deben tratarse con cuidado

- El filtro de archivos sensibles analiza nombres en comandos y es defensa en profundidad; no es una frontera de seguridad frente a un shell arbitrario. La cuenta SSH del servidor debe tener permisos mínimos.
- No afirmar que las llaves privadas están protegidas por Secure Enclave: GDW Vault puede guardar una ruta a una llave existente, mientras que Secretive se especializa en llaves de Secure Enclave.
- Distinguir “el agente no necesita recibir la credencial” de “ningún valor secreto puede llegar al contexto del agente”: algunas herramientas pueden devolver valores como parte de su respuesta si no se configuran para enmascararlos.
- La grabación de sesiones puede ayudar con auditoría, pero también puede conservar datos sensibles que aparezcan en la terminal.
- Las funciones, planes y documentación de proveedores pueden cambiar; verificar cada capacidad y condición antes de publicar comparativas comerciales.

## Fuentes consultadas

- [Termius Vault](https://www.termius.com/vault)
- [Secretive — repositorio oficial](https://github.com/maxgoedjen/secretive)
- [1Password for SSH & Git](https://developer.1password.com/docs/ssh/)
- [Infisical MCP Server — repositorio oficial](https://github.com/Infisical/infisical-mcp-server)
- [StrongDM MCP Gateway](https://docs.strongdm.com/ai/mcp-gateway)
- [Teleport Session Recording](https://goteleport.com/docs/reference/architecture/session-recording/)
