Binarios de Android empaquetados como `lib<herramienta>.so` (los puntos del nombre pasan a `_`).
Android 10+ solo permite ejecutar binarios desde el directorio de librerías nativas de la app;
la app los busca ahí automáticamente.

`arm64-v8a/` lo genera `tool/build_android_tools.sh <NDK>` (también lo hace CI):
erofs-utils oficial (kernel.org, v1.9.4) + lz4 v1.10.0, compilados con el NDK (API 29).

| Archivo                | Herramienta  | Uso en la app                                             |
|------------------------|--------------|-----------------------------------------------------------|
| libmkfs_erofs.so       | mkfs.erofs   | Construir EROFS (`--tar=f` con metadatos Android en PAX)  |
| libfsck_erofs.so       | fsck.erofs   | Extraer datos de EROFS (metadatos: lector en Dart)        |
| libdump_erofs.so       | dump.erofs   | Diagnóstico                                               |

Se pueden añadir otros (p. ej. `libmke2fs_android.so`, `libe2fsdroid.so` para ext4)
con el mismo esquema de nombres.
