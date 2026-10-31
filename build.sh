#!/bin/bash
# Build GDW Vault .app bundle
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GDW Vault"
BUNDLE_ID="mx.gdw.vault"
APP_VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
INSTALL_SUPPORT_DIR="$RES_DIR/InstallSupport"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$INSTALL_SUPPORT_DIR"

echo "==> Compilando Swift…"
BUILD_ARCHS="${GDW_BUILD_ARCHS:-$(uname -m)}"
read -r -a ARCHS <<< "$BUILD_ARCHS"
if [[ ${#ARCHS[@]} -eq 0 ]]; then
  echo "✕ GDW_BUILD_ARCHS no contiene arquitecturas." >&2
  exit 1
fi

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *)
      echo "✕ Arquitectura no admitida: $ARCH (usa arm64 y/o x86_64)." >&2
      exit 1
      ;;
  esac

  BINARY="$BUILD_DIR/$APP_NAME-$ARCH"
  swiftc Sources/*.swift \
    -target "$ARCH-apple-macosx13.0" \
    -o "$BINARY" \
    -framework AppKit \
    -framework LocalAuthentication \
    -framework Security \
    -O -parse-as-library
  BINARIES+=("$BINARY")
done

if [[ ${#BINARIES[@]} -eq 1 ]]; then
  mv "${BINARIES[0]}" "$MACOS_DIR/$APP_NAME"
else
  lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/$APP_NAME"
  rm -f "${BINARIES[@]}"
fi
echo "==> Arquitecturas: ${ARCHS[*]}"

echo "==> Generando iconos demo (icns)…"
ICONSET_DIR="$BUILD_DIR/app.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" assets/icon-template.png --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/icon-template.png --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "==> Copiando icono de barra de menús…"
cp assets/StatusIcon.png assets/StatusIcon@2x.png "$RES_DIR/"
cp scripts/setup-launch-agent.sh scripts/uninstall-pkg.sh "$INSTALL_SUPPORT_DIR/"
chmod 755 "$INSTALL_SUPPORT_DIR/setup-launch-agent.sh" "$INSTALL_SUPPORT_DIR/uninstall-pkg.sh"

echo "==> Escribiendo Info.plist…"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "✓ Listo: $APP_DIR"
echo "  Ejecuta: open \"$APP_DIR\""
