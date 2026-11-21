# Uploader

Servicio personal de subida de archivos, al estilo transfer.sh. Es un solo binario Go, sin dependencias externas, y funciona por terminal y por web.

- Solo tú subes: hace falta `UPLOAD_TOKEN`. Para descargar basta con el enlace.
- Caducidad por archivo (1–`MAX_DAYS` días) y límite opcional de descargas.
- Subida en streaming a disco: aguanta archivos de varios GB sin usar RAM.
- Las descargas se pueden reanudar (HTTP Range).
- Token de borrado por archivo y limpieza automática cada 10 min.
- Web con arrastrar y soltar, barra de progreso y lista de tus archivos.

## Despliegue (VPS con Docker)

1. Apunta un registro DNS `A` (p. ej. `files.tudominio.com`) a la IP del VPS.
2. En el VPS:

```bash
cd uploader
cp .env.example .env
openssl rand -hex 24   # pega el resultado en UPLOAD_TOKEN dentro de .env
nano .env              # ajusta DOMAIN y BASE_URL
docker compose up -d --build
```

Caddy saca el certificado HTTPS automáticamente. Los archivos se guardan en `./data`.

### Sin Docker

```bash
go build -o uploader .
UPLOAD_TOKEN=xxxx BASE_URL=https://files.tudominio.com ./uploader
```

Y pon delante cualquier proxy con HTTPS (Caddy, nginx).

## Uso

```bash
# Subir (devuelve el enlace)
curl -H "Authorization: Bearer $TOKEN" -T firmware.zip https://files.tudominio.com/

# Con caducidad de 2 días y máximo 5 descargas
curl -H "Authorization: Bearer $TOKEN" -H "Max-Days: 2" -H "Max-Downloads: 5" -T a.zip https://files.tudominio.com/

# Multipart
curl -H "Authorization: Bearer $TOKEN" -F file=@a.zip https://files.tudominio.com/

# Borrar (el token sale en la cabecera X-Delete-Token de la subida)
curl -X DELETE -H "X-Delete-Token: <token>" https://files.tudominio.com/AbC123xy/a.zip

# Listar tus archivos
curl -H "Authorization: Bearer $TOKEN" https://files.tudominio.com/api/files
```

Cliente incluido: `UPLOADER_URL=... UPLOADER_TOKEN=... ./up.sh archivo [días] [descargas]`

Con `Accept: application/json` la subida devuelve JSON (`url`, `delete_token`, `expires`…).

## Configuración

| Variable | Defecto | Descripción |
|---|---|---|
| `UPLOAD_TOKEN` | — (obligatorio, ≥16 car.) | Token para subir, listar y borrar |
| `BASE_URL` | se deduce del Host | URL pública usada en los enlaces |
| `LISTEN` | `:8080` | Dirección de escucha |
| `DATA_DIR` | `./data` | Carpeta de almacenamiento |
| `MAX_SIZE_MB` | `10240` | Tamaño máximo por archivo |
| `DEFAULT_DAYS` | `7` | Caducidad por defecto |
| `MAX_DAYS` | `30` | Caducidad máxima |

## Almacenamiento

Cada archivo se guarda como `data/<id>.bin`, con sus metadatos en `data/<id>.json`. No hay base de datos: para hacer copia de seguridad basta con copiar `data/`.

## Notas

- Si usas Cloudflare con proxy (nube naranja), el plan gratuito corta las subidas a **100 MB**. Para archivos grandes, deja el DNS en "solo DNS".

## Usarlo con los workflows de SamFWDumper

Los workflows `dump.yml` y `system_files.yml` tienen el destino **`uploader`**. Para activarlo:

1. En el repo: *Settings → Secrets and variables → Actions → New repository secret*:
   - `UPLOADER_URL` = `https://files.tudominio.com`
   - `UPLOADER_TOKEN` = el mismo `UPLOAD_TOKEN` del servidor
2. Opcional, en la pestaña *Variables*: `UPLOADER_DAYS` (días de caducidad; si no la pones, se usa `DEFAULT_DAYS`).
3. Lanza el workflow y elige `uploader` en *Upload destination*.

Los enlaces van a la Release igual que con GoFile, pero **caducan** según `UPLOADER_DAYS` o `MAX_DAYS`. Si quieres que duren más, sube `MAX_DAYS` en el servidor.
