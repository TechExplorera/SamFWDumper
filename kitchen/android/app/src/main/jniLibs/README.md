Coloca aquí los binarios de Android (ARM64, enlazados estáticamente) con nombre `lib<herramienta>.so`,
sustituyendo los puntos por guiones bajos:

| Herramienta      | Archivo                          |
|------------------|----------------------------------|
| extract.erofs    | arm64-v8a/libextract_erofs.so    |
| mkfs.erofs       | arm64-v8a/libmkfs_erofs.so       |
| mke2fs.android   | arm64-v8a/libmke2fs_android.so   |
| e2fsdroid        | arm64-v8a/libe2fsdroid.so        |

Android 10+ solo permite ejecutar binarios desde el directorio de librerías nativas de la app,
por eso se empaquetan así. La app los busca en `nativeLibraryDir` automáticamente.
