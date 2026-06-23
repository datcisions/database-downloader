#!/usr/bin/env bash
# =============================================================================
# backup.sh — Descarga y comprime un dump de RDS PostgreSQL y lo sube a Drive.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Cargar configuración
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: No se encontró el archivo .env en ${SCRIPT_DIR}" >&2
    echo "       Copia .env.example a .env y rellena los valores." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# .env.local sobreescribe .env cuando existe (no se versiona en git)
ENV_LOCAL_FILE="${SCRIPT_DIR}/.env.local"
if [[ -f "$ENV_LOCAL_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_LOCAL_FILE"
fi

# ---------------------------------------------------------------------------
# Validar variables requeridas
# ---------------------------------------------------------------------------
required_vars=(DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD RCLONE_REMOTE RCLONE_DEST_PATH LOCAL_BACKUP_DIR)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: La variable ${var} no está definida en .env" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Variables derivadas
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILENAME="${DB_NAME}_${TIMESTAMP}.dump.gz"
LOCAL_DUMP_PATH="${LOCAL_BACKUP_DIR}/${DUMP_FILENAME}"
RCLONE_TARGET="${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/${DUMP_FILENAME}"
LOG_FILE="${LOCAL_BACKUP_DIR}/backup.log"

LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-3}"

# Permite que rclone encuentre su config cuando el script corre como root
# o con un usuario distinto al que ejecutó `rclone config`.
if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    export RCLONE_CONFIG
fi

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" | tee -a "$LOG_FILE"
}

notify_error() {
    local msg="$1"
    log "ERROR" "$msg"
    if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
        echo "$msg" | mail -s "[BACKUP FAILED] ${DB_NAME}" "$NOTIFY_EMAIL" 2>/dev/null || true
    fi
}

check_dependencies() {
    local missing=()
    for cmd in pg_dump gzip rclone; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        notify_error "Dependencias faltantes: ${missing[*]}. Ejecuta ./setup.sh para instalarlas."
        exit 1
    fi
}

cleanup_local() {
    log "INFO" "Limpiando dumps locales con más de ${LOCAL_RETENTION_DAYS} días..."
    find "$LOCAL_BACKUP_DIR" -name "${DB_NAME}_*.dump.gz" \
        -mtime +"${LOCAL_RETENTION_DAYS}" -delete \
        -print | while read -r f; do
            log "INFO" "Eliminado local: $(basename "$f")"
        done
}

cleanup_drive() {
    log "INFO" "Aplicando política de retención en Google Drive..."
    log "INFO" "  · <= 5 días  : todos (diario)"
    log "INFO" "  · 6-30 días  : 1 por semana"
    log "INFO" "  · 31-365 días: 1 por mes"
    log "INFO" "  · > 365 días : 1 por año"

    # Lista más reciente primero; dentro de cada período conservamos el más reciente
    local files
    files=$(rclone lsf "${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/" \
        --include "${DB_NAME}_*.dump.gz" 2>/dev/null | sort -r)

    if [[ -z "$files" ]]; then
        log "INFO" "No hay backups en Drive, nada que limpiar."
        return 0
    fi

    local now
    now=$(date +%s)

    # Registra el primer backup visto en cada semana/mes/año (el más reciente)
    declare -A seen_weeks seen_months seen_years
    local -a to_delete=()
    local kept=0

    while IFS= read -r filename; do
        [[ -z "$filename" ]] && continue

        # Extraer YYYYMMDD del nombre: DBNAME_YYYYMMDD_HHMMSS.dump.gz
        local remainder="${filename#${DB_NAME}_}"
        local datestr="${remainder:0:8}"

        if ! [[ "$datestr" =~ ^[0-9]{8}$ ]]; then
            log "WARN" "Fecha no reconocida en '${filename}', se omite."
            continue
        fi

        local file_epoch
        file_epoch=$(date -d "$datestr" +%s 2>/dev/null) || {
            log "WARN" "Fecha inválida en '${filename}', se omite."
            continue
        }

        local age_days=$(( (now - file_epoch) / 86400 ))
        local keep=false

        if [[ $age_days -le 5 ]]; then
            keep=true
        elif [[ $age_days -le 30 ]]; then
            # %G%V = año ISO + semana ISO (evita problemas en cambio de año)
            local key; key=$(date -d "$datestr" +%G%V)
            if [[ -z "${seen_weeks[$key]:-}" ]]; then
                seen_weeks[$key]=1
                keep=true
            fi
        elif [[ $age_days -le 365 ]]; then
            local key; key=$(date -d "$datestr" +%Y%m)
            if [[ -z "${seen_months[$key]:-}" ]]; then
                seen_months[$key]=1
                keep=true
            fi
        else
            local key; key=$(date -d "$datestr" +%Y)
            if [[ -z "${seen_years[$key]:-}" ]]; then
                seen_years[$key]=1
                keep=true
            fi
        fi

        if [[ "$keep" == true ]]; then
            (( kept++ )) || true
        else
            to_delete+=("$filename")
        fi
    done <<< "$files"

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        log "INFO" "Retención: ${kept} backup(s) conservado(s), ninguno eliminado."
        return 0
    fi

    for f in "${to_delete[@]}"; do
        log "INFO" "Eliminando de Drive: ${f}"
        rclone delete "${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/${f}" 2>>"$LOG_FILE"
    done

    log "INFO" "Retención aplicada: ${kept} conservado(s), ${#to_delete[@]} eliminado(s)."
}

