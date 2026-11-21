#!/bin/bash
# Sube un archivo al uploader propio (carpeta uploader/).
# Uso: upload_uploader.sh archivo
# Requiere UPLOADER_URL y UPLOADER_TOKEN (secrets del repo).
# Opcional: UPLOADER_DAYS (caducidad en días).
# Igual que upload_gofile.sh, escribe el enlace en download_url.txt.
set -e

FILE="$1"
if [ ! -f "$FILE" ]; then
  echo "❌ File not found: $FILE"
  exit 1
fi
if [ -z "$UPLOADER_URL" ] || [ -z "$UPLOADER_TOKEN" ]; then
  echo "❌ UPLOADER_URL / UPLOADER_TOKEN not set (add them as repository secrets)"
  exit 1
fi

echo "Uploading $(basename "$FILE") to uploader..."

ARGS=(-fsS --retry 3
  -H "Authorization: Bearer ${UPLOADER_TOKEN}"
  -T "$FILE")
[ -n "$UPLOADER_DAYS" ] && ARGS+=(-H "Max-Days: ${UPLOADER_DAYS}")

if DOWNLOAD_URL=$(curl "${ARGS[@]}" "${UPLOADER_URL%/}/"); then
  DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | tr -d '\r\n')
  echo "✅ Upload successful!"
  echo "$DOWNLOAD_URL"
  echo "$DOWNLOAD_URL" > download_url.txt
  exit 0
else
  echo "❌ Upload failed"
  exit 1
fi
