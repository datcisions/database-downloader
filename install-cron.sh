#!/usr/bin/env bash
# =============================================================================
# install-cron.sh — Instala la entrada cron para backup automático.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"
LOG_FILE="/var/backups/db-dumps/backup.log"

# Hora de ejecución configurable vía argumentos (defecto: 02:00)
CRON_HOUR="${1:-2}"
CRON_MINUTE="${2:-0}"

CRON_EXPR="${CRON_MINUTE} ${CRON_HOUR} * * *"
CRON_JOB="${CRON_EXPR} ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1"

echo ">>> Instalando cron job: \"${CRON_JOB}\""

# Añade la entrada solo si no existe ya
( crontab -l 2>/dev/null | grep -vF "$BACKUP_SCRIPT"; echo "$CRON_JOB" ) | crontab -

echo ">>> Cron instalado. Lista actual:"
crontab -l

echo ""
echo "Para cambiar la hora: ./install-cron.sh <hora> <minuto>"
echo "Ejemplo (03:30):      ./install-cron.sh 3 30"
