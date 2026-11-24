# FW Kitchen

Kitchen de ROMs para firmwares Samsung (y Android en general), con interfaz gráfica para **Linux** y **Android**. Está hecha en Flutter y no requiere root.

El núcleo está en Dart puro (`lib/engine/`), así que la mayoría de operaciones funcionan igual en el PC y en el móvil, sin root y sin binarios externos.

## Funciones

| Función | Linux | Android sin root | Android con root |
|---|---|---|---|
| Importar `.zip` de Samsung, `AP/BL/CP/CSC .tar.md5`, `.img`, `.lz4` | ✅ | ✅ | ✅ |
| LZ4 (frame y legacy), sparse ↔ raw | ✅ | ✅ | ✅ |
| `super.img`: desempaquetar y reconstruir (mismos grupos, tamaño y versión de metadatos) | ✅ | ✅ | ✅ |
| Extraer **ext4** con `fs_config` + `file_contexts` (uid/gid/permisos, SELinux, capabilities) | ✅ | ✅ | ✅ |
| Extraer **EROFS** | ✅ (extract.erofs incluido) | ⏳ etapa 2 | ⏳ etapa 2 |
| Construir **EROFS** / **ext4** | ✅ (mkfs.erofs, mke2fs + e2fsdroid incluidos) | ⏳ etapa 2 | ⏳ etapa 2 |
| Debloat con lista de apps real y patrones editables (Knox, Facebook, Bixby…) | ✅ | ✅ | ✅ |
| `boot.img` v0–v4: desempaquetar / reempaquetar (conserva el footer AVB) | ✅ | ✅ | ✅ |
| `vbmeta`: desactivar verity y verificación | ✅ | ✅ | ✅ |
| Crear `AP_*.tar.md5` para Odin (LZ4 opcional) | ✅ | ✅ | ✅ |
| Copiar particiones del propio dispositivo (`dd` desde `/dev/block/by-name`) | — | — | ✅ |

⏳ En Android, extraer y construir EROFS, y construir ext4, necesitan binarios ARM64. Ver [Etapa 2](#etapa-2).

## Flujo típico

1. **Nuevo proyecto** y **Importar firmware**. Al elegir el `.zip` o el `AP_*.tar.md5`, la app descomprime LZ4, convierte sparse a raw y desempaqueta `super.img` en `system`, `vendor`, `product`…
2. **Imágenes → Extraer todas**. Los archivos quedan en `extracted/<partición>/` y los metadatos en `extracted/config/`.
3. **Debloat**: marcar las apps sugeridas o elegirlas a mano, y eliminar.
4. Editar lo que quieras: `build.prop`, `fstab`, añadir apps… Los archivos nuevos heredan uid, gid y contexto SELinux de su carpeta.
5. **ROM → Construir** cada partición, como EROFS o ext4.
6. **Salida → Construir super.img**, desactivar verity en `vbmeta` y **Crear AP para Odin**.

Estructura de un proyecto:

```
<espacio de trabajo>/<proyecto>/
  input/       firmware original (tar.md5, super.img original)
  images/      imágenes raw (boot, vbmeta, system, vendor…)
  extracted/   <partición>/ + config/ (fs_config, file_contexts, mount_point, fs_type)
  boot/        boot desempaquetados (kernel, ramdisk, dtb, boot_info.json)
  output/      imágenes construidas, super.img, AP_*.tar.md5
  project.json metadatos (incluida la geometría del super original)
  kitchen.log  registro
```

## Compilar

Requiere Flutter (probado con 3.50.1).

```bash
cd kitchen
flutter pub get
flutter build linux --release      # build/linux/x64/release/bundle/ (incluye tools/)
flutter build apk --release --target-platform android-arm64
```

En Linux hacen falta `libgtk-3-dev`, `clang`, `cmake` y `ninja`. Las herramientas x86-64 de `../tools/` se copian solas al bundle.

## Pruebas

```bash
flutter test
```

Las pruebas contrastan el motor con las herramientas oficiales de `../tools/`:

- `lpmake`, `lpunpack` y `lpdump` para `super.img`.
- `simg2img` e `img2simg` para sparse.
- `mkbootimg` para boot.img, que sale idéntico byte a byte.
- python-lz4 para LZ4.
- `e2fsck` y `fsck.erofs` sobre las imágenes reconstruidas.

También incluyen un flujo completo con un firmware Samsung sintético: zip → AP → super sparse+lz4 → extraer → debloat → reconstruir → super → vbmeta → AP para Odin.

## Android: notas

- La app pide **"Acceso a todos los archivos"** para leer firmwares de la memoria interna.
- Deja el espacio de trabajo en el almacenamiento interno de la app, que es el valor por defecto. `/sdcard` no admite enlaces simbólicos ni permisos Unix, y la ROM reconstruida saldría rota. Usa **Salida → Exportar** para copiar los resultados a Descargas.
- Los binarios se buscan en el directorio de librerías nativas de la app, con el nombre `lib<herramienta>.so`. Detalles en `android/app/src/main/jniLibs/README.md`.

## Etapa 2

- Lector EROFS en Dart puro, como el de ext4, para extraer sin binarios en Android.
- Binarios ARM64 estáticos de `mkfs.erofs` (y `mke2fs` + `e2fsdroid`) empaquetados en el APK.
- Ramdisk: desempaquetar y reempaquetar el cpio (gzip/lz4) para editar `fstab` e `init`.
- Parcheo con Magisk (`magiskboot`).
