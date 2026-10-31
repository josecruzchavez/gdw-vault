#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
APP_PATH="${GDW_VAULT_APP_PATH:-/Applications/GDW Vault.app}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GDW Vault"
LABEL="mx.gdw.vault"

resolve_target_user() {
    if [[ "$(id -u)" -eq 0 ]]; then
        TARGET_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
        case "$TARGET_USER" in
            ""|root|loginwindow|_mbsetupuser)
                return 1
                ;;
        esac

        TARGET_UID="$(id -u "$TARGET_USER")"
        USER_RECORD="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory)"
        TARGET_HOME="${USER_RECORD#NFSHomeDirectory: }"
    else
        TARGET_USER="$(id -un)"
        TARGET_UID="$(id -u)"
        TARGET_HOME="${HOME:?No se pudo determinar el directorio del usuario}"
    fi

    [[ "$TARGET_UID" =~ ^[0-9]+$ && "$TARGET_HOME" == /* && -d "$TARGET_HOME" ]]
}

if [[ "$ACTION" != "install" && "$ACTION" != "remove" ]]; then
    echo "Uso: setup-launch-agent.sh install|remove" >&2
    exit 2
fi

if ! resolve_target_user; then
    if [[ "$ACTION" == "install" ]]; then
        echo "Aviso: no hay una sesión gráfica activa; el LaunchAgent no se registró." >&2
        exit 0
    fi
    echo "No se pudo determinar el usuario de la sesión gráfica para retirar el LaunchAgent." >&2
    exit 1
fi

GUI_DOMAIN="gui/$TARGET_UID"
SERVICE_TARGET="$GUI_DOMAIN/$LABEL"
AGENT_DIR="$TARGET_HOME/Library/LaunchAgents"
PLIST_PATH="$AGENT_DIR/$LABEL.plist"

remove_agent() {
    if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
        /bin/launchctl bootout "$SERVICE_TARGET"
    fi
    /bin/rm -f "$PLIST_PATH"
}

if [[ "$ACTION" == "remove" ]]; then
    remove_agent
    echo "LaunchAgent retirado; los datos locales y el Llavero se conservaron."
    exit 0
fi

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "No existe el ejecutable instalado: $APP_EXECUTABLE" >&2
    exit 1
fi

if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
    /bin/launchctl bootout "$SERVICE_TARGET"
fi

if [[ ! -d "$AGENT_DIR" ]]; then
    /bin/mkdir -p "$AGENT_DIR"
    if [[ "$(id -u)" -eq 0 ]]; then
        /usr/sbin/chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$AGENT_DIR"
    fi
fi

TEMP_PLIST="$(/usr/bin/mktemp "$AGENT_DIR/.${LABEL}.XXXXXX")"
trap '/bin/rm -f "$TEMP_PLIST"' EXIT
umask 022
cat > "$TEMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>MachServices</key>
    <dict>
        <key>mx.gdw.vault.db.$TARGET_UID</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
/bin/chmod 644 "$TEMP_PLIST"
if [[ "$(id -u)" -eq 0 ]]; then
    /usr/sbin/chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TEMP_PLIST"
fi
/bin/mv -f "$TEMP_PLIST" "$PLIST_PATH"
trap - EXIT
/bin/launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
echo "LaunchAgent registrado para $TARGET_USER."
