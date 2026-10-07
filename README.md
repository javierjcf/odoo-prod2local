# odoo-prod2local

Copia una base de datos Odoo (Doodba + docker compose) desde un servidor remoto
a tu entorno local por SSH, con o sin filestore. Bash puro: solo `ssh`, `scp`,
`tar`, `rsync` (filestore), `docker compose` y, si usas password, `sshpass`.
No usa herramientas de terceros para el dump (`pg_dump` / `pg_restore` / `psql`).

```
odoo-prod2local/
├── odoo-prod2local.sh      # el script (genérico, sin datos de proyecto)
├── conf/
│   ├── _example.conf       # plantilla comentada (subible a git)
│   └── <proyecto>.conf     # uno por proyecto (ignorados por git, chmod 600)
└── README.md
```

## Inicio rápido

```bash
./odoo-prod2local.sh did_v18                  # solo BBDD
./odoo-prod2local.sh did_v18 --filestore      # BBDD + filestore
./odoo-prod2local.sh --list                   # proyectos configurados
```

### Añadir un proyecto (1 minuto)

```bash
cp conf/_example.conf conf/miproyecto.conf
chmod 600 conf/miproyecto.conf      # el script se niega a leerlo si no
$EDITOR conf/miproyecto.conf        # rellena la sección 1 (OBLIGATORIO)
./odoo-prod2local.sh miproyecto --dry-run   # ver la configuración resuelta
```

`conf/_example.conf` es la referencia: arriba lo **obligatorio** (descomentado) y debajo
**todo lo opcional**, comentado y con su valor por defecto. Nada se deduce del nombre del
fichero: el nombre del proyecto, las rutas y las carpetas de backup se escriben a mano.
Ejemplos reales: `conf/did_v18.conf` y `conf/delete_v18.conf`.

## Opciones

| Opción | Qué hace |
|---|---|
| `-f`, `--filestore` | Trae también el filestore con rsync (`--delete`). Por defecto **no** se trae. |
| `--from-local` | **No toca el servidor**: restaura el último backup local del proyecto. |
| `--backup NOMBRE` | Restaura ese backup local (nombre con o sin `.tar.gz`, o ruta). Implica `--from-local`. |
| `--list-backups` | Lista los backups del proyecto, locales y remotos. |
| `--no-update` | Salta `click-odoo-update --update-all`. |
| `--no-neutralize` | Salta `odoo neutralize`. |
| `--no-space-check` | Salta la comprobación de espacio libre. |
| `-n`, `--dry-run` | Muestra la configuración resuelta y sale sin ejecutar nada. |
| `-l`, `--list` | Lista los proyectos disponibles. |
| `-h`, `--help` | Ayuda. |

Variable de entorno: `PROD2LOCAL_CONF_DIR=/otra/carpeta` cambia dónde se buscan
los `.conf`. También puedes pasar directamente la ruta de un `.conf` en lugar del nombre.

## Qué hace, paso a paso

1. **Comprobaciones**: permisos 600 del `.conf`, herramientas necesarias y conexión SSH.
2. **Espacio libre**: calcula el tamaño de la BBDD (`pg_database_size`) y exige al menos
   ese espacio libre en el servidor (`REMOTE_BACKUP_DIR`) y en local. Si no puede
   calcularlo, avisa y sigue.
3. **Dump remoto** dentro del contenedor: `pg_dump -Fd -j N` (`dir`) o SQL plano (`sql`),
   empaquetado en `AAAA-MM-DD_HH-MM_<proyecto>.tar.gz`.
4. **Descarga** por `scp`.
5. **Extracción**: detecta el formato del backup por su contenido (carpeta con `toc.dat`
   o `.sql`), así que puedes restaurar backups antiguos aunque hayas cambiado `DUMP_FORMAT`.
6. **Restore**: para el compose local, `dropdb` + `createdb` y `pg_restore -j N` / `psql`.
   La carpeta extraída se borra al terminar; solo se conserva el `.tar.gz`.
