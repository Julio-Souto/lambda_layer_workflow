#!/usr/bin/env bash
set -euo pipefail
set -x

# build_in_container.sh
# Ejecutar dentro de public.ecr.aws/amazonlinux/amazonlinux:2023 con el repo montado en /workspace
# Monta /out en el contenedor (directorio de salida).
#
# Uso (ejemplo desde runner):
# docker run --rm -v "$PWD":/workspace -v "$PWD/out":/out -w /workspace public.ecr.aws/amazonlinux/amazonlinux:2023 \
#    /bin/bash /workspace/build_in_container.sh

WORKSPACE="/workspace"
OUT="/out"
WHEELHOUSE="${WORKSPACE}/wheelhouse"
REQ="${WORKSPACE}/requirements.txt"
LOG="${OUT}/build.log"

mkdir -p "$OUT"
: > "$LOG"

echo "Build script start: $(date)" | tee -a "$LOG"

# 1) Instalar utilidades y paquetes base (tolerante a fallos)
echo "Instalando paquetes base..." | tee -a "$LOG"
dnf -y update || true
dnf -y install -y \
  which findutils tar xz unzip curl git gzip bzip2 fontconfig freetype freetype-devel glibc-langpack-en \
  python3 python3-pip python3-devel make automake autoconf pkgconfig || true

# 2) Paquetes que suelen proporcionar las .so necesarias para Chromium
#    Incluye systemd-libs (libsystemd.so.0) y NSS/NSPR, GTK, mesa, ALSA, etc.
echo "Instalando librerías del sistema requeridas (intentando cubrir la mayoría)..." | tee -a "$LOG"
dnf -y install -y \
  nspr nss nss-util nss-softokn-freebl nss-tools \
  systemd-libs \
  dbus-glib dbus-libs \
  atk atk-devel at-spi2-atk at-spi2-core \
  cairo cairo-gobject \
  pango pango-devel pangox-compat \
  gtk3 gtk3-devel \
  libX11 libX11-devel libXrandr libXrandr-devel libXrender libXrender-devel \
  libXext libXext-devel libXcomposite libXcomposite-devel libXcursor libXcursor-devel libXdamage libXdamage-devel \
  libXfixes libXfixes-devel libXtst libXtst-devel libXScrnSaver \
  libxcb libxcb-devel libxkbcommon libxkbcommon-devel \
  mesa-libgbm libdrm \
  alsa-lib alsa-lib-devel \
  pulseaudio-libs pulseaudio-libs-devel \
  fontconfig fontconfig-devel freetype freetype-devel \
  cups-libs \
  expat expat-devel \
  libudev libudev-devel \
  libSM libSM-deprecated || true

# 3) Preparar python target (coincidente con python dentro del contenedor)
PYVER=$(python3 -c 'import sys; v=sys.version_info; print("%d.%d" % (v.major, v.minor))')
OUT_SITE="$OUT/python/lib/python${PYVER}/site-packages"
mkdir -p "$OUT_SITE"
chmod -R a+rwX "$OUT_SITE"
echo "PYVER=$PYVER OUT_SITE=$OUT_SITE" | tee -a "$LOG"

# 4) Asegurar pip y wheels desde wheelhouse (si existen)
python3 -m ensurepip --upgrade || true
if ! python3 -m pip --version >/dev/null 2>&1; then
  curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py || true
  python3 /tmp/get-pip.py || true
fi
python3 -m pip install --upgrade pip setuptools wheel || true

if [ -f "$REQ" ] && [ -d "$WHEELHOUSE" ]; then
  echo "Instalando requirements desde wheelhouse en $OUT_SITE" | tee -a "$LOG"
  python3 -m pip install --no-index --find-links="$WHEELHOUSE" --no-deps --target="$OUT_SITE" -r "$REQ" || true
fi

# 5) Instalar playwright en el target para que el python dentro del contenedor lo pueda instalar/usar
echo "Instalando playwright en $OUT_SITE" | tee -a "$LOG"
python3 -m pip install --no-deps --upgrade playwright --target="$OUT_SITE" || true

# 6) Ejecutar playwright install para descargar navegadores a /tmp (luego copiaremos)
export PYTHONPATH="$OUT_SITE"
export PLAYWRIGHT_BROWSERS_PATH="/tmp/ms-playwright"
echo "PYTHONPATH=$PYTHONPATH" | tee -a "$LOG"
echo "PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWS_PATH" | tee -a "$LOG" || true

echo "Ejecutando playwright install --with-deps chromium (log en /tmp/playwright-install.log)" | tee -a "$LOG"
PYTHONPATH="$PYTHONPATH" PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWS_PATH" \
  python3 -m playwright install --with-deps chromium 2>&1 | tee /tmp/playwright-install.log || true