# ---------------------------------------------------------------------------
# Inicio del backup
# ---------------------------------------------------------------------------
mkdir -p "$LOCAL_BACKUP_DIR"

log "INFO" "========================================================"
log "INFO" "Iniciando backup de ${DB_NAME} @ ${DB_HOST}"
log "INFO" "========================================================"

check_dependencies

# ---------------------------------------------------------------------------
# Dump + compresión en pipeline (sin escribir el dump sin comprimir a disco)
# ---------------------------------------------------------------------------
log "INFO" "Realizando pg_dump y comprimiendo → ${DUMP_FILENAME}"

export PGPASSWORD="$DB_PASSWORD"

# Construir flags --exclude-table-data a partir de la lista en .env
declare -a exclude_data_flags=()
if [[ -n "${EXCLUDE_TABLE_DATA:-}" ]]; then
    IFS=',' read -ra _tables <<< "$EXCLUDE_TABLE_DATA"
    for _table in "${_tables[@]}"; do
        _table="${_table// /}"   # eliminar espacios accidentales
        [[ -n "$_table" ]] && exclude_data_flags+=("--exclude-table-data=${_table}")
    done
    log "INFO" "Tablas exportadas sin datos: ${EXCLUDE_TABLE_DATA}"
fi

if ! pg_dump \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --username="$DB_USER" \
    --dbname="$DB_NAME" \
    --no-password \
    --format=plain \
    --no-owner \
    --no-privileges \
    "${exclude_data_flags[@]+"${exclude_data_flags[@]}"}" \
    2>>"$LOG_FILE" \
    | gzip --best > "$LOCAL_DUMP_PATH"; then
    notify_error "pg_dump falló para ${DB_NAME}. Revisa ${LOG_FILE}."
    rm -f "$LOCAL_DUMP_PATH"
    exit 1
fi

unset PGPASSWORD

DUMP_SIZE="$(du -sh "$LOCAL_DUMP_PATH" | cut -f1)"
log "INFO" "Dump completado: ${DUMP_FILENAME} (${DUMP_SIZE})"

# ---------------------------------------------------------------------------
# Subir a Google Drive
# ---------------------------------------------------------------------------
log "INFO" "Subiendo a Google Drive → ${RCLONE_TARGET}"

if ! rclone copy "$LOCAL_DUMP_PATH" "${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/" \
    --progress \
    --stats-one-line \
    2>>"$LOG_FILE"; then
    notify_error "rclone falló al subir ${DUMP_FILENAME} a Drive."
    exit 1
fi

log "INFO" "Subida completada."

# ---------------------------------------------------------------------------
# Limpieza
# ---------------------------------------------------------------------------
cleanup_local
cleanup_drive

log "INFO" "Backup finalizado con éxito: ${DUMP_FILENAME}"
