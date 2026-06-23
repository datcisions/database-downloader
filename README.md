# Database Backup — RDS PostgreSQL → Google Drive

Script de backup automático que descarga un dump de tu base de datos en AWS RDS, lo comprime y lo sube a una carpeta de Google Drive. Diseñado para ejecutarse periódicamente via cron en un servidor Ubuntu.

## Índice

1. [Requisitos previos](#1-requisitos-previos)
2. [Instalación](#2-instalación)
3. [Credenciales de AWS RDS](#3-credenciales-de-aws-rds)
4. [Credenciales de Google Drive](#4-credenciales-de-google-drive)
5. [Configuración del archivo .env](#5-configuración-del-archivo-env)
6. [Prueba manual](#6-prueba-manual)
7. [Configurar el cron job](#7-configurar-el-cron-job)
8. [Estructura de archivos](#8-estructura-de-archivos)
9. [Política de retención](#9-política-de-retención)
10. [Solución de problemas](#10-solución-de-problemas)

---

## 1. Requisitos previos

- Ubuntu 20.04 o superior
- Acceso por SSH al servidor
- Acceso a la consola de AWS con permisos sobre el RDS
- Una cuenta de Google con Google Drive
- El servidor debe tener salida a internet (para conectar a RDS y subir a Drive)

---

## 2. Instalación

Clona o copia este repositorio en tu servidor y ejecuta el script de instalación:

```bash
git clone <url-del-repo> ~/database-downloader
cd ~/database-downloader
./setup.sh
```

El script instala automáticamente:

- `postgresql-client` — para ejecutar `pg_dump`
- `gzip` — para comprimir el dump
- `rclone` — para subir archivos a Google Drive
- Crea el directorio `/var/backups/db-dumps/` con los permisos correctos
- Genera el archivo `.env` a partir de la plantilla

> Si prefieres instalar manualmente: `sudo apt-get install -y postgresql-client gzip` y luego `curl https://rclone.org/install.sh | sudo bash`

---

## 3. Credenciales de AWS RDS

Necesitas cuatro datos de tu instancia RDS: el **host**, el **puerto**, el **nombre de la base de datos** y un **usuario con permisos de lectura**.

### 3.1 Obtener el endpoint (host) y puerto

1. Ve a la [consola de AWS](https://console.aws.amazon.com/rds/)
2. En el menú izquierdo: **Databases**
3. Haz clic en el nombre de tu instancia RDS
4. En la sección **Connectivity & security**, copia el valor de **Endpoint**

   ```
   Ejemplo: mydb.c9akciq32.us-east-1.rds.amazonaws.com
   Puerto por defecto de PostgreSQL: 5432
   ```

### 3.2 Obtener el nombre de la base de datos

En la misma página de la instancia, pestaña **Configuration**, busca el campo **DB name**.

Si tienes varias bases de datos dentro de la instancia, puedes listarlas conectándote primero:

```bash
psql -h <endpoint> -U <usuario> -l
```

### 3.3 Crear un usuario de solo lectura (recomendado)

En lugar de usar el usuario administrador, crea uno específico para backups. Conéctate a tu base de datos y ejecuta:

```sql
-- Crear el usuario
CREATE USER backup_user WITH PASSWORD 'contraseña-segura';

-- Darle acceso de solo lectura a la base de datos
GRANT CONNECT ON DATABASE nombre_bd TO backup_user;
GRANT USAGE ON SCHEMA public TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup_user;

-- Para que el permiso aplique también a tablas futuras
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup_user;
```

### 3.4 Permitir la conexión desde tu servidor (Security Group)

El servidor Ubuntu debe poder conectarse al puerto 5432 del RDS. Si la conexión falla, revisa el Security Group de tu instancia RDS:

1. En la consola RDS, pestaña **Connectivity & security** → haz clic en el **VPC security group**
2. Pestaña **Inbound rules** → **Edit inbound rules**
3. Añade una regla:
   - **Type:** PostgreSQL
   - **Port:** 5432
   - **Source:** la IP pública de tu servidor Ubuntu (puedes obtenerla con `curl ifconfig.me`)

> Si tu servidor está dentro de la misma VPC que el RDS, usa la IP privada y no necesitas abrir el Security Group a internet.

### 3.5 Verificar la conexión

Desde tu servidor Ubuntu, prueba la conexión antes de configurar el backup:

```bash
psql -h <endpoint> -p 5432 -U backup_user -d nombre_bd -c "SELECT version();"
```

Si se conecta y muestra la versión de PostgreSQL, todo está correcto.

---

## 4. Credenciales de Google Drive

El script usa **rclone** para subir los archivos. Rclone se autentica con OAuth2, por lo que no necesitas gestionar claves de API manualmente — basta con autorizar la aplicación desde un navegador.

### 4.1 Configurar rclone

En tu servidor Ubuntu ejecuta:

```bash
rclone config
```

Sigue estos pasos dentro del asistente interactivo:

```
No remotes found, make a new one?
> n (New remote)

name> gdrive
```

```
Storage> drive
(busca "Google Drive" en la lista y escribe su número)
```

```
Google Application Client Id> (deja vacío, pulsa Enter)
Google Application Client Secret> (deja vacío, pulsa Enter)
scope> 1
(Full access — opción 1)
```

```
root_folder_id> (deja vacío, pulsa Enter)
service_account_file> (deja vacío, pulsa Enter)
Edit advanced config? > n
```

### 4.2 Autenticar desde un servidor sin interfaz gráfica

Como el servidor no tiene navegador, rclone ofrece autenticación remota:

```
Use auto config?
> n
```

Rclone te mostrará un mensaje similar a este:

```
Please go to the following link: https://accounts.google.com/o/oauth2/auth?...
Log in and authorize rclone for access
Enter verification code>
```

**En tu equipo local (con navegador):**

1. Abre la URL que te mostró rclone
2. Inicia sesión con tu cuenta de Google
3. Haz clic en **Permitir**
4. Copia el código de verificación que aparece en pantalla
5. Pégalo en la terminal del servidor y pulsa Enter

```
Configure this as a Shared Drive (Team Drive)?
> n

Is this OK?
> y
```

### 4.3 Verificar la conexión a Google Drive

```bash
rclone lsd gdrive:
```

Deberías ver el listado de carpetas de tu Google Drive. Si quieres crear la carpeta de backups manualmente:

```bash
rclone mkdir gdrive:database-backups
```

> El script crea la carpeta automáticamente en la primera ejecución si no existe.

### 4.4 Probar una subida de prueba

```bash
echo "test" > /tmp/rclone-test.txt
rclone copy /tmp/rclone-test.txt gdrive:database-backups/
rclone ls gdrive:database-backups/
```

---

## 5. Configuración del archivo .env

El script de instalación crea `.env` automáticamente. Ábrelo y rellena los valores:

```bash
nano .env
```

| Variable | Descripción | Ejemplo |
|---|---|---|
| `DB_HOST` | Endpoint del RDS | `mydb.xxxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | Puerto de PostgreSQL | `5432` |
| `DB_NAME` | Nombre de la base de datos | `production_db` |
| `DB_USER` | Usuario de la base de datos | `backup_user` |
| `DB_PASSWORD` | Contraseña del usuario | `contraseña-segura` |
| `RCLONE_REMOTE` | Nombre del remote de rclone | `gdrive` |
| `RCLONE_DEST_PATH` | Carpeta destino en Drive | `database-backups` |
| `LOCAL_BACKUP_DIR` | Carpeta local temporal | `/var/backups/db-dumps` |
| `LOCAL_RETENTION_DAYS` | Días que se guardan copias locales | `3` |
| `DRIVE_RETENTION_COUNT` | Máximo de backups en Drive (0 = sin límite) | `30` |
| `NOTIFY_EMAIL` | Email para alertas de error (opcional) | `admin@example.com` |

El archivo `.env` contiene contraseñas: asegúrate de que solo tu usuario pueda leerlo:

```bash
chmod 600 .env
```

---

## 6. Prueba manual

Antes de activar el cron, ejecuta el script manualmente para verificar que todo funciona:

```bash
./backup.sh
```

Si funciona correctamente verás una salida similar a:

```
[2026-06-23 10:00:00] [INFO] ========================================================
[2026-06-23 10:00:00] [INFO] Iniciando backup de production_db @ mydb.xxxx.rds.amazonaws.com
[2026-06-23 10:00:00] [INFO] Realizando pg_dump y comprimiendo → production_db_20260623_100000.dump.gz
[2026-06-23 10:00:45] [INFO] Dump completado: production_db_20260623_100000.dump.gz (124M)
[2026-06-23 10:00:45] [INFO] Subiendo a Google Drive → gdrive:database-backups/production_db_20260623_100000.dump.gz
[2026-06-23 10:02:10] [INFO] Subida completada.
[2026-06-23 10:02:10] [INFO] Backup finalizado con éxito: production_db_20260623_100000.dump.gz
```

Verifica también que el archivo aparece en Google Drive:

```bash
rclone ls gdrive:database-backups/
```

---

## 7. Configurar el cron job

### 7.1 Usando el script incluido

```bash
# Ejecutar a las 02:00 (por defecto)
./install-cron.sh

# Ejecutar a las 03:30
./install-cron.sh 3 30
```

### 7.2 Manualmente con crontab

```bash
crontab -e
```

Añade la línea (ajusta la ruta si instalaste el repo en otro directorio):

```cron
# Backup diario a las 02:00
0 2 * * * /home/pabloblanco/database-downloader/backup.sh >> /var/backups/db-dumps/backup.log 2>&1
```

Guarda y cierra. Verifica que se guardó:

```bash
crontab -l
```

### 7.3 Elegir la hora adecuada

Ejecuta el backup en horas de bajo tráfico para minimizar el impacto en producción. Entre las 02:00 y las 04:00 suele ser una buena franja.

---

## 8. Estructura de archivos

```
database-downloader/
├── backup.sh           # Script principal — dump + comprimir + subir
├── setup.sh            # Instalador de dependencias del sistema
├── install-cron.sh     # Instala/actualiza el cron job
├── .env.example        # Plantilla de configuración (sin datos reales)
├── .env                # Tu configuración real (NO subir a git)
└── README.md           # Esta guía

/var/backups/db-dumps/  # Directorio de dumps temporales (creado por setup.sh)
├── backup.log          # Log de todas las ejecuciones
├── nombre_bd_20260623_020000.dump.gz
└── ...
```

> **Importante:** El archivo `.env` nunca debe subirse a un repositorio git. Si usas git, verifica que `.env` está en tu `.gitignore`.

---

## 9. Política de retención

| Ubicación | Variable | Comportamiento |
|---|---|---|
| Local (`/var/backups/db-dumps/`) | `LOCAL_RETENTION_DAYS` | Elimina dumps con más de N días |
| Google Drive | `DRIVE_RETENTION_COUNT` | Conserva solo los N backups más recientes |

La limpieza se ejecuta automáticamente al final de cada backup. Los archivos más antiguos se eliminan primero.

---

## 10. Solución de problemas

### El comando pg_dump no encuentra el servidor

```
pg_dump: error: connection to server at "..." failed: Connection refused
```

- Verifica que el Security Group del RDS permite el tráfico desde la IP de tu servidor en el puerto 5432.
- Comprueba que el endpoint en `.env` es correcto (sin `https://`, sin barra final).
- Prueba: `psql -h <DB_HOST> -p <DB_PORT> -U <DB_USER> -d <DB_NAME>`

### Error de autenticación en PostgreSQL

```
pg_dump: error: connection to server failed: FATAL: password authentication failed
```

- Verifica `DB_USER` y `DB_PASSWORD` en `.env`.
- Comprueba que el usuario existe en la base de datos y tiene los permisos necesarios (ver sección 3.3).

### rclone no puede conectarse a Google Drive

```
Failed to copy: googleapi: Error 401: Invalid Credentials
```

El token de autenticación expiró. Vuelve a autenticar:

```bash
rclone config reconnect gdrive:
```

### El cron no ejecuta el script

Verifica que el script tiene permisos de ejecución:

```bash
chmod +x backup.sh
```

Los cron jobs no cargan las variables de entorno del usuario. El script carga `.env` explícitamente, por lo que esto no debería ser un problema — pero asegúrate de que la ruta al `.env` en `backup.sh` es absoluta.

Puedes ver si el cron intentó ejecutar el script en los logs del sistema:

```bash
grep CRON /var/log/syslog | tail -20
```

### Ver los logs del backup

```bash
tail -f /var/backups/db-dumps/backup.log
```

### Restaurar un backup

Para restaurar uno de los dumps a una base de datos local o en otro RDS:

```bash
# Descargar el backup de Drive
rclone copy gdrive:database-backups/production_db_20260623_020000.dump.gz /tmp/

# Descomprimir y restaurar
gunzip -c /tmp/production_db_20260623_020000.dump.gz | psql -h <host> -U <user> -d <dbname>
```