cp -v /tmp/playwright-install.log "$OUT/" || true

# 7) Copiar los navegadores instalados a /out/.cache/ms-playwright
mkdir -p "$OUT/.cache/ms-playwright"
cp -a /tmp/ms-playwright/* "$OUT/.cache/ms-playwright/" 2>/dev/null || true

# 8) Localizar binario headless/chrome
echo "Buscando binario headless_shell / chrome ..." | tee -a "$LOG"
HEADLESS_BIN="$(find "$OUT" -type f -name headless_shell -print -quit || true)"
if [ -z "$HEADLESS_BIN" ]; then
  HEADLESS_BIN="$(find "$OUT" -type f \( -name chrome -o -name chromium \) -print -quit || true)"
fi
echo "HEADLESS_BIN=${HEADLESS_BIN}" | tee -a "$LOG"
echo "HEADLESS_BIN=${HEADLESS_BIN}" > "$OUT/build-info.txt"

if [ -z "$HEADLESS_BIN" ]; then
  echo "ERROR: no se encontró binario headless_shell/chrome en /out/.cache/ms-playwright" | tee -a "$LOG"
  echo "Revisa /tmp/playwright-install.log" | tee -a "$LOG"
  exit 0
fi

# 9) Ejecutar ldd y detectar .so referenciadas y 'not found'
echo "Ejecutando ldd sobre $HEADLESS_BIN" | tee -a "$LOG"
ldd "$HEADLESS_BIN" > "$OUT/ldd-headless.txt" 2>&1 || true
grep -E "=> not found|not found" "$OUT/ldd-headless.txt" > "$OUT/ldd-missing.txt" || true

# 10) Extraer nombres de .so referenciadas (tokens que contienen .so)
LIBS=$(awk '{ for(i=1;i<=NF;i++) if($i ~ /\.so/) print $i }' "$OUT/ldd-headless.txt" | sed 's/,//g' | sed 's/.*\///' | sort -u)
echo "Librerías referenciadas por ldd:" | tee -a "$LOG"
echo "$LIBS" | tee -a "$LOG"
echo "$LIBS" > "$OUT/ldd-libs.txt"

# 11) Función copiar librería por nombre (busca variantes versionadas también)
copy_lib() {
  local name="$1"
  for p in /usr/lib64 /usr/lib /lib64 /lib /opt/lib64 /usr/lib/x86_64-linux-gnu; do
    if [ -f "$p/$name" ]; then
      cp -v "$p/$name" "$OUT/lib64/" && return 0
    fi
    # glob para versiones (libfoo.so.1, libfoo.so.1.2.3, ...)
    for f in "$p/$name"*; do
      [ -e "$f" ] || continue
      cp -v "$f" "$OUT/lib64/" && return 0
    done
  done
  echo "WARN: $name no encontrado en rutas estándar" >> "$OUT/ldd-missing.txt"
  return 1
}

mkdir -p "$OUT/lib64"
chmod -R a+rwX "$OUT/lib64"

# 12) Copiar todas las librerías listadas por ldd
echo "Copiando librerías referenciadas a $OUT/lib64" | tee -a "$LOG"
for lib in $LIBS; do
  case "$lib" in
    linux-vdso*|ld-linux*|ld64.so*) continue ;;
  esac
  copy_lib "$lib" || true
done

# 13) También leer explicit 'not found' tokens e intentar copiar esas si nombre aparece
if [ -s "$OUT/ldd-missing.txt" ]; then
  echo "Procesando entradas 'not found'..." | tee -a "$LOG"
  awk '{ if ($0 ~ /not found/) { for(i=1;i<=NF;i++) if($i ~ /\.so/) print $i } }' "$OUT/ldd-missing.txt" | sed 's/,//g' | sed 's/.*\///' | sort -u > "$OUT/ldd-missing-names.txt" || true
  for lib in $(cat "$OUT/ldd-missing-names.txt" 2>/dev/null || true); do
    copy_lib "$lib" || true
  done
fi

# 14) Copiar targets reales de symlinks para completitud
echo "Copiando targets reales de cualquier symlink copiado" | tee -a "$LOG"
for f in "$OUT/lib64"/*; do
  [ -e "$f" ] || continue
  if [ -L "$f" ]; then
    real=$(readlink -f "$f" || true)
    if [ -n "$real" ] && [ -f "$real" ]; then
      cp -v "$real" "$OUT/lib64/" || true
    fi
  fi
done

# 15) Guardar logs y ajustar permisos
echo "Guardando logs y fijando permisos finales" | tee -a "$LOG"
cp -v /tmp/playwright-install.log "$OUT/" 2>/dev/null || true
chmod -R a+rwX "$OUT" || true

echo "Build script finished: $(date)" | tee -a "$LOG"
exit 0