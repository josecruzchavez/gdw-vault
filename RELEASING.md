# Releases

El workflow [`.github/workflows/release.yml`](./.github/workflows/release.yml)
se ejecuta al publicar un tag `v*`. Comprueba que coincida con `VERSION`,
compila una app universal para Apple Silicon e Intel, la firma con Developer ID,
la notariza con Apple y crea un GitHub Release con un `.dmg`, un `.zip`, un
instalador `.pkg` y sus checksums SHA-256.

## Preparación de GitHub

En **Settings → Environments → production → Environment secrets**, configura
estos secretos:

| Secreto | Valor |
|---|---|
| `DEVELOPER_ID_APPLICATION` | Nombre exacto de la identidad, por ejemplo `Developer ID Application: Nombre (TEAMID)`. |
| `APPLE_CERTIFICATE_P12_BASE64` | Certificado Developer ID y llave privada exportados juntos como `.p12`, codificados en Base64. |
| `APPLE_CERTIFICATE_PASSWORD` | Contraseña usada al exportar el `.p12`. |
| `DEVELOPER_ID_INSTALLER` | Nombre exacto de la identidad `Developer ID Installer: Nombre (TEAMID)`. |
| `APPLE_INSTALLER_CERTIFICATE_P12_BASE64` | Certificado Developer ID Installer y llave privada exportados juntos como `.p12`, codificados en Base64. |
| `APPLE_INSTALLER_CERTIFICATE_PASSWORD` | Contraseña usada al exportar el `.p12` del instalador. |
| `APPLE_API_KEY_P8_BASE64` | Llave privada `.p8` de una API key de App Store Connect, codificada en Base64. |
| `APPLE_API_KEY_ID` | Key ID de esa API key. |
| `APPLE_API_ISSUER_ID` | Issuer ID de App Store Connect. |

Exporta el certificado desde **Acceso a Llaveros → Mis certificados** e incluye
la llave privada. Genera una API key de App Store Connect autorizada para
notarización. Crea y exporta **dos certificados distintos**: `Developer ID
Application` para la app y `Developer ID Installer` para el paquete `.pkg`.
Codifica los archivos localmente para copiar el contenido a los secrets; nunca
agregues el `.p12`, el `.p8`, sus contraseñas o sus contenidos al repositorio:

```bash
base64 -i DeveloperID-Application.p12 | pbcopy
base64 -i DeveloperID-Installer.p12 | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

El workflow crea un llavero temporal en el runner, verifica la identidad
importada y elimina el material de firma al terminar. Los valores secretos no
se guardan en los artefactos del release.

## Publicar una versión

1. Actualiza `VERSION`, los enlaces de descarga versionados en `README.md` y
   agrega las notas correspondientes en `CHANGELOG.md`.
2. Sube esos cambios a la rama principal.
3. Crea y publica un tag que coincida exactamente con `VERSION`; para `1.6.1`:

   ```bash
   git tag -a v1.6.1 -m "GDW Vault 1.6.1"
   git push origin v1.6.1
   ```

4. Revisa la ejecución **Actions → Release** y verifica el `.dmg`, el `.zip` y
   el `.pkg` en GitHub Releases, además de `SHA256SUMS.txt`.

El workflow no publica una versión si falta una credencial, el tag no coincide,
la firma falla o Apple rechaza la notarización.

## Firma local

Para instalar desde el código usando una identidad Developer ID ya instalada
en el llavero:

```bash
GDW_SIGN_IDENTITY="Developer ID Application: Nombre (TEAMID)" ./install.sh
```

La app local se firma con Hardened Runtime y timestamp. Esto valida la firma,
pero la notarización solo se realiza en el workflow de releases.
