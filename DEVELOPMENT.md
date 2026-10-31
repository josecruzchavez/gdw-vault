# Compilar e instalar desde el código fuente

GDW Vault ya está disponible como una app compilada en
[GitHub Releases](https://github.com/josecruzchavez/gdw-vault/releases/latest)
y mediante Homebrew. Esta guía es para quienes quieran compilar o instalar la
versión local desde el código fuente.

## Requisitos

- macOS 13 (Ventura) o posterior.
- Git y Xcode Command Line Tools.

## Primera instalación

Clona el repositorio y compila e instala la app:

```bash
git clone https://github.com/josecruzchavez/gdw-vault.git
cd gdw-vault
./build.sh && ./install.sh
```

`install.sh`:

1. Copia el `.app` a `/Applications` y lo firma con la identidad configurada
   (`GDW_SIGN_IDENTITY`, por defecto `GDW Development`) si está disponible;
   de lo contrario usa firma ad-hoc. Si se usa Developer ID, aplica Hardened
   Runtime y timestamp. La firma local no sustituye la notarización necesaria
   para distribuir la app; consulta la [guía de releases](./RELEASING.md).
2. Crea `~/Library/LaunchAgents/mx.gdw.vault.plist` para iniciar la app al
   iniciar sesión.
3. Actualiza el wrapper `gdw-vault` del proyecto para que CLI y MCP usen la
   app instalada.

## Actualizar una instalación local

Desde el repositorio clonado, obtiene los cambios y recompila:

```bash
git pull
./build.sh && ./install.sh
gdw-vault version
```

`install.sh` reemplaza la app en `/Applications` y reinicia el LaunchAgent.
**Tus datos no se eliminan:** la base de datos
(`~/Library/Application Support/GDWVault/vault.db`) y los secretos del
Llavero persisten entre versiones. Si una versión cambia el esquema de la
base, la app lo migra al arrancar.

Para preparar y publicar una versión, sigue la [guía de releases](./RELEASING.md).

## Desinstalar una instalación local

```bash
./install.sh uninstall
```

Esto elimina la app y el LaunchAgent, pero conserva la base de datos y los
secretos del Llavero para evitar perder tus accesos.
