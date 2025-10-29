#!/usr/bin/env bash
set -euo pipefail
set -x

# build_in_container.sh (usar con image public.ecr.aws/lambda/python:3.12)
# Monta repo en /workspace y out en /out
WORKSPACE="/workspace"
OUT="/out"
WHEELHOUSE="${WORKSPACE}/wheelhouse"
REQ="${WORKSPACE}/requirements.txt"
LOG="${OUT}/build.log"

mkdir -p "$OUT"
: > "$LOG"

echo "Build script start: $(date)" | tee -a "$LOG"

# Instalar utilidades y paquetes base (tolerante a fallos)
echo "Installing base packages..." | tee -a "$LOG"
# En la imagen lambda: usar yum (amazon linux)
yum -y update || true
yum -y install -y which findutils tar xz unzip curl fontconfig freetype freetype-devel glibc-langpack-en || true

# Paquetes recomendados para Chromium
yum -y install -y nspr nss nss-util dbus-glib atk at-spi2-atk expat cairo libX11 libXcomposite libXcursor libXdamage libXrandr libXtst libXrender libXfixes libXext libXScrnSaver libxcb libxshmfence libxkbcommon mesa-libgbm libdrm alsa-lib gtk3 pango cups-libs || true

# Detectar python 3.12 disponible en la imagen
PY_CMD=""
if command -v python3.12 >/dev/null 2>&1; then
  PY_CMD=python3.12
