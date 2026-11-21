#!/usr/bin/env bash
# Cliente de terminal: ./up.sh archivo [días] [máx_descargas]
# Requiere UPLOADER_URL y UPLOADER_TOKEN en el entorno.
set -euo pipefail

FILE="${1:?Uso: up.sh archivo [días] [máx_descargas]}"
DAYS="${2:-}"
DLS="${3:-}"
: "${UPLOADER_URL:?Define UPLOADER_URL (ej. https://files.tudominio.com)}"
: "${UPLOADER_TOKEN:?Define UPLOADER_TOKEN}"

[ -f "$FILE" ] || { echo "No existe: $FILE" >&2; exit 1; }

ARGS=(-fsS --retry 3 -H "Authorization: Bearer ${UPLOADER_TOKEN}" -T "$FILE")
[ -n "$DAYS" ] && ARGS+=(-H "Max-Days: $DAYS")
[ -n "$DLS" ] && ARGS+=(-H "Max-Downloads: $DLS")
[ -t 2 ] && ARGS+=(--progress-bar) || true

curl "${ARGS[@]}" "${UPLOADER_URL%/}/"