7. **Filestore** (solo con `--filestore`): `rsync -azh --delete`.
8. **Post-restore**: update-all → módulos (`POST_MODULES`) → scripts python (`POST_SCRIPTS`)
   → `odoo neutralize`. Todo configurable por proyecto.
9. **Arranca** el compose y **limpia** backups antiguos (remoto: `KEEP_REMOTE`, local: `KEEP_LOCAL`).

La salida de cada comando (incluido el update-all) se ve por pantalla; no hay ficheros de log.

## Funciones extra

### Retomar un backup que ya está en local
Si el script falla **después** de descargar (restore, update-all, un script de dev…),
no hace falta volver a pedir el dump a producción:

```bash
./odoo-prod2local.sh miproyecto --from-local                 # el último backup local
./odoo-prod2local.sh miproyecto --backup 2026-10-06_11-56_miproyecto   # uno concreto
./odoo-prod2local.sh miproyecto --list-backups               # ver cuáles hay
./odoo-prod2local.sh miproyecto --from-local --filestore     # y de paso el filestore
```
En este modo no se conecta al servidor (salvo que pidas `--filestore`) y no rota backups.
También sirve para **volver a un estado anterior** de la BBDD cuando quieras.

### Limpiar la copia remota
`KEEP_REMOTE` controla cuántos backups del proyecto quedan en el servidor al terminar:
`1` (por defecto) deja el último; `0` borra todos, incluido el que acabas de generar
(comportamiento de los scripts antiguos). Igual con `KEEP_LOCAL` (mínimo 1) en tu máquina.
Solo se tocan ficheros `*_<proyecto>.tar.gz`, así que varios proyectos pueden compartir
la misma carpeta remota sin pisarse.

### Cuidar el servidor de producción
`DUMP_JOBS` (por defecto **1**) son los procesos paralelos del `pg_dump` en producción.
Súbelo (`DUMP_JOBS=8`) solo en proyectos cuyo servidor lo aguante. El restore local usa
`RESTORE_JOBS` (por defecto 4), que no afecta a producción.

### Dos formatos de dump
- `DUMP_FORMAT="dir"` (por defecto): `pg_dump -Fd` + `pg_restore -j`. Más rápido.
- `DUMP_FORMAT="sql"`: SQL plano + `psql`, como los scripts antiguos de did/penacruz.

## Variables del `.conf`

Un `.conf` es un fichero bash con variables (`NOMBRE="valor"`; las listas, `POST_SCRIPTS=("a" "b")`).
`conf/_example.conf` las trae todas: las obligatorias descomentadas arriba, y las opcionales
comentadas debajo con su valor por defecto. Para cambiar una opcional, descoméntala.

Leyenda de la columna **Obligatoria**:

| Valor | Significado |
|---|---|
| **Sí** | Sin ella el script se detiene con un error que nombra la variable que falta. |
| **Con `--filestore`** | Solo se exige cuando traes el filestore; si no usas `--filestore` puede faltar. |
| **Una de** | Elige una forma de autenticar entre las marcadas (ver «Autenticación»). Si no pones ninguna, se usa el agente o las claves por defecto de `ssh`. |
| No | Opcional: si no la defines se usa el valor de la columna «Por defecto». |

### Proyecto y conexión SSH

| Variable | Obligatoria | Por defecto | Qué hace | Ejemplo |
|---|---|---|---|---|
| `PROJECT_NAME` | **Sí** | — | Nombre del proyecto. Es el sufijo de los backups (`AAAA-MM-DD_HH-MM_<PROJECT_NAME>.tar.gz`) y lo que se usa para rotarlos. Solo letras, números, `_ . -`. | `"did_v18"` |
| `SSH_HOST` | **Sí** | — | IP o nombre del servidor de producción. | `"51.91.104.112"` |
| `SSH_USER` | **Sí** | — | Usuario SSH. | `"ubuntu"` |
| `SSH_PASS` | **Una de** | — | Password SSH (usa `sshpass`). | `"secreto"` |
| `SSH_KEY` | **Una de** | — | Clave privada. Tiene prioridad sobre el password. | `"~/.ssh/id_ed25519"` |
| `SSH_PASS_CMD` | **Una de** | — | Comando que imprime el password (para no guardarlo en el fichero). | `"pass show odoo/did"` |
| `SSH_PORT` | No | `22` | Puerto SSH. | `1022` |

