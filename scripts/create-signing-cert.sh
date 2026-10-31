#!/bin/bash
# Crea un certificado de firma de código auto-firmado (sin cuenta Apple Developer).
# La identidad estable evita que el Keychain pida permiso por cada secreto
# después de cada rebuild (problema de la firma ad-hoc).
#
# Uso: ./scripts/create-signing-cert.sh [Nombre]   (default: GDW Development)
set -euo pipefail

CN="${1:-GDW Development}"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

echo "==> Generando certificado '$CN' (válido 10 años)…"
openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=$CN" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

echo "==> Empaquetando e importando al llavero de sesión…"
# -legacy: macOS 'security import' no lee el cifrado moderno de OpenSSL 3.
openssl pkcs12 -export -legacy -out "$DIR/identity.p12" \
  -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -password pass:gdw-temp-import \
  || openssl pkcs12 -export -out "$DIR/identity.p12" \
  -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -password pass:gdw-temp-import \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$DIR/identity.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P gdw-temp-import -T /usr/bin/codesign

echo "==> Marcando el certificado como confiable para firma de código…"
security add-trusted-cert -p codeSign "$DIR/cert.pem" 2>/dev/null \
  || security add-trusted-cert -p codesigning "$DIR/cert.pem"

echo "✓ Identidad creada:"
security find-identity -v -p codesigning | grep "$CN" || true
