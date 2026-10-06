#!/usr/bin/env bash
# =============================================================================
# odoo-prod2local.sh — copia una BBDD Odoo (Doodba + docker compose) de un servidor
# remoto a tu entorno local por SSH. Opcionalmente trae también el filestore.
#
# Todo lo específico de cada proyecto (host, rutas, claves, hooks) vive en un
# fichero conf/<proyecto>.conf. Este script no contiene datos de ningún proyecto.
#
# Etapas: dump remoto -> descarga -> restore local -> [filestore] -> update
#         -> neutralize/scripts/módulos -> arrancar -> rotar backups
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${odoo-prod2local_CONF_DIR:-$SCRIPT_DIR/conf}"

log()  { printf '[%s] [+] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] [!] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] [!] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
trap 'die "falló la línea $LINENO: $BASH_COMMAND"' ERR

usage() {
    cat <<EOF
Uso: ${0##*/} <proyecto|ruta.conf> [opciones]

  -f, --filestore     traer también el filestore (rsync). Por defecto NO.
      --no-update     saltar click-odoo-update --update-all
      --no-neutralize saltar 'odoo neutralize'
  -n, --dry-run       mostrar qué haría con esa configuración y salir
  -l, --list          listar proyectos disponibles en $CONF_DIR
  -h, --help          esta ayuda

Configuraciones en: $CONF_DIR   (cámbialo con odoo-prod2local_CONF_DIR)
Nuevo proyecto:     cp conf/_example.conf conf/miproyecto.conf && chmod 600 conf/miproyecto.conf
EOF
}

list_projects() {
    local f
    for f in "$CONF_DIR"/*.conf; do
        [[ -e $f && $(basename "$f") != _* ]] && basename "$f" .conf
    done
    return 0
}

# -----------------------------------------------------------------------------
# Valores por defecto (el .conf los sobreescribe)
# -----------------------------------------------------------------------------
SSH_PORT=22
SSH_KEY=""            # si se define, se usa clave privada
SSH_PASS=""           # si no hay clave: password (vía sshpass)
SSH_PASS_CMD=""       # alternativa a SSH_PASS: comando que imprime el password

REMOTE_COMPOSE_BIN="docker compose"
REMOTE_COMPOSE_FILE="prod.yaml"
REMOTE_SERVICE="odoo"
REMOTE_DB="prod"
REMOTE_FILESTORE=""
REMOTE_RSYNC_SUDO=false   # true si el filestore remoto solo lo lee root

LOCAL_COMPOSE_BIN="docker compose"
LOCAL_COMPOSE_FILE="devel.yaml"
LOCAL_SERVICE="odoo"
LOCAL_DB="devel"
LOCAL_FILESTORE=""
LOCAL_RSYNC_SUDO=true     # el volumen docker local suele requerir root

DUMP_FORMAT="dir"         # dir = pg_dump -Fd + pg_restore | sql = pg_dump plano + psql
JOBS=8
COMPRESS_LEVEL=5          # solo formato dir
PG_DUMP_OPTS=""
PG_RESTORE_OPTS=""

RUN_UPDATE=true
NEUTRALIZE=true
POST_SCRIPTS=()           # scripts python (odoo shell), relativos a LOCAL_DOCKER_PATH
POST_MODULES=()           # módulos a instalar (-i)
KEEP=2                    # backups a conservar (remoto y local)
BACKUP_TAG=""             # por defecto, el nombre del proyecto

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------
PROJECT_ARG=""; OPT_FILESTORE=""; OPT_UPDATE=""; OPT_NEUTRALIZE=""; DRY_RUN=false
while (($#)); do
    case "$1" in
        -f|--filestore)   OPT_FILESTORE=true ;;
        --no-update)      OPT_UPDATE=false ;;
        --no-neutralize)  OPT_NEUTRALIZE=false ;;
        -n|--dry-run)     DRY_RUN=true ;;
        -l|--list)        list_projects; exit 0 ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die "Opción desconocida: $1 (usa --help)" ;;
        *) [[ -z $PROJECT_ARG ]] || die "Solo se admite un proyecto"; PROJECT_ARG=$1 ;;
    esac
    shift
done
[[ -n $PROJECT_ARG ]] || { usage; exit 1; }
[[ $(id -u) != 0 ]] || die "No ejecutar como root."

# -----------------------------------------------------------------------------
# Carga y validación de la configuración
# -----------------------------------------------------------------------------
load_config() {
    if   [[ -f $PROJECT_ARG ]];                then CONF_FILE=$(realpath "$PROJECT_ARG")
    elif [[ -f $CONF_DIR/$PROJECT_ARG.conf ]]; then CONF_FILE="$CONF_DIR/$PROJECT_ARG.conf"
    else die "No existe la configuración '$PROJECT_ARG' en $CONF_DIR (usa --list)"
    fi
    PROJECT=$(basename "$CONF_FILE" .conf)

    local perm; perm=$(stat -c '%a' "$CONF_FILE")
    [[ ${perm: -2} == 00 ]] || die "$CONF_FILE tiene permisos $perm; ejecuta: chmod 600 $CONF_FILE"

    # shellcheck disable=SC1090
    source "$CONF_FILE"

    [[ -n $OPT_FILESTORE ]]   && COPY_FILESTORE=$OPT_FILESTORE || COPY_FILESTORE=false
    [[ -n $OPT_UPDATE ]]      && RUN_UPDATE=$OPT_UPDATE
    [[ -n $OPT_NEUTRALIZE ]]  && NEUTRALIZE=$OPT_NEUTRALIZE
    BACKUP_TAG="${BACKUP_TAG:-$PROJECT}"

    local v req=(SSH_HOST SSH_USER REMOTE_DOCKER_PATH REMOTE_BACKUP_DIR LOCAL_DOCKER_PATH LOCAL_BACKUP_DIR)
    [[ $COPY_FILESTORE == true ]] && req+=(REMOTE_FILESTORE LOCAL_FILESTORE)
    for v in "${req[@]}"; do [[ -n ${!v:-} ]] || die "Falta $v en $CONF_FILE"; done

    [[ $REMOTE_BACKUP_DIR == /* ]] || die "REMOTE_BACKUP_DIR debe ser una ruta absoluta"
    [[ $DUMP_FORMAT == dir || $DUMP_FORMAT == sql ]] || die "DUMP_FORMAT debe ser 'dir' o 'sql'"
    [[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "KEEP debe ser un entero >= 1"
    [[ -d $LOCAL_DOCKER_PATH ]] || die "No existe LOCAL_DOCKER_PATH: $LOCAL_DOCKER_PATH"
    [[ -f $LOCAL_DOCKER_PATH/$LOCAL_COMPOSE_FILE ]] || die "No existe $LOCAL_DOCKER_PATH/$LOCAL_COMPOSE_FILE"

    TS=$(date +%Y-%m-%d_%H-%M)
    BACKUP_NAME="${TS}_${BACKUP_TAG}"
    if [[ $DUMP_FORMAT == dir ]]; then ITEM="$BACKUP_NAME"; else ITEM="$BACKUP_NAME.sql"; fi
    ARCHIVE="$BACKUP_NAME.tar.gz"
}

# -----------------------------------------------------------------------------
# SSH: clave privada o password (sshpass -e, sin exponerlo en `ps`)
# -----------------------------------------------------------------------------
setup_ssh() {
    SSH_PREFIX=()
    SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
    if [[ -n $SSH_KEY ]]; then
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
        [[ -r $SSH_KEY ]] || die "No se puede leer SSH_KEY: $SSH_KEY"
        SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    elif [[ -n $SSH_PASS_CMD || -n $SSH_PASS ]]; then
        command -v sshpass >/dev/null || die "Falta sshpass (o usa SSH_KEY)"
        if [[ -n $SSH_PASS_CMD ]]; then SSH_PASS=$(eval "$SSH_PASS_CMD"); fi
        export SSHPASS="$SSH_PASS"
        SSH_PREFIX=(sshpass -e)
    fi
    printf -v RSYNC_SSH '%q ' ssh -p "$SSH_PORT" "${SSH_OPTS[@]}"
}

remote()   { "${SSH_PREFIX[@]}" ssh -T -p "$SSH_PORT" "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "$@"; }
lcompose() { ( trap - ERR; cd "$LOCAL_DOCKER_PATH" && $LOCAL_COMPOSE_BIN -f "$LOCAL_COMPOSE_FILE" "$@" ); }

resolve_local() { [[ $1 == /* ]] && echo "$1" || echo "$LOCAL_DOCKER_PATH/$1"; }

print_summary() {
    cat <<EOF
================================================================
  odoo-prod2local  |  $PROJECT
================================================================
  Remoto : $SSH_USER@$SSH_HOST:$SSH_PORT  ($REMOTE_DOCKER_PATH, $REMOTE_COMPOSE_FILE, db=$REMOTE_DB)
  Local  : $LOCAL_DOCKER_PATH  ($LOCAL_COMPOSE_FILE, db=$LOCAL_DB)
  Auth   : $([[ -n $SSH_KEY ]] && echo "clave $SSH_KEY" || { [[ -n $SSH_PASS || -n $SSH_PASS_CMD ]] && echo "password (sshpass)" || echo "ssh por defecto (agente/claves)"; })
  Dump   : $DUMP_FORMAT   ->  $LOCAL_BACKUP_DIR/$ARCHIVE
  Filestore: $COPY_FILESTORE   Update-all: $RUN_UPDATE   Neutralize: $NEUTRALIZE
  Scripts: ${POST_SCRIPTS[*]:-(ninguno)}
  Módulos: ${POST_MODULES[*]:-(ninguno)}
  Rotación: KEEP=$KEEP
================================================================
EOF
}

preflight() {
    local c
    for c in ssh scp tar; do command -v "$c" >/dev/null || die "Falta $c"; done
    command -v "${LOCAL_COMPOSE_BIN%% *}" >/dev/null || die "Falta ${LOCAL_COMPOSE_BIN%% *}"
    [[ $COPY_FILESTORE == true ]] && { command -v rsync >/dev/null || die "Falta rsync"; }
    log "Comprobando conexión SSH..."
    remote true || die "No se puede conectar a $SSH_USER@$SSH_HOST:$SSH_PORT"
}

# -----------------------------------------------------------------------------
# Etapas
# -----------------------------------------------------------------------------
remote_dump() {
    log "Dump remoto de '$REMOTE_DB' (formato $DUMP_FORMAT)..."
    # </dev/null en docker: evita que 'run' se coma el resto del script por stdin
    if [[ $DUMP_FORMAT == dir ]]; then
        remote bash -s <<EOF
set -euo pipefail
mkdir -p "$REMOTE_BACKUP_DIR"
cd "$REMOTE_DOCKER_PATH"
$REMOTE_COMPOSE_BIN -f "$REMOTE_COMPOSE_FILE" run --rm -T -v "$REMOTE_BACKUP_DIR:/backup" $REMOTE_SERVICE pg_dump $PG_DUMP_OPTS -Fd -j $JOBS -Z $COMPRESS_LEVEL -f "/backup/$ITEM" "$REMOTE_DB" </dev/null
cd "$REMOTE_BACKUP_DIR"
tar -czf "$ARCHIVE" "$ITEM"
rm -rf "$ITEM"
EOF
    else
        remote bash -s <<EOF
set -euo pipefail
mkdir -p "$REMOTE_BACKUP_DIR"
cd "$REMOTE_DOCKER_PATH"
$REMOTE_COMPOSE_BIN -f "$REMOTE_COMPOSE_FILE" run --rm -T $REMOTE_SERVICE pg_dump $PG_DUMP_OPTS "$REMOTE_DB" </dev/null | grep -v "doodba INFO:" > "$REMOTE_BACKUP_DIR/$ITEM"
cd "$REMOTE_BACKUP_DIR"
tar -czf "$ARCHIVE" "$ITEM"
rm -f "$ITEM"
EOF
    fi
}

fetch_archive() {
    log "Descargando $ARCHIVE..."
    mkdir -p "$LOCAL_BACKUP_DIR"
    "${SSH_PREFIX[@]}" scp -P "$SSH_PORT" "${SSH_OPTS[@]}" \
        "$SSH_USER@$SSH_HOST:$REMOTE_BACKUP_DIR/$ARCHIVE" "$LOCAL_BACKUP_DIR/"
    log "Descomprimiendo..."
    tar -xzf "$LOCAL_BACKUP_DIR/$ARCHIVE" -C "$LOCAL_BACKUP_DIR"
    if [[ $DUMP_FORMAT == dir ]]; then
        [[ -f $LOCAL_BACKUP_DIR/$ITEM/toc.dat ]] || die "Backup inválido: falta toc.dat"
    else
        [[ -s $LOCAL_BACKUP_DIR/$ITEM ]] || die "Backup inválido: dump vacío"
    fi
}

local_restore() {
    log "Parando contenedores locales y recreando '$LOCAL_DB'..."
    lcompose stop
    lcompose run --rm -T "$LOCAL_SERVICE" dropdb --if-exists "$LOCAL_DB"
    lcompose run --rm -T "$LOCAL_SERVICE" createdb "$LOCAL_DB"
    log "Restaurando..."
    if [[ $DUMP_FORMAT == dir ]]; then
        lcompose run --rm -T -v "$LOCAL_BACKUP_DIR/$ITEM:/backup" "$LOCAL_SERVICE" \
            pg_restore $PG_RESTORE_OPTS -j "$JOBS" -d "$LOCAL_DB" /backup
    else
        lcompose run --rm -T "$LOCAL_SERVICE" psql -q "$LOCAL_DB" < "$LOCAL_BACKUP_DIR/$ITEM"
    fi
    rm -rf "${LOCAL_BACKUP_DIR:?}/$ITEM"
}

sync_filestore() {
    log "Sincronizando filestore (rsync --delete)..."
    local cmd=(rsync -azh --delete --info=progress2 -e "$RSYNC_SSH") pre=()
    [[ $REMOTE_RSYNC_SUDO == true ]] && cmd+=(--rsync-path="sudo rsync")
    [[ $LOCAL_RSYNC_SUDO  == true ]] && pre=(sudo --preserve-env=SSHPASS,SSH_AUTH_SOCK)
    "${pre[@]}" "${SSH_PREFIX[@]}" "${cmd[@]}" \
        "$SSH_USER@$SSH_HOST:${REMOTE_FILESTORE%/}/" "${LOCAL_FILESTORE%/}/"
}

post_restore() {
    local s path
    if [[ $RUN_UPDATE == true ]]; then
        log "update-all..."
        lcompose run --rm -T "$LOCAL_SERVICE" click-odoo-update -d "$LOCAL_DB" --update-all
    fi
    if ((${#POST_MODULES[@]})); then
        log "Instalando módulos: ${POST_MODULES[*]}"
        lcompose run --rm -T "$LOCAL_SERVICE" odoo -d "$LOCAL_DB" --stop-after-init \
            -i "$(IFS=,; echo "${POST_MODULES[*]}")"
    fi
    for s in "${POST_SCRIPTS[@]}"; do
        path=$(resolve_local "$s")
        [[ -f $path ]] || { warn "Script no encontrado, se omite: $path"; continue; }
        log "Ejecutando $s"
        lcompose run --rm -T "$LOCAL_SERVICE" odoo shell -d "$LOCAL_DB" < "$path"
    done
    if [[ $NEUTRALIZE == true ]]; then
        log "neutralize..."
        lcompose run --rm -T "$LOCAL_SERVICE" odoo neutralize -d "$LOCAL_DB"
    fi
}

rotate_backups() {
    log "Rotando backups (KEEP=$KEEP)..."
    remote bash -s <<EOF
set -euo pipefail
ls -1t "$REMOTE_BACKUP_DIR"/*_$BACKUP_TAG.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f -- || true
EOF
    local old f
    mapfile -t old < <(ls -1t "$LOCAL_BACKUP_DIR"/*_"$BACKUP_TAG".tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) || true)
    for f in "${old[@]}"; do log "Eliminando local: $(basename "$f")"; rm -f -- "$f"; done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    load_config
    print_summary
    if $DRY_RUN; then log "Dry-run: no se ha ejecutado nada."; return 0; fi
    setup_ssh
    preflight
    remote_dump
    fetch_archive
    local_restore
    [[ $COPY_FILESTORE == true ]] && sync_filestore
    post_restore
    lcompose start
    rotate_backups
    log "HECHO :)  $LOCAL_DB restaurada desde $PROJECT ($ARCHIVE)"
}
main
