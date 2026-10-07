#!/usr/bin/env bash
# =============================================================================
# odoo-prod2local.sh — copia una BBDD Odoo (Doodba + docker compose) de un
# servidor remoto a tu entorno local por SSH. Opcionalmente trae el filestore.
#
# Todo lo específico de cada proyecto (host, claves, rutas, hooks) vive en
# conf/<proyecto>.conf. Este script no contiene datos de ningún proyecto.
#
# Flujo normal:
#   1 comprobar espacio  2 dump remoto  3 descargar  4 extraer  5 restaurar
#   6 [filestore]  7 update-all/módulos/scripts/neutralize  8 arrancar
#   9 limpiar backups antiguos (remoto y local)
# Con --from-local se saltan 1-3 y 9: se restaura un backup ya descargado.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${PROD2LOCAL_CONF_DIR:-$SCRIPT_DIR/conf}"

log()  { printf '[%s] [+] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] [!] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] [!] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
trap 'die "falló la línea $LINENO: $BASH_COMMAND"' ERR

usage() {
    cat <<EOF
Uso: ${0##*/} <proyecto|ruta.conf> [opciones]

  -f, --filestore      traer también el filestore (rsync). Por defecto NO.
      --only-filestore traer SOLO el filestore (no toca BBDD, backups ni contenedores)
      --from-local     NO tocar el servidor: restaurar el último backup local
      --backup NOMBRE  restaurar ese backup local (nombre o ruta; implica --from-local)
      --list-backups   listar backups del proyecto (local y remoto) y salir
      --no-update      saltar click-odoo-update --update-all
      --no-neutralize  saltar 'odoo neutralize'
      --no-space-check saltar la comprobación de espacio libre
  -n, --dry-run        mostrar la configuración resuelta y salir
  -l, --list           listar proyectos disponibles
  -h, --help           esta ayuda

Configuraciones en: $CONF_DIR   (cámbialo con PROD2LOCAL_CONF_DIR)
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
SSH_KEY=""            # clave privada (si se define, tiene prioridad)
SSH_PASS=""           # password (vía sshpass)
SSH_PASS_CMD=""       # alternativa: comando que imprime el password

REMOTE_COMPOSE_BIN="docker compose"
REMOTE_COMPOSE_FILE="prod.yaml"
REMOTE_SERVICE="odoo"
REMOTE_DB="prod"
REMOTE_DOCKER_PATH=""     # OBLIGATORIO: carpeta con prod.yaml en el servidor
REMOTE_FILESTORE=""       # obligatorio con --filestore
REMOTE_RSYNC_SUDO=true    # rsync con sudo en remoto (filestore en /var/lib/docker)

LOCAL_COMPOSE_BIN="docker compose"
LOCAL_COMPOSE_FILE="devel.yaml"
LOCAL_SERVICE="odoo"
LOCAL_DB="devel"
LOCAL_DOCKER_PATH=""      # OBLIGATORIO: carpeta con devel.yaml en local
LOCAL_FILESTORE=""        # obligatorio con --filestore
LOCAL_RSYNC_SUDO=true     # rsync con sudo en local (filestore en /var/lib/docker)
LOCAL_BACKUP_DIR=""       # OBLIGATORIO: carpeta local donde se guardan los backups

DUMP_FORMAT="dir"         # dir = pg_dump -Fd + pg_restore | sql = pg_dump plano + psql
DUMP_JOBS=1               # jobs del pg_dump EN PRODUCCIÓN (1 = no saturar el servidor)
RESTORE_JOBS=4            # jobs del pg_restore en local
COMPRESS_LEVEL=5          # solo formato dir
PG_DUMP_OPTS=""
PG_RESTORE_OPTS=""

RUN_UPDATE=true
NEUTRALIZE=true
POST_SCRIPTS=()           # scripts python (odoo shell), relativos a LOCAL_DOCKER_PATH
POST_MODULES=()           # módulos a instalar (-i)

KEEP_LOCAL=2              # backups a conservar en local (>= 1)
KEEP_REMOTE=1             # backups a conservar en remoto (0 = borrarlos todos al terminar)
CHECK_SPACE=true
PROJECT_NAME=""           # OBLIGATORIO: nombre del proyecto (sufijo de los backups)

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------
PROJECT_ARG=""; OPT_FILESTORE=""; OPT_UPDATE=""; OPT_NEUTRALIZE=""; OPT_BACKUP=""
OPT_SPACE=""; DRY_RUN=false; FROM_LOCAL=false; LIST_BACKUPS=false; ONLY_FILESTORE=false
while (($#)); do
    case "$1" in
        -f|--filestore)    OPT_FILESTORE=true ;;
        --only-filestore)  ONLY_FILESTORE=true; OPT_FILESTORE=true ;;
        --from-local)      FROM_LOCAL=true ;;
        --backup)          [[ $# -ge 2 ]] || die "--backup necesita un valor"
                           OPT_BACKUP=$2; FROM_LOCAL=true; shift ;;
        --list-backups)    LIST_BACKUPS=true ;;
        --no-update)       OPT_UPDATE=false ;;
        --no-neutralize)   OPT_NEUTRALIZE=false ;;
        --no-space-check)  OPT_SPACE=false ;;
        -n|--dry-run)      DRY_RUN=true ;;
        -l|--list)         list_projects; exit 0 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                die "Opción desconocida: $1 (usa --help)" ;;
        *) [[ -z $PROJECT_ARG ]] || die "Solo se admite un proyecto"; PROJECT_ARG=$1 ;;
    esac
    shift