elif command -v python3 >/dev/null 2>&1; then
  # comprobar que python3 es 3.12
  VER=$((python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")') 2>/dev/null || echo "")
  if [ "$VER" = "3.12" ]; then
    PY_CMD=python3
  fi
fi

if [ -z "${PY_CMD}" ]; then
  echo "ERROR: python 3.12 no disponible en el contenedor. Se requiere Python 3.12." | tee -a "$LOG"
  exit 2
fi

echo "Using Python command: $PY_CMD" | tee -a "$LOG"
PYVER=$($PY_CMD -c 'import sys; v=sys.version_info; print("%d.%d" % (v.major, v.minor))')
echo "Detected python version: $PYVER" | tee -a "$LOG"

OUT_SITE="$OUT/python/lib/python${PYVER}/site-packages"
mkdir -p "$OUT_SITE"
chmod -R a+rwX "$OUT_SITE"

# Asegurar pip
$PY_CMD -m ensurepip --upgrade || true
if ! $PY_CMD -m pip --version >/dev/null 2>&1; then
  curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py || true
  $PY_CMD /tmp/get-pip.py || true
fi
$PY_CMD -m pip install --upgrade pip setuptools wheel || true

# Instalar wheels del wheelhouse si existen (opcional)
if [ -f "$REQ" ] && [ -d "$WHEELHOUSE" ]; then
  echo "Installing requirements from wheelhouse into $OUT_SITE" | tee -a "$LOG"
  $PY_CMD -m pip install --no-index --find-links="$WHEELHOUSE" --no-deps --target="$OUT_SITE" -r "$REQ" || true
fi

echo "Instalando dependencias del sistema requeridas por Chromium (yum)..." | tee -a "$LOG"

# Lista recomendada de paquetes para Amazon Linux / Lambda (AL2023)
# Nota: algunos paquetes pueden ya estar instalados; usamos -y y toleramos fallos.
yum -y update || true
yum -y install -y \
  alsa-lib \
  atk \
  at-spi2-atk \
  dbus-glib \
  cups-libs \
  freetype \
  fontconfig \
  gtk3 \
  libX11 \
  libXcomposite \
  libXcursor \
  libXdamage \
  libXrandr \
  libXtst \
  libXrender \
  libXfixes \
  libXext \
  libXScrnSaver || true \
  libxcb \
  libxshmfence \
  libxkbcommon \
  mesa-libgbm \
  libdrm \
  nspr \
  nss \
  nss-util \
  systemd-libs \
  pango \
  cairo \
  alsa-lib \
  pulseaudio-libs || true

# También instalamos utilidades que Playwright usa al descargar
yum -y install -y curl tar gzip unzip xz || true

echo "Dependencias del sistema instaladas (o intentadas). Reintentando instalación de navegadores..." | tee -a "$LOG"

# Evitar que Playwright intente ejecutar apt-get como fallback (si aún así lo hace)
export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

# Crear directorio para configuraciones adicionales
mkdir -p "$OUT/etc"
mkdir -p "$OUT/sandbox"

# Configurar variables de entorno críticas para Lambda
cat > "$OUT/lambda_env.sh" << 'EOF'
#!/bin/bash
# Variables de entorno para Lambda
export PLAYWRIGHT_BROWSERS_PATH=/opt/.cache/ms-playwright
export LD_LIBRARY_PATH=/opt/lib:/var/lang/lib:/lib64:/usr/lib64:/var/runtime:/var/runtime/lib:/var/task:/var/task/lib
export FONTCONFIG_PATH=/etc/fonts
export FONTCONFIG_FILE=/etc/fonts/fonts.conf
export FONTCONFIG_SYSROOT=/opt
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=true
# Deshabilitar completamente la validación de sandbox
export PLAYWRIGHT_DISABLE_SANDBOX=1
export QTWEBENGINE_DISABLE_SANDBOX=1
EOF

chmod +x "$OUT/lambda_env.sh"

# Crear un script de diagnóstico mejorado
cat > "$OUT/diagnose_chromium.sh" << 'EOF'
#!/bin/bash
echo "=== Chromium Diagnosis ==="
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "PLAYWRIGHT_BROWSERS_PATH: $PLAYWRIGHT_BROWSERS_PATH"

# Buscar chromium
find /opt -name "chrome" -o -name "chromium" -o -name "headless_shell" 2>/dev/null | while read bin; do
  echo "Found: $bin"
  if [ -x "$bin" ]; then
    echo "  Executable: YES"
    echo "  Version attempt:"
    $bin --version 2>&1 | head -1 || echo "  Failed to get version"
  else
    echo "  Executable: NO"
    chmod +x "$bin" 2>/dev/null && echo "  Fixed permissions" || echo "  Could not fix permissions"
  fi
  echo "  LDD output:"
  ldd "$bin" 2>&1 | grep -E "not found|=>" | head -10
  echo "---"
done

echo "=== Library check ==="
find /opt/lib -name "*.so*" 2>/dev/null | wc -l | xargs echo "Total .so files in /opt/lib:"
EOF

chmod +x "$OUT/diagnose_chromium.sh"

# Usamos el python apropiado (PY_CMD ya definido) y PYTHONPATH apuntando al target site-packages
# Ejecutar instalación de navegadores SIN --with-deps (ya instalamos deps con yum)
PYTHONPATH="$PYTHONPATH" PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
  $PY_CMD -m playwright install chromium 2>&1 | tee /tmp/playwright-install.log || true

# Copiar log y navegadores a /out
cp -v /tmp/playwright-install.log "$OUT/" || true
mkdir -p "$OUT/.cache/ms-playwright"
cp -a /tmp/ms-playwright/* "$OUT/.cache/ms-playwright/" 2>/dev/null || true

# Instalar playwright en el target site-packages
echo "Installing playwright into $OUT_SITE" | tee -a "$LOG"
$PY_CMD -m pip install --no-deps --upgrade playwright --target="$OUT_SITE" || true

# Exportar paths para que python use el target
export PYTHONPATH="$OUT_SITE"
# Usar ruta clara para navegadores
export PLAYWRIGHT_BROWSERS_PATH="/tmp/ms-playwright"

echo "PYTHONPATH=$PYTHONPATH" | tee -a "$LOG"
echo "PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWS_PATH" | tee -a "$LOG" || true

# Instalar navegadores (se descargarán en /tmp/ms-playwright)
echo "Running: $PY_CMD -m playwright install --with-deps chromium (log -> /tmp/playwright-install.log)" | tee -a "$LOG"
PYTHONPATH="$PYTHONPATH" PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" $PY_CMD -m playwright install --with-deps chromium 2>&1 | tee /tmp/playwright-install.log || true
cp -v /tmp/playwright-install.log "$OUT/" || true

# Copiar navegadores a out para empaquetar
mkdir -p "$OUT/.cache/ms-playwright"
cp -a /tmp/ms-playwright/* "$OUT/.cache/ms-playwright/" 2>/dev/null || true

# Buscar binario headless_shell / chrome
echo "Searching for headless binary..." | tee -a "$LOG"
HEADLESS_BIN="$(find "$OUT" -type f -name headless_shell -print -quit || true)"
if [ -z "$HEADLESS_BIN" ]; then
  HEADLESS_BIN="$(find "$OUT" -type f \( -name chrome -o -name chromium \) -print -quit || true)"
fi
echo "HEADLESS_BIN=${HEADLESS_BIN}" | tee -a "$LOG"
echo "HEADLESS_BIN=${HEADLESS_BIN}" > "$OUT/build-info.txt"

if [ -z "$HEADLESS_BIN" ]; then
  echo "ERROR: headless binary not found in /out/.cache/ms-playwright. Check /out/playwright-install.log" | tee -a "$LOG"
  exit 0
fi

# Ejecutar ldd sobre el binario y guardar salida
echo "Running ldd on $HEADLESS_BIN" | tee -a "$LOG"
ldd "$HEADLESS_BIN" > "$OUT/ldd-headless.txt" 2>&1 || true
grep -E "=> not found|not found" "$OUT/ldd-headless.txt" > "$OUT/ldd-missing.txt" || true

# Extraer nombres de .so y guardarlos
LIBS=$(awk '{ for(i=1;i<=NF;i++) if($i ~ /\.so/) print $i }' "$OUT/ldd-headless.txt" | sed 's/,//g' | sed 's/.*\///' | sort -u)
echo "$LIBS" > "$OUT/ldd-libs.txt"
echo "Referenced libs saved to $OUT/ldd-libs.txt" | tee -a "$LOG"

# Función para copiar librerías por nombre (incluye glob de versiones)
copy_lib() {
  local name="$1"
  for p in /usr/lib64 /usr/lib /lib64 /lib /opt/lib64 /usr/lib/x86_64-linux-gnu; do
    if [ -f "$p/$name" ]; then
      cp -v "$p/$name" "$OUT/lib64/" && return 0
    fi
    for f in "$p/$name"*; do
      [ -e "$f" ] || continue
      cp -v "$f" "$OUT/lib64/" && return 0
    done
  done
  echo "WARN: $name not found in standard paths" >> "$OUT/ldd-missing.txt"
  return 1
}

mkdir -p "$OUT/lib64"
chmod -R a+rwX "$OUT/lib64"

# Copiar todas las librerías listadas por ldd
echo "Copying referenced libs to $OUT/lib64" | tee -a "$LOG"
for lib in $LIBS; do
  case "$lib" in
    linux-vdso*|ld-linux*|ld64.so*) continue ;;
  esac
  copy_lib "$lib" || true
done

# Intentar también copiar los nombres que aparecieron como 'not found'
if [ -s "$OUT/ldd-missing.txt" ]; then
  awk '{ if ($0 ~ /not found/) { for(i=1;i<=NF;i++) if($i ~ /\.so/) print $i } }' "$OUT/ldd-missing.txt" | sed 's/,//g' | sed 's/.*\///' | sort -u > "$OUT/ldd-missing-names.txt" || true
  for lib in $(cat "$OUT/ldd-missing-names.txt" 2>/dev/null || true); do
    copy_lib "$lib" || true
  done
fi

# Copiar targets reales de symlinks
for f in "$OUT/lib64"/*; do
  [ -e "$f" ] || continue
  if [ -L "$f" ]; then
    real=$(readlink -f "$f" || true)
    if [ -n "$real" ] && [ -f "$real" ]; then
      cp -v "$real" "$OUT/lib64/" || true
    fi
  fi
done

# Guardar logs finales y permisos
cp -v /tmp/playwright-install.log "$OUT/" 2>/dev/null || true
chmod -R a+rwX "$OUT" || true
echo "Build finished: $(date)" | tee -a "$LOG"

# Verificación final y creación de archivo de configuración
echo "=== Final setup ==="

# Crear un archivo de configuración para Lambda
cat > "$OUT/chromium-config.json" << EOF
{
  "chromium_args": [
    "--no-sandbox",
    "--disable-setuid-sandbox", 
    "--disable-seccomp-filter-sandbox",
    "--disable-namespace-sandbox",
    "--disable-custom-sandbox",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--single-process",
    "--no-zygote",
    "--no-first-run",
    "--headless=new",
    "--remote-debugging-port=0",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-features=VizDisplayCompositor,AudioServiceOutOfProcess,Translate",
    "--disk-cache-dir=/tmp/chromium-cache",
    "--user-data-dir=/tmp/chromium-user-data"
  ],
  "environment": {
    "ld_library_path": "/opt/lib:/var/lang/lib:/lib64:/usr/lib64:/var/runtime:/var/runtime/lib:/var/task:/var/task/lib",
    "playwright_browsers_path": "/opt/.cache/ms-playwright",
    "fontconfig_path": "/etc/fonts"
  }
}
EOF

echo "Final setup completed at: $(date)" | tee -a "$LOG"

exit 0