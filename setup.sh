#!/usr/bin/env bash
# =============================================================================
# setup.sh — Instala dependencias y configura el entorno inicial.
#             Ejecutar una sola vez como usuario con sudo.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=== Database Backup Setup ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Instalar dependencias del sistema
# ---------------------------------------------------------------------------
echo ">>> Instalando dependencias del sistema..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    postgresql-client \
    gzip \
    curl \
    unzip \
    ca-certificates

# ---------------------------------------------------------------------------
# 2. Instalar rclone (si no está ya)
# ---------------------------------------------------------------------------
if ! command -v rclone &>/dev/null; then
    echo ">>> Instalando rclone..."
    curl -fsSL https://rclone.org/install.sh | sudo bash
else
    echo ">>> rclone ya está instalado: $(rclone version | head -1)"
fi

# ---------------------------------------------------------------------------
# 3. Crear el directorio de backups locales
# ---------------------------------------------------------------------------
BACKUP_DIR="/var/backups/db-dumps"
echo ">>> Creando directorio de backups: ${BACKUP_DIR}"
sudo mkdir -p "$BACKUP_DIR"
sudo chown "$(whoami)":"$(whoami)" "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# 4. Crear el archivo .env a partir del ejemplo
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo ""
    echo ">>> Se creó ${ENV_FILE}"
    echo "    IMPORTANTE: Edítalo y rellena tus credenciales antes de continuar."
    echo ""
else
    echo ">>> .env ya existe, se conserva."
fi

# ---------------------------------------------------------------------------
# 5. Hacer ejecutable el script de backup
# ---------------------------------------------------------------------------
chmod +x "${SCRIPT_DIR}/backup.sh"

# ---------------------------------------------------------------------------
# 6. Instrucciones post-instalación
# ---------------------------------------------------------------------------
cat <<'EOF'

=============================================================
 SIGUIENTE PASO: Configurar rclone con Google Drive
=============================================================

Ejecuta el siguiente comando (necesitas un navegador):

    rclone config

Pasos dentro del asistente:
  1. n  → New remote
  2. Nombre: gdrive   (o el que pongas en RCLONE_REMOTE en .env)
  3. Storage type: drive  (Google Drive)
  4. Client ID / Secret: deja en blanco (usa los de rclone)
  5. scope: 1  (Full access)
  6. En "Use auto config?" — responde n si estás en un servidor sin GUI
     y sigue las instrucciones para autenticar desde otro equipo.
  7. Configure as team drive? — n (salvo que uses Shared Drive)
  8. y  → confirmar

Verifica la conexión:
    rclone lsd gdrive:

=============================================================
 EDITAR CREDENCIALES
=============================================================

    nano /home/$(whoami)/other-projects/database-downloader/.env

=============================================================
 INSTALAR EN CRON (ejemplo: cada día a las 02:00)
=============================================================

    crontab -e

Añade la línea:
    0 2 * * * /home/$(whoami)/other-projects/database-downloader/backup.sh >> /var/backups/db-dumps/backup.log 2>&1

=============================================================
 PRUEBA MANUAL
=============================================================

    /home/$(whoami)/other-projects/database-downloader/backup.sh

EOF