done
[[ -n $PROJECT_ARG ]] || { usage; exit 1; }
if $ONLY_FILESTORE && { $FROM_LOCAL || $LIST_BACKUPS; }; then
    die "--only-filestore no se combina con --from-local, --backup ni --list-backups"
fi
[[ $(id -u) != 0 ]] || die "No ejecutar como root."

# -----------------------------------------------------------------------------
# Configuración: carga, valores derivados y validación
# -----------------------------------------------------------------------------
apply_defaults() {
    if [[ -n $OPT_FILESTORE ]]; then COPY_FILESTORE=$OPT_FILESTORE; else COPY_FILESTORE=false; fi
    if [[ -n $OPT_UPDATE ]];     then RUN_UPDATE=$OPT_UPDATE; fi
    if [[ -n $OPT_NEUTRALIZE ]]; then NEUTRALIZE=$OPT_NEUTRALIZE; fi
    if [[ -n $OPT_SPACE ]];      then CHECK_SPACE=$OPT_SPACE; fi
}

load_config() {
    if   [[ -f $PROJECT_ARG ]];                then CONF_FILE=$(realpath "$PROJECT_ARG")
    elif [[ -f $CONF_DIR/$PROJECT_ARG.conf ]]; then CONF_FILE="$CONF_DIR/$PROJECT_ARG.conf"
    else die "No existe la configuración '$PROJECT_ARG' en $CONF_DIR (usa --list)"
    fi

    local perm; perm=$(stat -c '%a' "$CONF_FILE")
    [[ ${perm: -2} == 00 ]] || die "$CONF_FILE tiene permisos $perm; ejecuta: chmod 600 $CONF_FILE"

    # shellcheck disable=SC1090
    source "$CONF_FILE"
    apply_defaults

    local v req=(PROJECT_NAME SSH_HOST SSH_USER REMOTE_DOCKER_PATH LOCAL_DOCKER_PATH REMOTE_BACKUP_DIR LOCAL_BACKUP_DIR)
    if [[ $COPY_FILESTORE == true ]]; then req+=(REMOTE_FILESTORE LOCAL_FILESTORE); fi
    for v in "${req[@]}"; do
        [[ -n ${!v:-} ]] || die "Falta $v en $CONF_FILE (ver conf/_example.conf)"
    done
    [[ $PROJECT_NAME =~ ^[A-Za-z0-9_.-]+$ ]]  || die "PROJECT_NAME solo admite letras, números, _ . -"
    BACKUP_TAG="$PROJECT_NAME"
    # REMOTE_COMPOSE_FILE vacío = sin -f (compose usa su fichero por defecto)
    REMOTE_COMPOSE_OPT=""
    if [[ -n $REMOTE_COMPOSE_FILE ]]; then REMOTE_COMPOSE_OPT="-f \"$REMOTE_COMPOSE_FILE\""; fi
    # '~' dentro de comillas no se expande: lo hacemos aquí para las rutas locales
    LOCAL_DOCKER_PATH="${LOCAL_DOCKER_PATH/#\~/$HOME}"
    LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR/#\~/$HOME}"
    LOCAL_FILESTORE="${LOCAL_FILESTORE/#\~/$HOME}"
    [[ $REMOTE_BACKUP_DIR == /* ]]            || die "REMOTE_BACKUP_DIR debe ser una ruta absoluta"
    [[ $DUMP_FORMAT == dir || $DUMP_FORMAT == sql ]] || die "DUMP_FORMAT debe ser 'dir' o 'sql'"
    [[ $KEEP_LOCAL  =~ ^[1-9][0-9]*$ ]]       || die "KEEP_LOCAL debe ser un entero >= 1"
    [[ $KEEP_REMOTE =~ ^[0-9]+$ ]]            || die "KEEP_REMOTE debe ser un entero >= 0"
    [[ $DUMP_JOBS =~ ^[1-9][0-9]*$ && $RESTORE_JOBS =~ ^[1-9][0-9]*$ ]] || die "DUMP_JOBS y RESTORE_JOBS deben ser enteros >= 1"
    [[ -d $LOCAL_DOCKER_PATH ]]               || die "No existe LOCAL_DOCKER_PATH: $LOCAL_DOCKER_PATH"
    [[ -f $LOCAL_DOCKER_PATH/$LOCAL_COMPOSE_FILE ]] || die "No existe $LOCAL_DOCKER_PATH/$LOCAL_COMPOSE_FILE"

    if $ONLY_FILESTORE; then
        LOCAL_ARCHIVE=""
    elif $FROM_LOCAL; then
        pick_local_archive
    else
        BACKUP_NAME="$(date +%Y-%m-%d_%H-%M)_${BACKUP_TAG}"
        LOCAL_ARCHIVE="$LOCAL_BACKUP_DIR/$BACKUP_NAME.tar.gz"
    fi
}

# Backup local a restaurar: el indicado con --backup o el más reciente del proyecto
pick_local_archive() {
    local f
    if [[ -n $OPT_BACKUP ]]; then
        for f in "$OPT_BACKUP" "$LOCAL_BACKUP_DIR/$OPT_BACKUP" "$LOCAL_BACKUP_DIR/$OPT_BACKUP.tar.gz"; do
            if [[ -f $f ]]; then LOCAL_ARCHIVE=$(realpath "$f"); return 0; fi
        done
        die "No encuentro el backup '$OPT_BACKUP' (busqué en $LOCAL_BACKUP_DIR)"
    fi
    f=$(ls -1t "$LOCAL_BACKUP_DIR"/*_"$BACKUP_TAG".tar.gz 2>/dev/null | head -1 || true)
    [[ -n $f ]] || die "No hay backups locales de $PROJECT_NAME en $LOCAL_BACKUP_DIR"
    LOCAL_ARCHIVE=$f
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
        command -v sshpass >/dev/null || die "Falta sshpass (o define SSH_KEY)"
        if [[ -n $SSH_PASS_CMD ]]; then SSH_PASS=$(eval "$SSH_PASS_CMD"); fi
        export SSHPASS="$SSH_PASS"
        SSH_PREFIX=(sshpass -e)
    fi
    printf -v RSYNC_SSH '%q ' ssh -p "$SSH_PORT" "${SSH_OPTS[@]}"
}

remote()   { "${SSH_PREFIX[@]}" ssh -T -p "$SSH_PORT" "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "$@"; }
lcompose() { ( trap - ERR; cd "$LOCAL_DOCKER_PATH" && $LOCAL_COMPOSE_BIN -f "$LOCAL_COMPOSE_FILE" "$@" ); }

resolve_local() { if [[ $1 == /* ]]; then echo "$1"; else echo "$LOCAL_DOCKER_PATH/$1"; fi; }
needs_ssh()     { ! $FROM_LOCAL || [[ $COPY_FILESTORE == true ]]; }
human()         { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

print_summary() {
    local auth origen
    if $ONLY_FILESTORE; then
        cat <<EOF
================================================================
  odoo-prod2local  |  $PROJECT_NAME  |  SOLO FILESTORE
================================================================
  Origen : $SSH_USER@$SSH_HOST:$SSH_PORT  $REMOTE_FILESTORE
  Destino: $LOCAL_FILESTORE   (rsync --delete; sudo remoto=$REMOTE_RSYNC_SUDO, local=$LOCAL_RSYNC_SUDO)
  No se toca: BBDD, contenedores ni backups
================================================================
EOF
        return 0
    fi
    if   [[ -n $SSH_KEY ]];                  then auth="clave $SSH_KEY"
    elif [[ -n $SSH_PASS || -n $SSH_PASS_CMD ]]; then auth="password (sshpass)"
    else auth="ssh por defecto (agente/claves)"; fi
    if $FROM_LOCAL; then origen="backup local $(basename "$LOCAL_ARCHIVE")"
    else origen="dump remoto $DUMP_FORMAT (jobs=$DUMP_JOBS) -> $LOCAL_ARCHIVE"; fi
    cat <<EOF
================================================================
  odoo-prod2local  |  $PROJECT_NAME
================================================================
  Origen   : $origen
  Remoto   : $SSH_USER@$SSH_HOST:$SSH_PORT  ($REMOTE_DOCKER_PATH, ${REMOTE_COMPOSE_FILE:-compose por defecto}, db=$REMOTE_DB)
  Auth     : $auth
  Local    : $LOCAL_DOCKER_PATH  ($LOCAL_COMPOSE_FILE, db=$LOCAL_DB, restore jobs=$RESTORE_JOBS)
  Backups  : $LOCAL_BACKUP_DIR   (conserva: local=$KEEP_LOCAL, remoto=$KEEP_REMOTE)
  Filestore: $COPY_FILESTORE$([[ $COPY_FILESTORE == true ]] && echo "  ($REMOTE_FILESTORE -> $LOCAL_FILESTORE)")
  Después  : update-all=$RUN_UPDATE  neutralize=$NEUTRALIZE
  Scripts  : ${POST_SCRIPTS[*]:-(ninguno)}
  Módulos  : ${POST_MODULES[*]:-(ninguno)}
================================================================
EOF
}

preflight() {
    local c
    for c in tar "${LOCAL_COMPOSE_BIN%% *}"; do command -v "$c" >/dev/null || die "Falta $c"; done
    needs_ssh || return 0
    for c in ssh scp; do command -v "$c" >/dev/null || die "Falta $c"; done
    if [[ $COPY_FILESTORE == true ]]; then command -v rsync >/dev/null || die "Falta rsync"; fi
    log "Comprobando conexión SSH..."
    remote true || die "No se puede conectar a $SSH_USER@$SSH_HOST:$SSH_PORT"
}

# -----------------------------------------------------------------------------
# Etapas
# -----------------------------------------------------------------------------
# Espacio libre: remoto y local deben tener, al menos, el tamaño de la BBDD
space_check() {
    $CHECK_SPACE || return 0
    log "Comprobando espacio libre..."
    local out line size r_avail l_avail
    out=$(remote bash -s <<EOF
set -euo pipefail
mkdir -p "$REMOTE_BACKUP_DIR"
cd "$REMOTE_DOCKER_PATH"
size=\$($REMOTE_COMPOSE_BIN $REMOTE_COMPOSE_OPT run --rm -T $REMOTE_SERVICE psql -tA "$REMOTE_DB" -c "select pg_database_size(current_database())" </dev/null | grep -E '^[0-9]+\$' | tail -1 || true)
avail=\$(df -B1 --output=avail "$REMOTE_BACKUP_DIR" | tail -1 | tr -d ' ')
echo "SPACE \${size:-0} \$avail"
EOF
)
    line=$(grep '^SPACE ' <<<"$out" | tail -1 || true)
    read -r _ size r_avail <<<"${line:-SPACE 0 0}"
    if [[ ${size:-0} -eq 0 ]]; then warn "No se pudo calcular el tamaño de la BBDD; se omite la comprobación"; return 0; fi
    mkdir -p "$LOCAL_BACKUP_DIR"
    l_avail=$(df -B1 --output=avail "$LOCAL_BACKUP_DIR" | tail -1 | tr -d ' ')
    log "BBDD: $(human "$size")  |  libre remoto: $(human "$r_avail")  local: $(human "$l_avail")"
    (( r_avail >= size )) || die "Poco espacio en el servidor ($(human "$r_avail") libres, la BBDD ocupa $(human "$size")). Usa --no-space-check para saltarlo."
    (( l_avail >= size )) || die "Poco espacio en local ($(human "$l_avail") libres, la BBDD ocupa $(human "$size")). Usa --no-space-check para saltarlo."
}

remote_dump() {
    log "Dump remoto de '$REMOTE_DB' (formato $DUMP_FORMAT, jobs=$DUMP_JOBS)..."
    local item="$BACKUP_NAME"; [[ $DUMP_FORMAT == sql ]] && item="$BACKUP_NAME.sql"
    # </dev/null en docker: evita que 'run' se coma el resto del script por stdin
    if [[ $DUMP_FORMAT == dir ]]; then
        remote bash -s <<EOF
set -euo pipefail
mkdir -p "$REMOTE_BACKUP_DIR"
cd "$REMOTE_DOCKER_PATH"
$REMOTE_COMPOSE_BIN $REMOTE_COMPOSE_OPT run --rm -T -v "$REMOTE_BACKUP_DIR:/backup" $REMOTE_SERVICE pg_dump $PG_DUMP_OPTS -Fd -j $DUMP_JOBS -Z $COMPRESS_LEVEL -f "/backup/$item" "$REMOTE_DB" </dev/null
cd "$REMOTE_BACKUP_DIR"
tar -czf "$BACKUP_NAME.tar.gz" "$item"
rm -rf "$item"
EOF
    else
        remote bash -s <<EOF
set -euo pipefail
mkdir -p "$REMOTE_BACKUP_DIR"
cd "$REMOTE_DOCKER_PATH"
$REMOTE_COMPOSE_BIN $REMOTE_COMPOSE_OPT run --rm -T $REMOTE_SERVICE pg_dump $PG_DUMP_OPTS "$REMOTE_DB" </dev/null | grep -v "doodba INFO:" > "$REMOTE_BACKUP_DIR/$item"
cd "$REMOTE_BACKUP_DIR"
tar -czf "$BACKUP_NAME.tar.gz" "$item"
rm -f "$item"
EOF
    fi
}

fetch_archive() {
    log "Descargando $BACKUP_NAME.tar.gz..."
    mkdir -p "$LOCAL_BACKUP_DIR"
    "${SSH_PREFIX[@]}" scp -P "$SSH_PORT" "${SSH_OPTS[@]}" \
        "$SSH_USER@$SSH_HOST:$REMOTE_BACKUP_DIR/$BACKUP_NAME.tar.gz" "$LOCAL_BACKUP_DIR/"
}

# Descomprime LOCAL_ARCHIVE y fija ITEM (dir o .sql) y RESTORE_FORMAT según su contenido
extract_archive() {
    log "Descomprimiendo $(basename "$LOCAL_ARCHIVE")..."
    mkdir -p "$LOCAL_BACKUP_DIR"
    ITEM=$(tar -tzf "$LOCAL_ARCHIVE" | awk -F/ 'NR==1{print $1}')
    [[ -n $ITEM ]] || die "Archivo vacío o ilegible: $LOCAL_ARCHIVE"
    rm -rf "${LOCAL_BACKUP_DIR:?}/$ITEM"
    tar -xzf "$LOCAL_ARCHIVE" -C "$LOCAL_BACKUP_DIR"
    if [[ $ITEM == *.sql ]]; then
        RESTORE_FORMAT=sql
        [[ -s $LOCAL_BACKUP_DIR/$ITEM ]] || die "Backup inválido: dump vacío"
    else
        RESTORE_FORMAT=dir
        [[ -f $LOCAL_BACKUP_DIR/$ITEM/toc.dat ]] || die "Backup inválido: falta toc.dat"
    fi
}

local_restore() {
    log "Parando contenedores locales y recreando '$LOCAL_DB'..."
    lcompose stop
    lcompose run --rm -T "$LOCAL_SERVICE" dropdb --if-exists "$LOCAL_DB"
    lcompose run --rm -T "$LOCAL_SERVICE" createdb "$LOCAL_DB"
    log "Restaurando ($RESTORE_FORMAT)..."
    if [[ $RESTORE_FORMAT == dir ]]; then
        lcompose run --rm -T -v "$LOCAL_BACKUP_DIR/$ITEM:/backup" "$LOCAL_SERVICE" \
            pg_restore $PG_RESTORE_OPTS -j "$RESTORE_JOBS" -d "$LOCAL_DB" /backup
    else
        lcompose run --rm -T "$LOCAL_SERVICE" psql -q "$LOCAL_DB" < "$LOCAL_BACKUP_DIR/$ITEM"
    fi
    rm -rf "${LOCAL_BACKUP_DIR:?}/$ITEM"
}

sync_filestore() {
    log "Sincronizando filestore (rsync --delete)..."
    local cmd=(rsync -azh --delete --info=progress2 -e "$RSYNC_SSH") pre=()
    if [[ $REMOTE_RSYNC_SUDO == true ]]; then cmd+=(--rsync-path="sudo rsync"); fi
    if [[ $LOCAL_RSYNC_SUDO  == true ]]; then pre=(sudo --preserve-env=SSHPASS,SSH_AUTH_SOCK); fi
    "${pre[@]}" mkdir -p "${LOCAL_FILESTORE%/}"
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
    log "Limpiando backups antiguos (remoto: conserva $KEEP_REMOTE, local: conserva $KEEP_LOCAL)..."
    remote bash -s <<EOF
set -euo pipefail
ls -1t "$REMOTE_BACKUP_DIR"/*_$BACKUP_TAG.tar.gz 2>/dev/null | tail -n +$((KEEP_REMOTE + 1)) | xargs -r rm -f -- || true
EOF
    local old f
    mapfile -t old < <(ls -1t "$LOCAL_BACKUP_DIR"/*_"$BACKUP_TAG".tar.gz 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)) || true)
    for f in "${old[@]}"; do log "Eliminando local: $(basename "$f")"; rm -f -- "$f"; done
}

list_backups() {
    local f
    log "Backups locales en $LOCAL_BACKUP_DIR:"
    for f in $(ls -1t "$LOCAL_BACKUP_DIR"/*_"$BACKUP_TAG".tar.gz 2>/dev/null || true); do
        printf '    %s  (%s)\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done
    log "Backups remotos en $REMOTE_BACKUP_DIR:"
    remote "ls -1t \"$REMOTE_BACKUP_DIR\"/*_$BACKUP_TAG.tar.gz 2>/dev/null | xargs -r -n1 basename | sed 's/^/    /'" || true
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    load_config
    if $LIST_BACKUPS; then setup_ssh; list_backups; return 0; fi
    print_summary
    if $DRY_RUN; then log "Dry-run: no se ha ejecutado nada."; return 0; fi

    if $ONLY_FILESTORE; then
        setup_ssh
        preflight
        sync_filestore
        log "HECHO :)  filestore de $PROJECT_NAME sincronizado en $LOCAL_FILESTORE"
        return 0
    fi
    mkdir -p "$LOCAL_BACKUP_DIR"

    if needs_ssh; then setup_ssh; fi
    preflight

    if ! $FROM_LOCAL; then
        space_check
        remote_dump
        fetch_archive
    fi
    extract_archive
    local_restore
    if [[ $COPY_FILESTORE == true ]]; then sync_filestore; fi
    post_restore
    lcompose start
    if ! $FROM_LOCAL; then rotate_backups; fi
    log "HECHO :)  $LOCAL_DB restaurada desde $(basename "$LOCAL_ARCHIVE")"
}
main
