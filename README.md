# odoo-prod2local

Copia una base de datos Odoo (Doodba + docker compose) desde un servidor remoto
a tu entorno local por SSH, con o sin filestore. Bash puro: solo `ssh`, `scp`,
`tar`, `rsync` (filestore), `docker compose` y, si usas password, `sshpass`.

## Uso

```bash
./odoo-prod2local.sh miproyecto                 # solo BBDD
./odoo-prod2local.sh miproyecto --filestore     # BBDD + filestore (rsync)
./odoo-prod2local.sh miproyecto --no-update --no-neutralize
./odoo-prod2local.sh miproyecto --dry-run       # ver la configuración resuelta
./odoo-prod2local.sh --list
```

## Añadir un proyecto

```bash
cp conf/_example.conf conf/miproyecto.conf
chmod 600 conf/miproyecto.conf      # el script se niega a leerlo si no
$EDITOR conf/miproyecto.conf
```

Los `conf/*.conf` están en `.gitignore`: las claves nunca van al repositorio.
Otra carpeta de configs: `odoo-prod2local_CONF_DIR=/ruta ./odoo-prod2local.sh proyecto`,
o pasa directamente la ruta de un `.conf`.

## Qué hace

1. `pg_dump` en remoto dentro del contenedor (`DUMP_FORMAT=dir` → `-Fd -j`; `sql` → SQL plano).
2. Empaqueta, descarga por `scp` y descomprime en `LOCAL_BACKUP_DIR`.
3. Para el compose local, recrea la BBDD y restaura (`pg_restore -j` o `psql`).
4. Con `--filestore`: `rsync --delete` del filestore remoto al volumen local.
5. `update-all`, módulos (`POST_MODULES`), scripts (`POST_SCRIPTS`) y `neutralize`.
6. Arranca, y conserva solo los `KEEP` últimos `*.tar.gz` (remoto y local).

## Autenticación

`SSH_KEY` (clave privada) → `SSH_PASS` / `SSH_PASS_CMD` (sshpass) → agente/claves por defecto.
El password se pasa a sshpass por variable de entorno, no por línea de comandos.
Para el rsync local sobre el volumen docker se usa `sudo` (te pide tu password;
nada de passwords de sudo en ficheros). `LOCAL_RSYNC_SUDO=false` lo desactiva.