### Carpetas de docker compose

| Variable | Obligatoria | Por defecto | Qué hace | Ejemplo |
|---|---|---|---|---|
| `REMOTE_DOCKER_PATH` | **Sí** | — | Carpeta del proyecto en el servidor, donde está `prod.yaml`. | `"/opt/odoo/did_v18"` |
| `LOCAL_DOCKER_PATH` | **Sí** | — | Carpeta del proyecto en tu máquina, donde está `devel.yaml`. Debe existir. | `"/opt/odoo/did_v18"` |
| `REMOTE_COMPOSE_FILE` | No | `prod.yaml` | Fichero compose del servidor. | `"prod.yaml"` |
| `LOCAL_COMPOSE_FILE` | No | `devel.yaml` | Fichero compose local. | `"devel.yaml"` |
| `REMOTE_COMPOSE_BIN` | No | `docker compose` | Comando compose del servidor. | `"docker-compose"` |
| `LOCAL_COMPOSE_BIN` | No | `docker compose` | Comando compose local. | `"docker-compose"` |
| `REMOTE_SERVICE` | No | `odoo` | Servicio de compose que ejecuta `pg_dump`. | `"odoo"` |
| `LOCAL_SERVICE` | No | `odoo` | Servicio de compose que ejecuta restore, update y neutralize. | `"odoo"` |
| `REMOTE_DB` | No | `prod` | BBDD de origen en el servidor. | `"prod"` |
| `LOCAL_DB` | No | `devel` | BBDD de destino. **Se borra y se recrea.** | `"devel"` |

### Carpetas de backups

| Variable | Obligatoria | Por defecto | Qué hace | Ejemplo |
|---|---|---|---|---|
| `REMOTE_BACKUP_DIR` | **Sí** | — | Carpeta del servidor donde se genera el dump. Ruta **absoluta**; se crea con `mkdir -p`. | `"/home/ubuntu/backup-script"` |
| `LOCAL_BACKUP_DIR` | **Sí** | — | Carpeta local donde se guardan los `.tar.gz`; se crea con `mkdir -p`. Admite `~` y `$HOME`. | `"$HOME/bbdd/did_v18"` |
| `KEEP_LOCAL` | No | `2` | Backups a conservar en tu máquina (mínimo 1). | `3` |
| `KEEP_REMOTE` | No | `1` | Backups a conservar en el servidor. `0` los borra todos al terminar, incluido el recién creado. | `0` |
| `CHECK_SPACE` | No | `true` | Comprueba antes del dump que hay espacio libre (servidor y local). `--no-space-check` lo salta una vez. | `false` |

### Filestore (solo con `--filestore`)

| Variable | Obligatoria | Por defecto | Qué hace | Ejemplo |
|---|---|---|---|---|
| `REMOTE_FILESTORE` | **Con `--filestore`** | — | Carpeta del filestore en el servidor. Con barra final: copia el **contenido**. | `"/var/lib/docker/volumes/did_v18_filestore/_data/filestore/prod/"` |
| `LOCAL_FILESTORE` | **Con `--filestore`** | — | Carpeta destino local. Se crea si no existe. Se sincroniza con `--delete`. | `"/var/lib/docker/volumes/did_v18_filestore/_data/filestore/devel"` |
| `REMOTE_RSYNC_SUDO` | No | `true` | Usa `sudo rsync` en el servidor (hace falta si está en `/var/lib/docker`). Requiere sudo **sin password** para el usuario SSH. | `false` |
| `LOCAL_RSYNC_SUDO` | No | `true` | Ejecuta el rsync local con `sudo` (te pide tu password). | `true` |

### Dump y restore

