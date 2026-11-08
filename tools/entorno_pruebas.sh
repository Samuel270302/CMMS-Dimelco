#!/usr/bin/env bash
# Entorno de pruebas del CMMS: PostgreSQL local con el esquema completo (001-019), datos
# de prueba de backlog y de preventivos, y la app web servida en un solo puerto.
# Los datos de preventivos entran con tools/traer_preventivos.mjs, la misma copia que se
# usará en producción. Nada de esto toca Supabase.
#
#   tools/entorno_pruebas.sh            arranca (la primera vez crea la base y siembra datos)
#   tools/entorno_pruebas.sh reiniciar  borra la base de pruebas y la vuelve a crear
#   tools/entorno_pruebas.sh detener    apaga la app y la base (los datos quedan)
#   tools/entorno_pruebas.sh estado     dice si está corriendo
#
# Los datos quedan en .pruebas/ (no se sube al repositorio).
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$RAIZ/.pruebas"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)}"
export PGPORT="${PGPORT:-55440}"
export PGHOST="$DIR/pg"
export PUERTO_APP="${PUERTO_APP:-5180}"
export CLAVE_PRUEBAS="${CLAVE_PRUEBAS:-prueba}"
COMO=""; [ "$(id -u)" = "0" ] && COMO="runuser -u postgres --"
psql_db() { PGOPTIONS="-c client_min_messages=warning" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q -X "${@:2}"; }

detener() {
  if [ -f "$DIR/app.pid" ]; then kill "$(cat "$DIR/app.pid")" 2>/dev/null || true; rm -f "$DIR/app.pid"; fi
  if [ -d "$DIR/pg/datos" ]; then $COMO "$PGBIN/pg_ctl" -D "$DIR/pg/datos" stop -m fast >/dev/null 2>&1 || true; fi
}

arrancar_base() {
  if ! $COMO "$PGBIN/pg_ctl" -D "$DIR/pg/datos" status >/dev/null 2>&1; then
    $COMO "$PGBIN/pg_ctl" -D "$DIR/pg/datos" -o "-p $PGPORT -k $DIR/pg" -l "$DIR/pg/log" start -w >/dev/null
  fi
}

crear() {
  echo "Creando la base de pruebas en $DIR"
  mkdir -p "$DIR/pg"
  [ -n "$COMO" ] && chown -R postgres "$DIR/pg"
  $COMO "$PGBIN/initdb" -D "$DIR/pg/datos" -U postgres -A trust >/dev/null
  arrancar_base
  psql_db postgres -c "create database prev" -c "create database cmms"

  echo "  base de origen con el esquema de Control de Preventivos 0.6.0 y datos de prueba"
  psql_db prev -f "$RAIZ/tools/base_local.sql"
  psql_db prev <<'SQL'
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid $$;
create publication supabase_realtime;
SQL
  for f in "$RAIZ"/tests/preventivos_0.6.0/*.sql; do psql_db prev -f "$f"; done
  psql_db prev -f "$RAIZ/tests/semilla_preventivos.sql" >/dev/null

  echo "  base del CMMS (migraciones 001-019) con datos de backlog"
  psql_db cmms -f "$RAIZ/tools/base_local.sql"
  for f in "$RAIZ"/supabase/migrations/*.sql; do psql_db cmms -f "$f"; done
  psql_db cmms -f "$RAIZ/tests/semilla_e2e.sql" >/dev/null

  echo "  copia de preventivos con tools/traer_preventivos.mjs"
  node "$RAIZ/tools/traer_preventivos.mjs" \
    --origen "postgresql://postgres@localhost:$PGPORT/prev?host=$DIR/pg" \
    --destino "postgresql://postgres@localhost:$PGPORT/cmms?host=$DIR/pg" --grabar | sed 's/^/    /'

  echo "  backlogs listos para programar, capacidad del taller y HH estándar por gama"
  psql_db cmms -f "$RAIZ/tests/semilla_programacion.sql" >/dev/null
}

# Base ya creada: aplica las migraciones nuevas sin tocar los datos (igual que en producción).
actualizar() {
  echo "Aplicando migraciones nuevas a la base de pruebas (los datos se conservan)"
  bash "$RAIZ/tools/armar_instalacion.sh" >/dev/null
  psql_db cmms --single-transaction -f "$RAIZ/supabase/instalar_todo.sql" >/dev/null
}

case "${1:-iniciar}" in
  detener) detener; echo "Entorno de pruebas detenido"; exit 0 ;;
  estado)
    if [ -f "$DIR/app.pid" ] && kill -0 "$(cat "$DIR/app.pid")" 2>/dev/null; then
      echo "Corriendo en http://localhost:$PUERTO_APP"
    else
      echo "Detenido"
    fi
    exit 0 ;;
  reiniciar) detener; rm -rf -- "$RAIZ/.pruebas/pg"; crear ;;
  iniciar)
    detener
    if [ -d "$DIR/pg/datos" ]; then arrancar_base; actualizar; else crear; fi ;;
  *) echo "Uso: tools/entorno_pruebas.sh [iniciar|reiniciar|detener|estado]"; exit 2 ;;
esac

echo "Compilando la app web"
(cd "$RAIZ" && VITE_SUPABASE_URL=mismo-origen VITE_SUPABASE_ANON_KEY=llave-anon-de-prueba-0123456789 \
  npx vite build --mode web --logLevel error)

nohup node "$RAIZ/tools/entorno_pruebas.mjs" > "$DIR/app.log" 2>&1 &
echo $! > "$DIR/app.pid"
curl -sf --retry 30 --retry-connrefused --retry-delay 1 "http://localhost:$PUERTO_APP/" >/dev/null \
  || { echo "La app no respondió; ver $DIR/app.log"; exit 1; }
cat <<EOF

Entorno de pruebas listo en http://localhost:$PUERTO_APP
Contraseña de todos los usuarios: $CLAVE_PRUEBAS
  admin@prueba      Administrador, todas las unidades
  cap@prueba        Capturador de HEMCO
  cap.vtn@prueba    Capturador de Veta Nueva
  cap.prev@prueba   Capturador de Veta Nueva (venía solo en preventivos)
EOF
