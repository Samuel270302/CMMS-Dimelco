#!/usr/bin/env bash
# Ensayo de la copia de preventivos a la base del CMMS, en dos PostgreSQL locales:
#   prev  esquema de Control de Preventivos 0.6.0 (tests/preventivos_0.6.0) + tests/semilla_preventivos.sql
#   cmms  migraciones del CMMS (backlog 001-018 + 019) + tests/semilla_e2e.sql (datos de backlog)
# Corre tools/traer_preventivos.mjs en ensayo y en grabar, revisa que los datos de backlog
# no cambien, que una segunda copia se rechace y que las políticas por unidad funcionen.
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)}"
DIR="$(mktemp -d)"
PUERTO="${PUERTO:-55433}"
COMO=""; [ "$(id -u)" = "0" ] && { chown -R postgres "$DIR"; COMO="runuser -u postgres --"; }
trap '[ $? -ne 0 ] && tail -5 "$DIR/log" >&2 2>/dev/null; $COMO "$PGBIN/pg_ctl" -D "$DIR/datos" stop -m fast >/dev/null 2>&1 || true; rm -rf "$DIR"' EXIT
$COMO "$PGBIN/initdb" -D "$DIR/datos" -U postgres -A trust >/dev/null
$COMO "$PGBIN/pg_ctl" -D "$DIR/datos" -o "-p $PUERTO -k $DIR" -l "$DIR/log" start -w >/dev/null
export PGOPTIONS="-c client_min_messages=warning"
psql_db() { psql -h "$DIR" -p "$PUERTO" -U postgres -d "$1" -v ON_ERROR_STOP=1 -q -X "${@:2}"; }
psql_db postgres -c "create database prev" -c "create database cmms"

