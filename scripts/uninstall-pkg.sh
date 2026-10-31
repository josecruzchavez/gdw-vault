#!/bin/bash
set -euo pipefail

APP_PATH="/Applications/GDW Vault.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GDW Vault"
LAUNCH_AGENT_HELPER="$APP_PATH/Contents/Resources/InstallSupport/setup-launch-agent.sh"
CLI_PATH="/usr/local/bin/gdw-vault"
PACKAGE_ID="mx.gdw.vault.installer"

if [[ "$(id -u)" -ne 0 ]]; then
    exec /usr/bin/sudo "$0" "$@"
fi

if [[ ! -x "$LAUNCH_AGENT_HELPER" ]]; then
    echo "No se encontró el instalador de LaunchAgent en $APP_PATH." >&2
    exit 1
fi

"$LAUNCH_AGENT_HELPER" remove

if [[ -L "$CLI_PATH" ]] && [[ "$(/usr/bin/readlink "$CLI_PATH")" == "$APP_EXECUTABLE" ]]; then
    /bin/rm -f "$CLI_PATH"
elif [[ -e "$CLI_PATH" || -L "$CLI_PATH" ]]; then
    echo "Se conservó $CLI_PATH porque no pertenece a GDW Vault." >&2
fi

/usr/sbin/pkgutil --forget "$PACKAGE_ID"
/bin/rm -rf "$APP_PATH"
echo "GDW Vault se desinstaló. La base SQLite y los secretos del Llavero se conservaron."