| Variable | Obligatoria | Por defecto | Qué hace | Ejemplo |
|---|---|---|---|---|
| `DUMP_FORMAT` | No | `dir` | `dir`: `pg_dump -Fd` + `pg_restore` (rápido). `sql`: SQL plano + `psql` (como los scripts antiguos). | `"sql"` |
| `DUMP_JOBS` | No | `1` | Procesos paralelos del `pg_dump` **en producción**. Súbelo solo si el servidor lo aguanta. Solo formato `dir`. | `8` |
| `RESTORE_JOBS` | No | `4` | Procesos paralelos del `pg_restore` en tu máquina. | `8` |
| `COMPRESS_LEVEL` | No | `5` | Compresión de `pg_dump -Fd` (0-9). Solo formato `dir`. | `5` |
| `PG_DUMP_OPTS` | No | vacío | Opciones extra para `pg_dump`. | `"--no-owner"` |
| `PG_RESTORE_OPTS` | No | vacío | Opciones extra para `pg_restore`. | `"--no-owner"` |

### Después de restaurar

Orden de ejecución: update-all → módulos → scripts → neutralize.

| Variable | Obligatoria | Por defecto | Qué hace | Ejemplo |
|---|---|---|---|---|
| `RUN_UPDATE` | No | `true` | Ejecuta `click-odoo-update --update-all`. `--no-update` lo salta una vez. | `false` |
| `POST_MODULES` | No | `()` | Módulos a instalar con `-i`. | `("web_environment_ribbon")` |
| `POST_SCRIPTS` | No | `()` | Scripts python que se ejecutan con `odoo shell`; ruta relativa a `LOCAL_DOCKER_PATH`. Si no existe, avisa y sigue. | `("scripts/dev_set_user_passwords.py")` |
| `NEUTRALIZE` | No | `true` | Ejecuta `odoo neutralize` (desactiva crons, correo saliente…). `--no-neutralize` lo salta una vez. | `false` |

### Filestore y permisos (sudo)
En casi todos los proyectos el filestore está en un volumen de docker
(`/var/lib/docker/volumes/<carpeta>_filestore/_data/filestore/<bbdd>/`), que solo puede
leer/escribir root. Por eso los dos lados usan sudo por defecto:

- `REMOTE_RSYNC_SUDO=true` → `rsync --rsync-path="sudo rsync"`. El usuario SSH necesita
  **sudo sin password** en el servidor.
- `LOCAL_RSYNC_SUDO=true` → el rsync local corre con `sudo` (te pide tu password) y la
  carpeta destino se crea con `sudo mkdir -p`.

Caso **locotoo**: el filestore remoto está en una carpeta normal del host con permisos de
lectura (`/opt/odoo/filestore_v18/prod/`) → `REMOTE_RSYNC_SUDO=false`. Escribe la barra
final en `REMOTE_FILESTORE`: copia el contenido de la carpeta.

## Autenticación

Orden de prioridad: `SSH_KEY` → `SSH_PASS` / `SSH_PASS_CMD` → agente/claves por defecto de `ssh`.
El password se entrega a `sshpass` por variable de entorno (no aparece en `ps`).
`StrictHostKeyChecking=accept-new`: acepta hosts nuevos pero avisa si cambia la clave
de uno conocido.

## Seguridad y advertencias

- Los `conf/*.conf` contienen passwords: están en `.gitignore` y el script exige `chmod 600`.
  No los subas ni los incluyas en zips que compartas.
- Un `.conf` es código bash (se carga con `source`): lee los que te pasen otras personas.
- Es **destructivo en local** por diseño: borra y recrea `LOCAL_DB`, y con `--filestore`
  el rsync usa `--delete` sobre `LOCAL_FILESTORE`. Úsalo solo en entornos de desarrollo.
- Si el restore falla a medias, `LOCAL_DB` queda sin restaurar: relanza con `--from-local`.

## Mantenimiento: cómo está organizado el script

Una función por etapa (`space_check`, `remote_dump`, `fetch_archive`, `extract_archive`,
`local_restore`, `sync_filestore`, `post_restore`, `rotate_backups`) y un `main` corto que
las llama en orden. Para añadir un paso, escribe su función y llámala desde `main`.
Para probar cambios: `bash -n odoo-prod2local.sh`, `shellcheck odoo-prod2local.sh` y
`--dry-run` con un `.conf` de prueba.