echo "== Base de preventivos 0.6.0"
psql_db prev -f "$RAIZ/tools/base_local.sql"
psql_db prev <<'SQL'
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid $$;
create publication supabase_realtime;
SQL
for f in "$RAIZ"/tests/preventivos_0.6.0/*.sql; do psql_db prev -f "$f"; done
psql_db prev -f "$RAIZ/tests/semilla_preventivos.sql"

echo "== Base del CMMS con datos de backlog"
psql_db cmms -f "$RAIZ/tools/base_local.sql"
for f in "$RAIZ"/supabase/migrations/*.sql; do psql_db cmms -f "$f"; done
psql_db cmms -f "$RAIZ/tests/semilla_e2e.sql" >/dev/null

HUELLA="select string_agg(t || ':' || n, ' ' order by t) from (
  select 'backlogs' t, count(*) n from backlogs union all select 'backlog_hh', count(*) from backlog_hh
  union all select 'backlog_repuestos', count(*) from backlog_repuestos union all select 'backlog_eventos', count(*) from backlog_eventos
  union all select 'capacidad', count(*) from capacidad_taller union all select 'familias', count(*) from familias
  union all select 'hh', sum(hh)::bigint from backlog_hh) x"
ANTES=$(psql_db cmms -At -c "$HUELLA")

ORIGEN="postgresql://postgres@localhost:$PUERTO/prev?host=$DIR"
DESTINO="postgresql://postgres@localhost:$PUERTO/cmms?host=$DIR"

echo "== Ensayo (se deshace)"
node "$RAIZ/tools/traer_preventivos.mjs" --origen "$ORIGEN" --destino "$DESTINO"
[ "$(psql_db cmms -At -c 'select count(*) from lecturas')" = "0" ] || { echo "El ensayo dejó datos"; exit 1; }

echo "== Copia (grabar)"
node "$RAIZ/tools/traer_preventivos.mjs" --origen "$ORIGEN" --destino "$DESTINO" --grabar

DESPUES=$(psql_db cmms -At -c "$HUELLA")
[ "$ANTES" = "$DESPUES" ] || { echo "Cambiaron los datos de backlog: $ANTES -> $DESPUES"; exit 1; }
echo "Datos de backlog sin cambios: $DESPUES"

echo "== Segunda copia (debe rechazarse)"
if node "$RAIZ/tools/traer_preventivos.mjs" --origen "$ORIGEN" --destino "$DESTINO" --grabar >/dev/null 2>&1; then
  echo "La segunda copia no se rechazó"; exit 1
fi

echo "== instalar_todo.sql otra vez sobre la base con datos (debe poder repetirse)"
CONTEO="select (select count(*) from lecturas) || '/' || (select count(*) from registros_pm) || '/' || (select count(*) from backlogs) || '/' || (select count(*) from equipos)"
C1=$(psql_db cmms -At -c "$CONTEO")
psql_db cmms --single-transaction -f "$RAIZ/supabase/instalar_todo.sql" >/dev/null
C2=$(psql_db cmms -At -c "$CONTEO")
[ "$C1" = "$C2" ] || { echo "instalar_todo.sql cambió los datos: $C1 -> $C2"; exit 1; }
echo "Sin cambios en lecturas/PM/backlogs/equipos: $C2"

echo "== Comprobaciones en la base del CMMS"
psql_db cmms <<'SQL'
do $$
declare n int; v json;
begin
  -- PS011 de HEMCO es el mismo equipo para backlog y preventivos.
  select count(*) into n from equipos where cod_interno = 'PS011'
    and unidad_id = (select id from unidades where sigla = 'HEM');
  if n <> 1 then raise exception 'PS011 de HEMCO quedó % veces', n; end if;
  select count(*) into n from backlogs b join componentes c on c.equipo_id = b.equipo_id;
  if n = 0 then raise exception 'Ningún backlog quedó ligado a un equipo con horómetro'; end if;
  -- El usuario que solo estaba en preventivos entra con su perfil.
  select count(*) into n from perfiles where correo = 'cap.prev@prueba' and rol = 'capturador' and activo
    and unidades = array[(select id from unidades where sigla = 'VTN')];
  if n <> 1 then raise exception 'Perfil de cap.prev@prueba no copiado'; end if;
  -- El capturador que ya estaba conserva el perfil de backlog.
  select count(*) into n from perfiles where correo = 'cap@prueba' and rol = 'capturador';
  if n <> 1 then raise exception 'Se cambió el perfil de cap@prueba'; end if;
  -- Las validaciones de captura siguen activas después de la copia.
  v := validar_lectura((select c.id from componentes c join equipos e on e.id = c.equipo_id
                        where e.cod_interno = 'PS011'), current_date, 'Dia', 1);
  if v->>'nivel' <> 'error' then raise exception 'validar_lectura no rechaza una baja: %', v; end if;
  if not exists (select 1 from pg_trigger where tgname = 'validar_lectura' and tgenabled = 'O') then
    raise exception 'Disparador validar_lectura quedó apagado';
  end if;
end $$;

-- Políticas: el capturador de Veta Nueva solo ve Veta Nueva.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000e"}', false);
do $$
declare n int;
begin
  select count(distinct unidad) into n from v_control_pm;
  if n <> 1 or (select min(unidad) from v_control_pm) <> 'Veta Nueva' then
    raise exception 'El capturador de Veta Nueva ve otras unidades en Control PM';
  end if;
  insert into lecturas (componente_id, fecha, turno, lectura)
  select c.id, current_date, 'Dia', ul.lectura + 3 from componentes c
  join equipos e on e.id = c.equipo_id join v_ultima_lectura ul on ul.componente_id = c.id
  where e.cod_interno = 'PS012';
  begin
    insert into lecturas (componente_id, fecha, turno, lectura)
    select c.id, current_date, 'Dia', 1 from componentes c join equipos e on e.id = c.equipo_id
    where e.cod_interno = 'PS013';
    get diagnostics n = row_count;
    if n > 0 then raise exception 'El capturador de Veta Nueva grabó en HEMCO'; end if;
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ENSAYO OK' as resultado;
SQL
