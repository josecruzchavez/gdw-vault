#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Uso: sign-app.sh <app-path> <identity>}"
SIGN_IDENTITY="${2:?Uso: sign-app.sh <app-path> <identity>}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "✕ No existe el bundle de aplicación: $APP_PATH" >&2
    exit 1
fi

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
    if ! grep -Fq "$SIGN_IDENTITY" <<< "$SIGNING_IDENTITIES"; then
        echo "✕ No se encontró una identidad válida: $SIGN_IDENTITY" >&2
        exit 1
    fi
fi

if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
else
    codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"
fi

codesign --verify --strict "$APP_PATH"
