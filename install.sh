#!/bin/bash
# Instala GDW Vault como aplicación de macOS:
#   1. Copia el .app a /Applications
#   2. Crea un LaunchAgent para arrancar al iniciar sesión
#   3. Actualiza el wrapper CLI (gdw-vault) para apuntar a /Applications
#
# Uso:
#   ./install.sh            instalar
#   ./install.sh uninstall  desinstalar

set -euo pipefail

APP_NAME="GDW Vault"
APP_DIR="$(cd "$(dirname "$0")" && pwd)/build/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
PLIST="$HOME/Library/LaunchAgents/mx.gdw.vault.plist"
WRAPPER="$(cd "$(dirname "$0")" && pwd)/gdw-vault"
LAUNCH_AGENT_HELPER="$(dirname "$0")/scripts/setup-launch-agent.sh"

uninstall() {
    echo "==> Deteniendo y desinstalando…"
    "$LAUNCH_AGENT_HELPER" remove
    rm -f "$PLIST"
    rm -rf "$INSTALLED_APP"
    echo "✓ Desinstalado. La base de datos (~/Library/Application Support/GDWVault) y el Keychain se conservan."
}

if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
    exit 0
fi

[[ -d "$APP_DIR" ]] || { echo "✕ No existe $APP_DIR — ejecuta ./build.sh primero"; exit 1; }

# Firma antes de sustituir la app instalada, para conservarla si la firma falla.
SIGN_IDENTITY="${GDW_SIGN_IDENTITY:-GDW Development}"
SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
if [[ -z "${GDW_SIGN_IDENTITY:-}" ]] &&
   ! grep -Fq "$SIGN_IDENTITY" <<< "$SIGNING_IDENTITIES"; then
    SIGN_IDENTITY="-"
fi

echo "==> Firmando con '$SIGN_IDENTITY'…"
"$(dirname "$0")/scripts/sign-app.sh" "$APP_DIR" "$SIGN_IDENTITY"

# 1. Copiar a /Applications
echo "==> Instalando en /Applications…"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -rf "$INSTALLED_APP"
cp -R "$APP_DIR" "$INSTALLED_APP"
codesign --verify --strict "$INSTALLED_APP"

# 2. LaunchAgent: arranca al iniciar sesión y registra el servicio XPC
echo "==> Registrando LaunchAgent…"
GDW_VAULT_APP_PATH="$INSTALLED_APP" "$LAUNCH_AGENT_HELPER" install

# Eliminar la copia de build/: solo debe existir UNA app (la instalada),
# si no Spotlight/Launchpad la muestran duplicada.
rm -rf "$APP_DIR"

# 3. Wrapper CLI apuntando a la app instalada
echo "==> Actualizando wrapper CLI…"
cat > "$WRAPPER" <<WRAPPER
#!/bin/bash
exec "$INSTALLED_APP/Contents/MacOS/$APP_NAME" "\$@"
WRAPPER
chmod +x "$WRAPPER"

echo "✓ Instalado:"
echo "  App:        $INSTALLED_APP"
echo "  Autoinicio: $PLIST"
echo "  CLI/MCP:    $WRAPPER"
