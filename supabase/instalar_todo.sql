-- Instalación completa de la base del CMMS (generado por tools/armar_instalacion.sh).
-- Backlog 001 a 018 y preventivo 019. Se puede repetir sobre la base de backlog en uso:
-- solo agrega lo que falta. No ejecutar en producción sin la aprobación de la fusión.

-- ===== 001_base.sql =====
-- Base de la app de backlog: unidades, perfiles, parámetros y funciones de sesión.
-- Proyecto Supabase propio, separado del de preventivos.

create table if not exists unidades (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  sigla   text not null unique check (sigla ~ '^[A-Z]{3}$'),  -- va en el folio: BL-HEM-000123
  activo  boolean not null default true,
  orden   integer not null default 0
);
insert into unidades (nombre, sigla, orden) values
  ('HEMCO', 'HEM', 1), ('Veta Nueva', 'VTN', 2), ('Mina La India', 'MLI', 3), ('Explotec', 'EXP', 4)
on conflict (nombre) do nothing;

-- Los perfiles nuevos nacen inactivos y sin unidad; el admin los activa en Usuarios.
create table if not exists perfiles (
  user_id    uuid primary key,
  nombre     text not null,
  correo     text,
  rol        text not null default 'capturador' check (rol in ('admin', 'capturador', 'invitado')),
  activo     boolean not null default false,
  unidad_id  uuid references unidades(id),
  creado_en  timestamptz not null default now(),
  constraint perfiles_unidad_requerida check (rol = 'admin' or not activo or unidad_id is not null)
);

create table if not exists parametros (
  clave        text primary key,
  valor        numeric,
  valor_texto  text,
  descripcion  text
);

-- Plazos provisionales: se reemplazan por los de HEMCO en la pantalla de parámetros.
insert into parametros (clave, valor, descripcion) values
  ('plazo_p1_dias',  2, 'Días para atender un backlog P1 desde su detección (provisional)'),
  ('plazo_p2_dias',  7, 'Días para atender un backlog P2 desde su detección (provisional)'),
  ('plazo_p3_dias', 30, 'Días para atender un backlog P3 desde su detección (provisional)'),
  ('plazo_p4_dias', 90, 'Días para atender un backlog P4 desde su detección (provisional)')
on conflict (clave) do nothing;
insert into parametros (clave, valor, valor_texto, descripcion) values
  ('fecha_referencia', null, null, 'Solo pruebas: fija el «hoy» de las vistas (YYYY-MM-DD). Vacío = fecha actual')
on conflict (clave) do nothing;

create or replace function hoy() returns date
language sql stable as $$
  select coalesce(
    (select nullif(valor_texto, '')::date from parametros where clave = 'fecha_referencia'),
    current_date)
$$;

create or replace function param(p_clave text) returns numeric
language sql stable as $$
  select valor from parametros where clave = p_clave
$$;

-- Usuario de la sesión tomado del token (lo mismo que auth.uid()); así las funciones
-- también corren en una base local de pruebas sin el esquema auth.
create or replace function usuario_sesion() returns uuid
language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid
$$;

create or replace function rol_actual() returns text
language sql stable security definer set search_path = public as $$
  select rol from perfiles where user_id = usuario_sesion() and activo
$$;

create or replace function unidad_actual() returns uuid
language sql stable security definer set search_path = public as $$
  select unidad_id from perfiles where user_id = usuario_sesion() and activo
$$;

-- El admin ve y graba en todas las unidades; capturador e invitado, solo en la suya.
create or replace function unidad_permitida(p_unidad uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(rol_actual() = 'admin', false)
      or (p_unidad is not null and p_unidad = unidad_actual())
$$;

-- ===== 002_catalogos.sql =====
-- Catálogos: equipos (importados una vez desde preventivos), sistemas, especialidades
-- y capacidad del taller en HH por semana.

create table if not exists equipos (
  id           uuid primary key default gen_random_uuid(),
  unidad_id    uuid not null references unidades(id),
  cod_interno  text not null,          -- Scooptram #1, Boomer #2...
  cod_sap      text,
  modelo       text not null,
  flota        text,                   -- Scooptram, Jumbo, Empernador, Camión...
  activo       boolean not null default true,
  creado_en    timestamptz not null default now(),
  constraint equipos_unidad_cod_interno_key unique (unidad_id, cod_interno)
);
create index if not exists equipos_unidad on equipos (unidad_id);

create table if not exists sistemas (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  activo  boolean not null default true,
  orden   integer not null default 0
);
insert into sistemas (nombre, orden) values
  ('Motor', 1), ('Transmisión', 2), ('Sistema hidráulico', 3), ('Sistema eléctrico', 4),
  ('Frenos', 5), ('Dirección', 6), ('Estructura y chasis', 7), ('Neumáticos', 8),
  ('Perforadora', 9), ('Empernadora', 10), ('Compresor', 11), ('Cabina y seguridad', 12),
  ('Otro', 99)
on conflict (nombre) do nothing;

create table if not exists especialidades (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  activo  boolean not null default true,
  orden   integer not null default 0
);
insert into especialidades (nombre, orden) values
  ('Mecánico', 1), ('Eléctrico', 2), ('Hidráulico', 3), ('Soldador', 4), ('Llantero', 5)
on conflict (nombre) do nothing;

-- Capacidad disponible por unidad y especialidad. La vigente es la de mayor
-- vigente_desde que no pasa de hoy(); un cambio de dotación se carga como fila nueva.
create table if not exists capacidad_taller (
  id               uuid primary key default gen_random_uuid(),
  unidad_id        uuid not null references unidades(id),
  especialidad_id  uuid not null references especialidades(id),
  hh_semana        numeric not null check (hh_semana >= 0),
  vigente_desde    date not null default current_date,
  creado_en        timestamptz not null default now(),
  unique (unidad_id, especialidad_id, vigente_desde)
);

-- ===== 003_backlog.sql =====
-- Backlog: trabajos pendientes de equipo, con HH por especialidad, repuestos,
-- bitácora y fotos. Nada se borra físico: un backlog se rechaza o anula con motivo.

create table if not exists backlogs (
  id                 uuid primary key default gen_random_uuid(),
  folio              text not null unique,                 -- BL-HEM-000123, lo pone el disparador
  unidad_id          uuid not null references unidades(id),-- la del equipo, la pone el disparador
  equipo_id          uuid not null references equipos(id),
  sistema_id         uuid not null references sistemas(id),
  descripcion        text not null check (length(trim(descripcion)) >= 5),
  origen             text not null check (origen in
                       ('Inspección','PM','Operador','Falla','Análisis de aceite','Otro')),
  prioridad          text not null check (prioridad in ('P1','P2','P3','P4')),
  estado             text not null default 'Identificado' check (estado in
                       ('Identificado','En planificación','Esperando repuestos','Listo para programar',
                        'Programado','Ejecutado','Cerrado','Rechazado','Anulado')),
  fecha_deteccion    date not null default hoy(),
  fecha_limite       date,                                 -- detección + plazo de la prioridad
  reportado_por      text,                                 -- quien vio el hallazgo (puede no tener usuario)
  aviso_sap          text,
  ot_sap             text,
  semana_programada  date,                                 -- lunes de la semana
  fecha_programada   date,
  aprovechar_pm      boolean not null default false,
  fecha_ejecucion    date,
  reprogramaciones   integer not null default 0,
  motivo_anulacion   text,
  creado_por         uuid default usuario_sesion(),
  creado_en          timestamptz not null default now(),
  actualizado_en     timestamptz not null default now(),
  constraint backlogs_semana_lunes check (semana_programada is null or extract(isodow from semana_programada) = 1)
);
create index if not exists backlogs_unidad_estado on backlogs (unidad_id, estado);
create index if not exists backlogs_equipo on backlogs (equipo_id);

-- Correlativo de folio por unidad.
create table if not exists folios (
  unidad_id  uuid primary key references unidades(id),
  ultimo     integer not null default 0
);

create table if not exists backlog_hh (
  id               uuid primary key default gen_random_uuid(),
  backlog_id       uuid not null references backlogs(id),
  especialidad_id  uuid not null references especialidades(id),
  tipo             text not null check (tipo in ('estimada','real')),
  personas         numeric not null check (personas > 0),
  horas            numeric not null check (horas > 0),
  hh               numeric generated always as (personas * horas) stored,
  creado_por       uuid default usuario_sesion(),
  creado_en        timestamptz not null default now(),
  unique (backlog_id, especialidad_id, tipo)
);

create table if not exists backlog_repuestos (
  id              uuid primary key default gen_random_uuid(),
  backlog_id      uuid not null references backlogs(id),
  cod_sap         text not null check (length(trim(cod_sap)) > 0),
  descripcion     text,
  cantidad        numeric not null check (cantidad > 0),
  um              text not null default 'UN',
  solicitud_sap   text,                                    -- SolPed o reserva
  estado          text not null default 'Por pedir' check (estado in ('Por pedir','Pedido','Recibido')),
  fecha_estimada  date,
  fecha_recibido  date,
  creado_por      uuid default usuario_sesion(),
  creado_en       timestamptz not null default now()
);
create index if not exists backlog_repuestos_backlog on backlog_repuestos (backlog_id);

create table if not exists backlog_eventos (
  id               uuid primary key default gen_random_uuid(),
  backlog_id       uuid not null references backlogs(id),
  tipo             text not null check (tipo in ('estado','comentario','repuesto','reprogramación')),
  estado_anterior  text,
  estado_nuevo     text,
  texto            text,
  usuario          uuid default usuario_sesion(),
  creado_en        timestamptz not null default now()
);
create index if not exists backlog_eventos_backlog on backlog_eventos (backlog_id, creado_en);

-- Ruta en Storage: <unidad_id>/<backlog_id>/<archivo>.jpg (bucket backlog-fotos).
create table if not exists backlog_fotos (
  id          uuid primary key default gen_random_uuid(),
  backlog_id  uuid not null references backlogs(id),
  ruta        text not null unique,
  creado_por  uuid default usuario_sesion(),
  creado_en   timestamptz not null default now()
);

create or replace function plazo_prioridad(p_prioridad text) returns integer
language sql stable as $$
  select param('plazo_' || lower(p_prioridad) || '_dias')::integer
$$;

-- Alta: unidad del equipo, folio correlativo, plazo, estado inicial y evento de registro.
create or replace function tg_backlog_alta() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_sigla text;
  v_num   integer;
begin
  select e.unidad_id, u.sigla into new.unidad_id, v_sigla
  from equipos e join unidades u on u.id = e.unidad_id
  where e.id = new.equipo_id;
  if new.unidad_id is null then
    raise exception 'Equipo inexistente';
  end if;
  if new.fecha_deteccion > hoy() then
    raise exception 'La fecha de detección no puede ser futura';
  end if;
  insert into folios (unidad_id, ultimo) values (new.unidad_id, 1)
  on conflict (unidad_id) do update set ultimo = folios.ultimo + 1
  returning ultimo into v_num;
  new.folio := format('BL-%s-%s', v_sigla, lpad(v_num::text, 6, '0'));
  new.estado := 'Identificado';
  new.fecha_limite := new.fecha_deteccion + plazo_prioridad(new.prioridad);
  new.reprogramaciones := 0;
  new.creado_en := now();
  new.actualizado_en := now();
  return new;
end $$;

drop trigger if exists backlog_alta on backlogs;
create trigger backlog_alta before insert on backlogs
  for each row execute function tg_backlog_alta();

create or replace function tg_backlog_evento_alta() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into backlog_eventos (backlog_id, tipo, estado_nuevo, texto, usuario)
  values (new.id, 'estado', new.estado, 'Registrado', new.creado_por);
  return null;
end $$;

drop trigger if exists backlog_evento_alta on backlogs;
create trigger backlog_evento_alta after insert on backlogs
  for each row execute function tg_backlog_evento_alta();

-- Cambios: el estado y los campos que lo acompañan solo los mueve
-- cambiar_estado_backlog(); folio, unidad y equipo no cambian; cerrados no se editan.
create or replace function tg_backlog_cambio() returns trigger
language plpgsql as $$
declare
  v_transicion boolean := coalesce(current_setting('backlog.transicion', true), '') = 'si';
begin
  if new.folio <> old.folio or new.unidad_id <> old.unidad_id or new.creado_por is distinct from old.creado_por then
    raise exception 'El folio, la unidad y el autor de un backlog no se cambian';
  end if;
  if new.equipo_id <> old.equipo_id then
    if old.estado <> 'Identificado' then
      raise exception 'El equipo solo se corrige mientras el backlog está Identificado';
    end if;
    if (select unidad_id from equipos where id = new.equipo_id) <> old.unidad_id then
      raise exception 'El equipo nuevo es de otra unidad';
    end if;
  end if;
  if not v_transicion then
    if old.estado in ('Cerrado','Rechazado','Anulado') then
      raise exception 'Backlog % en estado %: no se edita', old.folio, old.estado;
    end if;
    if new.estado <> old.estado
       or new.reprogramaciones <> old.reprogramaciones
       or new.motivo_anulacion is distinct from old.motivo_anulacion
       or new.fecha_ejecucion is distinct from old.fecha_ejecucion
       or new.semana_programada is distinct from old.semana_programada
       or new.fecha_programada is distinct from old.fecha_programada then
      raise exception 'El estado y la programación se cambian con cambiar_estado_backlog()';
    end if;
  end if;
  if new.prioridad <> old.prioridad or new.fecha_deteccion <> old.fecha_deteccion then
    new.fecha_limite := new.fecha_deteccion + plazo_prioridad(new.prioridad);
  end if;
  new.actualizado_en := now();
  return new;
end $$;

drop trigger if exists backlog_cambio on backlogs;
create trigger backlog_cambio before update on backlogs
  for each row execute function tg_backlog_cambio();

-- Detalle (HH, repuestos, fotos): no se toca cuando el backlog está cerrado,
-- rechazado o anulado. Las HH reales se cargan en Programado o Ejecutado.
create or replace function tg_detalle_editable() returns trigger
language plpgsql as $$
declare
  v_fila    record;
  v_estado  text;
begin
  if tg_op = 'DELETE' then v_fila := old; else v_fila := new; end if;
  select estado into v_estado from backlogs where id = v_fila.backlog_id;
  if v_estado in ('Cerrado','Rechazado','Anulado') then
    raise exception 'El backlog está %: su detalle no se edita', v_estado;
  end if;
  if tg_table_name = 'backlog_hh' then
    if v_fila.tipo = 'real' and v_estado not in ('Programado','Ejecutado') then
      raise exception 'Las HH reales se cargan con el backlog Programado o Ejecutado';
    end if;
    if v_fila.tipo = 'estimada' and v_estado in ('Ejecutado') then
      raise exception 'Con el backlog Ejecutado ya no se cambian las HH estimadas';
    end if;
  end if;
  if tg_table_name = 'backlog_repuestos' and tg_op <> 'DELETE' then
    if new.estado = 'Recibido' and new.fecha_recibido is null then
      new.fecha_recibido := current_date;
    elsif new.estado <> 'Recibido' then
      new.fecha_recibido := null;
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['backlog_hh','backlog_repuestos','backlog_fotos'] loop
    execute format('drop trigger if exists detalle_editable on %I', t);
    execute format('create trigger detalle_editable before insert or update or delete on %I
                    for each row execute function tg_detalle_editable()', t);
  end loop;
end $$;

-- ===== 004_transiciones.sql =====
-- Flujo del backlog. El estado solo cambia por esta función, que revisa rol,
-- unidad, transición permitida y datos obligatorios, y deja el evento en la bitácora.
--
--   Identificado         -> En planificación (admin: HH estimadas cargadas) | Rechazado (admin, motivo)
--   En planificación     -> Esperando repuestos (admin: hay repuestos sin recibir)
--                         | Listo para programar (admin: sin repuestos o todos recibidos)
--   Esperando repuestos  -> Listo para programar (automático al recibir el último, o admin)
--                         | En planificación (admin)
--   Listo para programar -> Programado (admin: semana, fecha y OT) | En planificación (admin)
--   Programado           -> Ejecutado (admin o capturador: fecha y HH reales)
--                         | Listo para programar (admin, motivo: reprogramación)
--   Ejecutado            -> Cerrado (admin)
--   Cualquier estado abierto -> Anulado (admin, motivo)
--
-- p_datos (jsonb, todo opcional salvo lo que pida la transición):
--   prioridad, motivo, comentario, semana_programada, fecha_programada, ot_sap,
--   aprovechar_pm, fecha_ejecucion

create or replace function cambiar_estado_backlog(p_id uuid, p_estado text, p_datos jsonb default '{}'::jsonb)
returns backlogs
language plpgsql security definer set search_path = public as $$
declare
  b          backlogs;
  v_rol      text := rol_actual();
  v_motivo   text := nullif(trim(p_datos->>'motivo'), '');
  v_coment   text := nullif(trim(p_datos->>'comentario'), '');
  v_tipo_ev  text := 'estado';
  v_pend     integer;
  v_total    integer;
  v_fecha    date;
  v_semana   date;
  v_anterior text;
begin
  select * into b from backlogs where id = p_id for update;
  if not found then
    raise exception 'Backlog inexistente';
  end if;
  v_anterior := b.estado;
  if v_rol is null or v_rol = 'invitado' or not unidad_permitida(b.unidad_id) then
    raise exception 'Sin permiso para cambiar este backlog';
  end if;
  if p_estado = b.estado then
    raise exception 'El backlog ya está %', b.estado;
  end if;

  select count(*), count(*) filter (where estado <> 'Recibido')
    into v_total, v_pend
  from backlog_repuestos where backlog_id = b.id;

  -- Transiciones permitidas y quién las hace
  if not (
       (b.estado = 'Identificado'         and p_estado in ('En planificación','Rechazado'))
    or (b.estado = 'En planificación'     and p_estado in ('Esperando repuestos','Listo para programar'))
    or (b.estado = 'Esperando repuestos'  and p_estado in ('Listo para programar','En planificación'))
    or (b.estado = 'Listo para programar' and p_estado in ('Programado','En planificación'))
    or (b.estado = 'Programado'           and p_estado in ('Ejecutado','Listo para programar'))
    or (b.estado = 'Ejecutado'            and p_estado = 'Cerrado')
    or (b.estado in ('Identificado','En planificación','Esperando repuestos','Listo para programar','Programado')
        and p_estado = 'Anulado')
  ) then
    raise exception 'No se puede pasar de % a %', b.estado, p_estado;
  end if;
  if v_rol <> 'admin' and not (b.estado = 'Programado' and p_estado = 'Ejecutado') then
    raise exception 'Solo el administrador puede pasar de % a %', b.estado, p_estado;
  end if;

  perform set_config('backlog.transicion', 'si', true);

  if p_datos ? 'prioridad' and b.estado in ('Identificado','En planificación') then
    b.prioridad := p_datos->>'prioridad';
  end if;

  case p_estado
    when 'En planificación' then
      if b.estado = 'Identificado'
         and not exists (select 1 from backlog_hh where backlog_id = b.id and tipo = 'estimada') then
        raise exception 'Cargue las HH estimadas por especialidad antes de planificar';
      end if;
    when 'Esperando repuestos' then
      if v_pend = 0 then
        raise exception 'No hay repuestos pendientes de recibir';
      end if;
    when 'Listo para programar' then
      if v_pend > 0 then
        raise exception 'Faltan % repuesto(s) por recibir', v_pend;
      end if;
      if b.estado = 'Programado' then
        if v_motivo is null then
          raise exception 'Indique el motivo de la reprogramación';
        end if;
        b.reprogramaciones := b.reprogramaciones + 1;
        b.semana_programada := null;
        b.fecha_programada := null;
        v_tipo_ev := 'reprogramación';
      end if;
    when 'Programado' then
      v_fecha := coalesce((p_datos->>'fecha_programada')::date, b.fecha_programada);
      v_semana := coalesce((p_datos->>'semana_programada')::date, date_trunc('week', v_fecha)::date);
      b.ot_sap := coalesce(nullif(trim(p_datos->>'ot_sap'), ''), b.ot_sap);
      if v_fecha is null or b.ot_sap is null then
        raise exception 'Para programar indique fecha programada y OT SAP';
      end if;
      if v_fecha < hoy() then
        raise exception 'La fecha programada no puede ser pasada';
      end if;
      if date_trunc('week', v_fecha)::date <> v_semana then
        raise exception 'La fecha programada no cae en la semana indicada';
      end if;
      b.fecha_programada := v_fecha;
      b.semana_programada := v_semana;
      b.aprovechar_pm := coalesce((p_datos->>'aprovechar_pm')::boolean, b.aprovechar_pm);
    when 'Ejecutado' then
      v_fecha := (p_datos->>'fecha_ejecucion')::date;
      if v_fecha is null then
        raise exception 'Indique la fecha de ejecución';
      end if;
      if v_fecha > hoy() then
        raise exception 'La fecha de ejecución no puede ser futura';
      end if;
      if not exists (select 1 from backlog_hh where backlog_id = b.id and tipo = 'real') then
        raise exception 'Cargue las HH reales por especialidad antes de marcar ejecutado';
      end if;
      b.fecha_ejecucion := v_fecha;
    when 'Rechazado', 'Anulado' then
      if v_motivo is null then
        raise exception 'Indique el motivo';
      end if;
      b.motivo_anulacion := v_motivo;
    else
      null;
  end case;

  update backlogs set
    estado = p_estado,
    prioridad = b.prioridad,
    ot_sap = b.ot_sap,
    semana_programada = b.semana_programada,
    fecha_programada = b.fecha_programada,
    aprovechar_pm = b.aprovechar_pm,
    fecha_ejecucion = b.fecha_ejecucion,
    reprogramaciones = b.reprogramaciones,
    motivo_anulacion = b.motivo_anulacion
  where id = b.id
  returning * into b;

  insert into backlog_eventos (backlog_id, tipo, estado_anterior, estado_nuevo, texto)
  values (b.id, v_tipo_ev, v_anterior, p_estado, nullif(concat_ws(' · ', v_motivo, v_coment), ''));

  perform set_config('backlog.transicion', 'no', true);
  return b;
end $$;

-- Repuestos: al recibir el último, el backlog en Esperando repuestos pasa solo a
-- Listo para programar; si a uno Listo se le agrega un repuesto sin recibir, vuelve a esperar.
create or replace function tg_repuestos_estado() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid := coalesce(new.backlog_id, old.backlog_id);
  v_estado text;
  v_pend   integer;
  v_total  integer;
  v_nuevo  text;
begin
  select estado into v_estado from backlogs where id = v_id;
  select count(*), count(*) filter (where estado <> 'Recibido') into v_total, v_pend
  from backlog_repuestos where backlog_id = v_id;
  if v_estado = 'Esperando repuestos' and v_total > 0 and v_pend = 0 then
    v_nuevo := 'Listo para programar';
  elsif v_estado = 'Listo para programar' and v_pend > 0 then
    v_nuevo := 'Esperando repuestos';
  end if;
  if v_nuevo is not null then
    perform set_config('backlog.transicion', 'si', true);
    update backlogs set estado = v_nuevo where id = v_id;
    perform set_config('backlog.transicion', 'no', true);
    insert into backlog_eventos (backlog_id, tipo, estado_anterior, estado_nuevo, texto)
    values (v_id, 'estado', v_estado, v_nuevo,
            case when v_pend = 0 then 'Automático: todos los repuestos recibidos'
                 else 'Automático: se agregó un repuesto sin recibir' end);
  end if;
  return null;
end $$;

drop trigger if exists repuestos_estado on backlog_repuestos;
create trigger repuestos_estado after insert or update or delete on backlog_repuestos
  for each row execute function tg_repuestos_estado();

-- ===== 005_vistas.sql =====
-- Vistas del tablero, la programación y los indicadores. Respetan las políticas
-- de las tablas base (security_invoker) en Supabase.

-- Se borra y se recrea: usa b.* y 008 le agrega columnas a backlogs.
drop view if exists v_backlog;
create view v_backlog as
with hh as (
  select backlog_id,
         sum(hh) filter (where tipo = 'estimada') as hh_estimadas,
         sum(hh) filter (where tipo = 'real')     as hh_reales
  from backlog_hh group by backlog_id
),
rep as (
  select backlog_id,
         count(*) as repuestos_total,
         count(*) filter (where estado <> 'Recibido') as repuestos_pendientes
  from backlog_repuestos group by backlog_id
)
select b.*,
       e.cod_interno, e.modelo, e.flota,
       s.nombre as sistema,
       case when b.estado in ('Ejecutado','Cerrado') then coalesce(b.fecha_ejecucion, hoy()) - b.fecha_deteccion
            else hoy() - b.fecha_deteccion end as antiguedad_dias,
       case when b.estado in ('Ejecutado','Cerrado','Rechazado','Anulado') then null
            else b.fecha_limite - hoy() end as dias_para_limite,
       (b.estado not in ('Ejecutado','Cerrado','Rechazado','Anulado') and b.fecha_limite < hoy()) as vencido,
       coalesce(hh.hh_estimadas, 0) as hh_estimadas,
       coalesce(hh.hh_reales, 0)    as hh_reales,
       coalesce(rep.repuestos_total, 0)      as repuestos_total,
       coalesce(rep.repuestos_pendientes, 0) as repuestos_pendientes
from backlogs b
join equipos e  on e.id = b.equipo_id
join sistemas s on s.id = b.sistema_id
left join hh  on hh.backlog_id = b.id
left join rep on rep.backlog_id = b.id;

-- HH estimadas de los backlogs abiertos (sin ejecutar), por unidad y especialidad.
create or replace view v_hh_pendiente as
select b.unidad_id, h.especialidad_id, b.estado, sum(h.hh) as hh
from backlogs b
join backlog_hh h on h.backlog_id = b.id and h.tipo = 'estimada'
where b.estado in ('Identificado','En planificación','Esperando repuestos','Listo para programar','Programado')
group by b.unidad_id, h.especialidad_id, b.estado;

-- Capacidad vigente a hoy() por unidad y especialidad.
create or replace view v_capacidad_vigente as
select distinct on (unidad_id, especialidad_id)
       unidad_id, especialidad_id, hh_semana, vigente_desde
from capacidad_taller
where vigente_desde <= hoy()
order by unidad_id, especialidad_id, vigente_desde desc;

-- Semanas de backlog = HH pendientes / HH disponibles por semana.
create or replace view v_semanas_backlog as
with pend as (
  select unidad_id, especialidad_id, sum(hh) as hh_pendientes
  from v_hh_pendiente group by unidad_id, especialidad_id
)
select coalesce(p.unidad_id, c.unidad_id) as unidad_id,
       coalesce(p.especialidad_id, c.especialidad_id) as especialidad_id,
       es.nombre as especialidad,
       coalesce(p.hh_pendientes, 0) as hh_pendientes,
       c.hh_semana,
       case when c.hh_semana > 0 then round(coalesce(p.hh_pendientes, 0) / c.hh_semana, 2) end as semanas
from pend p
full join v_capacidad_vigente c on c.unidad_id = p.unidad_id and c.especialidad_id = p.especialidad_id
join especialidades es on es.id = coalesce(p.especialidad_id, c.especialidad_id);

-- HH programadas por semana, unidad y especialidad (para comparar con la capacidad).
create or replace view v_carga_semanal as
select b.unidad_id, b.semana_programada as semana, h.especialidad_id, sum(h.hh) as hh_programadas,
       count(distinct b.id) as backlogs
from backlogs b
join backlog_hh h on h.backlog_id = b.id and h.tipo = 'estimada'
where b.estado = 'Programado'
group by b.unidad_id, b.semana_programada, h.especialidad_id;

-- Ingresos y cierres por semana ISO (lunes). Cierre = ejecutado (fecha de ejecución).
create or replace view v_backlog_semanal as
with ing as (
  select unidad_id, date_trunc('week', fecha_deteccion)::date as semana,
         count(*) as ingresos,
         count(*) filter (where estado not in ('Rechazado','Anulado')) as ingresos_validos
  from backlogs group by 1, 2
),
cie as (
  select unidad_id, date_trunc('week', fecha_ejecucion)::date as semana,
         count(*) as cierres,
         count(*) filter (where fecha_ejecucion <= fecha_limite) as cierres_en_plazo
  from backlogs
  where estado in ('Ejecutado','Cerrado') and fecha_ejecucion is not null
  group by 1, 2
)
select coalesce(i.unidad_id, c.unidad_id) as unidad_id,
       coalesce(i.semana, c.semana) as semana,
       coalesce(i.ingresos, 0) as ingresos,
       coalesce(i.ingresos_validos, 0) as ingresos_validos,
       coalesce(c.cierres, 0) as cierres,
       coalesce(c.cierres_en_plazo, 0) as cierres_en_plazo
from ing i
full join cie c on c.unidad_id = i.unidad_id and c.semana = i.semana;

do $$
declare v text;
begin
  foreach v in array array['v_backlog','v_hh_pendiente','v_capacidad_vigente','v_semanas_backlog',
                           'v_carga_semanal','v_backlog_semanal'] loop
    execute format('alter view %I set (security_invoker = true)', v);
  end loop;
end $$;

-- ===== 006_rls.sql =====
-- Seguridad por rol y unidad.
--   admin:      todo, en todas las unidades.
--   capturador: registra backlogs, HH, repuestos, fotos y comentarios de su unidad;
--               edita el backlog mientras está Identificado; marca Ejecutado.
--   invitado:   solo consulta su unidad.
-- Las transiciones de estado van por cambiar_estado_backlog() (004).

create or replace function unidad_de_backlog(p_backlog uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select unidad_id from backlogs where id = p_backlog
$$;

revoke execute on function rol_actual(), unidad_actual(), unidad_permitida(uuid),
  unidad_de_backlog(uuid), cambiar_estado_backlog(uuid, text, jsonb) from public;
grant execute on function rol_actual(), unidad_actual(), unidad_permitida(uuid),
  unidad_de_backlog(uuid), cambiar_estado_backlog(uuid, text, jsonb) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['unidades','perfiles','parametros','equipos','sistemas','especialidades',
                           'capacidad_taller','backlogs','folios','backlog_hh','backlog_repuestos',
                           'backlog_eventos','backlog_fotos'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- Catálogos generales: los lee cualquier usuario activo, los administra el admin.
do $$
declare t text;
begin
  foreach t in array array['unidades','parametros','sistemas','especialidades'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format('create policy leer_%I on %I for select to authenticated
                    using (rol_actual() is not null)', t, t);
    execute format('drop policy if exists administrar_%I on %I', t, t);
    execute format('create policy administrar_%I on %I for all to authenticated
                    using (rol_actual() = ''admin'') with check (rol_actual() = ''admin'')', t, t);
  end loop;
end $$;

-- Perfiles: cada uno lee el suyo aunque esté inactivo (pantalla de acceso pendiente).
drop policy if exists leer_perfiles on perfiles;
create policy leer_perfiles on perfiles for select to authenticated
  using (rol_actual() is not null or user_id = usuario_sesion());
drop policy if exists administrar_perfiles on perfiles;
create policy administrar_perfiles on perfiles for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

-- Equipos y capacidad: por unidad; los administra el admin.
do $$
declare t text;
begin
  foreach t in array array['equipos','capacidad_taller'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format('create policy leer_%I on %I for select to authenticated
                    using (rol_actual() is not null and unidad_permitida(unidad_id))', t, t);
    execute format('drop policy if exists administrar_%I on %I', t, t);
    execute format('create policy administrar_%I on %I for all to authenticated
                    using (rol_actual() = ''admin'') with check (rol_actual() = ''admin'')', t, t);
  end loop;
end $$;

-- Backlogs. Sin política de borrado: no se borran.
drop policy if exists leer_backlogs on backlogs;
create policy leer_backlogs on backlogs for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_id));
drop policy if exists registrar_backlogs on backlogs;
create policy registrar_backlogs on backlogs for insert to authenticated
  with check (rol_actual() in ('admin','capturador') and unidad_permitida(unidad_id));
drop policy if exists editar_backlogs on backlogs;
create policy editar_backlogs on backlogs for update to authenticated
  using (unidad_permitida(unidad_id)
         and (rol_actual() = 'admin' or (rol_actual() = 'capturador' and estado = 'Identificado')))
  with check (unidad_permitida(unidad_id));

-- Detalle del backlog: lo leen todos los de la unidad; lo editan admin y capturador.
do $$
declare t text;
begin
  foreach t in array array['backlog_hh','backlog_repuestos','backlog_fotos'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format('create policy leer_%I on %I for select to authenticated
                    using (rol_actual() is not null and unidad_permitida(unidad_de_backlog(backlog_id)))', t, t);
    execute format('drop policy if exists editar_%I on %I', t, t);
    execute format('create policy editar_%I on %I for all to authenticated
                    using (rol_actual() in (''admin'',''capturador'') and unidad_permitida(unidad_de_backlog(backlog_id)))
                    with check (rol_actual() in (''admin'',''capturador'') and unidad_permitida(unidad_de_backlog(backlog_id)))', t, t);
  end loop;
end $$;

-- Bitácora: desde la app solo se agregan comentarios propios; los eventos de estado
-- los escriben las funciones de la base.
drop policy if exists leer_backlog_eventos on backlog_eventos;
create policy leer_backlog_eventos on backlog_eventos for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_de_backlog(backlog_id)));
drop policy if exists comentar_backlog_eventos on backlog_eventos;
create policy comentar_backlog_eventos on backlog_eventos for insert to authenticated
  with check (rol_actual() in ('admin','capturador')
              and unidad_permitida(unidad_de_backlog(backlog_id))
              and tipo = 'comentario' and usuario = usuario_sesion()
              and estado_anterior is null and estado_nuevo is null);

-- Perfil automático (inactivo, sin unidad) al crear un usuario en Authentication.
create or replace function crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (user_id, nombre, correo, rol, activo)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
          new.email, 'capturador', false)
  on conflict (user_id) do nothing;
  return new;
end $$;

do $$
begin
  if to_regclass('auth.users') is not null then
    drop trigger if exists al_crear_usuario on auth.users;
    create trigger al_crear_usuario after insert on auth.users
      for each row execute function crear_perfil();
  end if;
end $$;

-- Tiempo real de Supabase.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['backlogs','backlog_hh','backlog_repuestos','backlog_eventos','backlog_fotos',
                             'equipos','sistemas','especialidades','capacidad_taller','parametros','perfiles'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table %I', t);
      end if;
    end loop;
  end if;
end $$;

-- ===== 007_storage.sql =====
-- Fotos de backlog en Supabase Storage: bucket privado backlog-fotos.
-- Ruta: <unidad_id>/<backlog_id>/<archivo>.jpg; la carpeta raíz decide la unidad.

do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'Sin esquema storage: se omite 007 (base local)';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('backlog-fotos', 'backlog-fotos', false)
  on conflict (id) do nothing;

  drop policy if exists leer_backlog_fotos on storage.objects;
  create policy leer_backlog_fotos on storage.objects for select to authenticated
    using (bucket_id = 'backlog-fotos' and rol_actual() is not null
           and unidad_permitida(((storage.foldername(name))[1])::uuid));

  drop policy if exists subir_backlog_fotos on storage.objects;
  create policy subir_backlog_fotos on storage.objects for insert to authenticated
    with check (bucket_id = 'backlog-fotos' and rol_actual() in ('admin','capturador')
                and unidad_permitida(((storage.foldername(name))[1])::uuid)
                and unidad_de_backlog(((storage.foldername(name))[2])::uuid) = ((storage.foldername(name))[1])::uuid);

  drop policy if exists borrar_backlog_fotos on storage.objects;
  create policy borrar_backlog_fotos on storage.objects for delete to authenticated
    using (bucket_id = 'backlog-fotos' and rol_actual() = 'admin');
end $$;

-- ===== 008_formato_backlog.sql =====
-- Formato "Mantenimiento correctivo programado": tipo de pedido, justificación,
-- componente y horómetro del backlog; marca del equipo; repuestos con ítem, número
-- de parte, stock, componente y observaciones; foto por línea de repuesto.

alter table equipos add column if not exists marca text;

alter table backlogs add column if not exists tipo_pedido text not null default 'Normal';
alter table backlogs drop constraint if exists backlogs_tipo_pedido_check;
alter table backlogs add constraint backlogs_tipo_pedido_check check (tipo_pedido in ('Normal', 'Urgente'));
alter table backlogs add column if not exists justificacion text;
alter table backlogs add column if not exists componente text;       -- ej. Block de implementos
alter table backlogs add column if not exists horometro numeric;     -- horómetro del equipo al detectar
alter table backlogs drop constraint if exists backlogs_horometro_check;
alter table backlogs add constraint backlogs_horometro_check check (horometro is null or horometro >= 0);

-- Repuestos: se identifican por número de parte, por código SAP o por los dos.
alter table backlog_repuestos add column if not exists item integer;
alter table backlog_repuestos add column if not exists numero_parte text;
alter table backlog_repuestos add column if not exists stock numeric;
alter table backlog_repuestos add column if not exists componente text;
alter table backlog_repuestos add column if not exists observaciones text;
alter table backlog_repuestos alter column cod_sap drop not null;
alter table backlog_repuestos drop constraint if exists backlog_repuestos_cod_sap_check;
alter table backlog_repuestos drop constraint if exists backlog_repuestos_identificacion;
alter table backlog_repuestos add constraint backlog_repuestos_identificacion
  check (coalesce(trim(numero_parte), '') <> '' or coalesce(trim(cod_sap), '') <> '');
alter table backlog_repuestos drop constraint if exists backlog_repuestos_stock_check;
alter table backlog_repuestos add constraint backlog_repuestos_stock_check check (stock is null or stock >= 0);

-- Repuestos cargados antes de esta migración: ítem según orden de carga.
update backlog_repuestos r set item = x.n
from (select id, row_number() over (partition by backlog_id order by creado_en, ctid) as n
      from backlog_repuestos) x
where x.id = r.id and r.item is null;

-- Ítem correlativo por backlog cuando la app no lo manda.
create or replace function tg_repuesto_item() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.item is null then
    select coalesce(max(item), 0) + 1 into new.item from backlog_repuestos where backlog_id = new.backlog_id;
  end if;
  return new;
end $$;

drop trigger if exists repuesto_item on backlog_repuestos;
create trigger repuesto_item before insert on backlog_repuestos
  for each row execute function tg_repuesto_item();

alter table backlog_fotos add column if not exists repuesto_id uuid references backlog_repuestos(id);

-- v_backlog con las columnas nuevas (b.* las incluye) y la marca del equipo.
drop view if exists v_backlog;
create view v_backlog as
with hh as (
  select backlog_id,
         sum(hh) filter (where tipo = 'estimada') as hh_estimadas,
         sum(hh) filter (where tipo = 'real')     as hh_reales
  from backlog_hh group by backlog_id
),
rep as (
  select backlog_id,
         count(*) as repuestos_total,
         count(*) filter (where estado <> 'Recibido') as repuestos_pendientes
  from backlog_repuestos group by backlog_id
)
select b.*,
       e.cod_interno, e.modelo, e.flota,
       s.nombre as sistema,
       case when b.estado in ('Ejecutado','Cerrado') then coalesce(b.fecha_ejecucion, hoy()) - b.fecha_deteccion
            else hoy() - b.fecha_deteccion end as antiguedad_dias,
       case when b.estado in ('Ejecutado','Cerrado','Rechazado','Anulado') then null
            else b.fecha_limite - hoy() end as dias_para_limite,
       (b.estado not in ('Ejecutado','Cerrado','Rechazado','Anulado') and b.fecha_limite < hoy()) as vencido,
       coalesce(hh.hh_estimadas, 0) as hh_estimadas,
       coalesce(hh.hh_reales, 0)    as hh_reales,
       coalesce(rep.repuestos_total, 0)      as repuestos_total,
       coalesce(rep.repuestos_pendientes, 0) as repuestos_pendientes,
       e.marca
from backlogs b
join equipos e  on e.id = b.equipo_id
join sistemas s on s.id = b.sistema_id
left join hh  on hh.backlog_id = b.id
left join rep on rep.backlog_id = b.id;

alter view v_backlog set (security_invoker = true);

-- ===== 009_reprogramar.sql =====
-- Reprogramación directa: cambiar_estado_backlog acepta Programado -> Programado
-- con otra fecha y motivo, en un solo llamado (antes había que pasar por Listo para
-- programar). Suma 1 a reprogramaciones, mantiene la OT y deja en la bitácora
-- "fecha anterior -> fecha nueva · motivo". Reemplaza la función de 004.
--
--   Programado -> Programado (admin: fecha_programada nueva, motivo)

create or replace function cambiar_estado_backlog(p_id uuid, p_estado text, p_datos jsonb default '{}'::jsonb)
returns backlogs
language plpgsql security definer set search_path = public as $$
declare
  b          backlogs;
  v_rol      text := rol_actual();
  v_motivo   text := nullif(trim(p_datos->>'motivo'), '');
  v_coment   text := nullif(trim(p_datos->>'comentario'), '');
  v_tipo_ev  text := 'estado';
  v_pend     integer;
  v_total    integer;
  v_fecha    date;
  v_semana   date;
  v_anterior text;
  v_detalle  text;
  v_fecha_ant date;
begin
  select * into b from backlogs where id = p_id for update;
  if not found then
    raise exception 'Backlog inexistente';
  end if;
  v_anterior := b.estado;
  if v_rol is null or v_rol = 'invitado' or not unidad_permitida(b.unidad_id) then
    raise exception 'Sin permiso para cambiar este backlog';
  end if;
  if p_estado = b.estado and p_estado <> 'Programado' then
    raise exception 'El backlog ya está %', b.estado;
  end if;

  select count(*), count(*) filter (where estado <> 'Recibido')
    into v_total, v_pend
  from backlog_repuestos where backlog_id = b.id;

  -- Transiciones permitidas y quién las hace
  if not (
       (b.estado = 'Identificado'         and p_estado in ('En planificación','Rechazado'))
    or (b.estado = 'En planificación'     and p_estado in ('Esperando repuestos','Listo para programar'))
    or (b.estado = 'Esperando repuestos'  and p_estado in ('Listo para programar','En planificación'))
    or (b.estado = 'Listo para programar' and p_estado in ('Programado','En planificación'))
    or (b.estado = 'Programado'           and p_estado in ('Ejecutado','Listo para programar','Programado'))
    or (b.estado = 'Ejecutado'            and p_estado = 'Cerrado')
    or (b.estado in ('Identificado','En planificación','Esperando repuestos','Listo para programar','Programado')
        and p_estado = 'Anulado')
  ) then
    raise exception 'No se puede pasar de % a %', b.estado, p_estado;
  end if;
  if v_rol <> 'admin' and not (b.estado = 'Programado' and p_estado = 'Ejecutado') then
    raise exception 'Solo el administrador puede pasar de % a %', b.estado, p_estado;
  end if;

  perform set_config('backlog.transicion', 'si', true);

  if p_datos ? 'prioridad' and b.estado in ('Identificado','En planificación') then
    b.prioridad := p_datos->>'prioridad';
  end if;

  case p_estado
    when 'En planificación' then
      if b.estado = 'Identificado'
         and not exists (select 1 from backlog_hh where backlog_id = b.id and tipo = 'estimada') then
        raise exception 'Cargue las HH estimadas por especialidad antes de planificar';
      end if;
    when 'Esperando repuestos' then
      if v_pend = 0 then
        raise exception 'No hay repuestos pendientes de recibir';
      end if;
    when 'Listo para programar' then
      if v_pend > 0 then
        raise exception 'Faltan % repuesto(s) por recibir', v_pend;
      end if;
      if b.estado = 'Programado' then
        if v_motivo is null then
          raise exception 'Indique el motivo de la reprogramación';
        end if;
        b.reprogramaciones := b.reprogramaciones + 1;
        b.semana_programada := null;
        b.fecha_programada := null;
        v_tipo_ev := 'reprogramación';
      end if;
    when 'Programado' then
      if b.estado = 'Programado' then
        -- Reprogramación directa: otra fecha, misma OT, con motivo.
        v_fecha_ant := b.fecha_programada;
        if v_motivo is null then
          raise exception 'Indique el motivo de la reprogramación';
        end if;
        if (p_datos->>'fecha_programada') is null or (p_datos->>'fecha_programada')::date = v_fecha_ant then
          raise exception 'Indique una fecha programada distinta a la actual';
        end if;
        b.reprogramaciones := b.reprogramaciones + 1;
        v_tipo_ev := 'reprogramación';
        v_detalle := format('%s → %s', to_char(v_fecha_ant, 'DD/MM/YYYY'),
                            to_char((p_datos->>'fecha_programada')::date, 'DD/MM/YYYY'));
      end if;
      v_fecha := coalesce((p_datos->>'fecha_programada')::date, b.fecha_programada);
      v_semana := coalesce((p_datos->>'semana_programada')::date, date_trunc('week', v_fecha)::date);
      b.ot_sap := coalesce(nullif(trim(p_datos->>'ot_sap'), ''), b.ot_sap);
      if v_fecha is null or b.ot_sap is null then
        raise exception 'Para programar indique fecha programada y OT SAP';
      end if;
      if v_fecha < hoy() then
        raise exception 'La fecha programada no puede ser pasada';
      end if;
      if date_trunc('week', v_fecha)::date <> v_semana then
        raise exception 'La fecha programada no cae en la semana indicada';
      end if;
      b.fecha_programada := v_fecha;
      b.semana_programada := v_semana;
      b.aprovechar_pm := coalesce((p_datos->>'aprovechar_pm')::boolean, b.aprovechar_pm);
    when 'Ejecutado' then
      v_fecha := (p_datos->>'fecha_ejecucion')::date;
      if v_fecha is null then
        raise exception 'Indique la fecha de ejecución';
      end if;
      if v_fecha > hoy() then
        raise exception 'La fecha de ejecución no puede ser futura';
      end if;
      if not exists (select 1 from backlog_hh where backlog_id = b.id and tipo = 'real') then
        raise exception 'Cargue las HH reales por especialidad antes de marcar ejecutado';
      end if;
      b.fecha_ejecucion := v_fecha;
    when 'Rechazado', 'Anulado' then
      if v_motivo is null then
        raise exception 'Indique el motivo';
      end if;
      b.motivo_anulacion := v_motivo;
    else
      null;
  end case;

  update backlogs set
    estado = p_estado,
    prioridad = b.prioridad,
    ot_sap = b.ot_sap,
    semana_programada = b.semana_programada,
    fecha_programada = b.fecha_programada,
    aprovechar_pm = b.aprovechar_pm,
    fecha_ejecucion = b.fecha_ejecucion,
    reprogramaciones = b.reprogramaciones,
    motivo_anulacion = b.motivo_anulacion
  where id = b.id
  returning * into b;

  insert into backlog_eventos (backlog_id, tipo, estado_anterior, estado_nuevo, texto)
  values (b.id, v_tipo_ev, v_anterior, p_estado, nullif(concat_ws(' · ', v_detalle, v_motivo, v_coment), ''));

  perform set_config('backlog.transicion', 'no', true);
  return b;
end $$;

-- ===== 010_validado.sql =====
-- El estado final "Cerrado" pasa a llamarse "Validado" (pedido del usuario: el
-- flujo visible es Identificado, Planeado, Programado, Ejecutado, Validado).
-- Se cambian los datos, la restricción de estados y cada función y vista que
-- nombra el estado, a partir de su definición actual en la base. Se puede repetir.

alter table backlogs drop constraint if exists backlogs_estado_check;

-- Los datos: el disparador de cambios exige pasar por cambiar_estado_backlog();
-- aquí se marca la transacción como transición autorizada.
do $$
begin
  perform set_config('backlog.transicion', 'si', true);
  update backlogs set estado = 'Validado' where estado = 'Cerrado';
  perform set_config('backlog.transicion', 'no', true);
end $$;
update backlog_eventos set estado_nuevo = 'Validado' where estado_nuevo = 'Cerrado';
update backlog_eventos set estado_anterior = 'Validado' where estado_anterior = 'Cerrado';

alter table backlogs add constraint backlogs_estado_check check (estado in
  ('Identificado','En planificación','Esperando repuestos','Listo para programar',
   'Programado','Ejecutado','Validado','Rechazado','Anulado'));

-- Funciones: cambiar_estado_backlog (de 009), tg_backlog_cambio y tg_detalle_editable (de 003).
do $$
declare
  f text;
begin
  for f in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('cambiar_estado_backlog', 'tg_backlog_cambio', 'tg_detalle_editable')
  loop
    execute replace(f, '''Cerrado''', '''Validado''');
  end loop;
end $$;

-- Vistas: mismas columnas, solo cambia el literal.
do $$
declare
  v text;
begin
  foreach v in array array['v_backlog', 'v_backlog_semanal'] loop
    execute format('create or replace view %I as %s', v,
                   replace(pg_get_viewdef(v::regclass), '''Cerrado''', '''Validado'''));
    execute format('alter view %I set (security_invoker = true)', v);
  end loop;
end $$;

-- ===== 011_fotos.sql =====
-- Fotos: suben admin y capturador de la unidad; borra solo el admin, igual que el
-- archivo en Storage (007). Antes la política "for all" de 006 dejaba al capturador
-- borrar la fila aunque no pudiera borrar el archivo.

drop policy if exists editar_backlog_fotos on backlog_fotos;

drop policy if exists subir_backlog_fotos on backlog_fotos;
create policy subir_backlog_fotos on backlog_fotos for insert to authenticated
  with check (rol_actual() in ('admin','capturador') and unidad_permitida(unidad_de_backlog(backlog_id))
              and creado_por = usuario_sesion());

drop policy if exists cambiar_backlog_fotos on backlog_fotos;
create policy cambiar_backlog_fotos on backlog_fotos for update to authenticated
  using (rol_actual() in ('admin','capturador') and unidad_permitida(unidad_de_backlog(backlog_id)))
  with check (rol_actual() in ('admin','capturador') and unidad_permitida(unidad_de_backlog(backlog_id)));

drop policy if exists borrar_backlog_fotos on backlog_fotos;
create policy borrar_backlog_fotos on backlog_fotos for delete to authenticated
  using (rol_actual() = 'admin' and unidad_permitida(unidad_de_backlog(backlog_id)));

-- ===== 012_recalcular_limites.sql =====
-- Recalcula la fecha límite de los backlogs abiertos con los plazos vigentes por
-- prioridad (parametros plazo_pN_dias). Solo el admin. Devuelve cuántos cambiaron.
-- Sin esto, un plazo nuevo solo rige para backlogs nuevos o que cambian de prioridad.

create or replace function recalcular_fechas_limite() returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_n integer;
begin
  if coalesce(rol_actual(), '') <> 'admin' then
    raise exception 'Solo el administrador puede recalcular las fechas límite';
  end if;
  update backlogs
     set fecha_limite = fecha_deteccion + plazo_prioridad(prioridad)
   where estado in ('Identificado','En planificación','Esperando repuestos','Listo para programar','Programado')
     and fecha_limite is distinct from fecha_deteccion + plazo_prioridad(prioridad);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function recalcular_fechas_limite() from public;
grant execute on function recalcular_fechas_limite() to authenticated;

-- ===== 013_numero_formato.sql =====
-- N° del formato en papel (ej. 105) como referencia de los backlogs importados desde
-- Excel. Único por unidad: el mismo formato no se importa dos veces.

alter table backlogs add column if not exists numero_formato text;
drop index if exists backlogs_numero_formato;
create unique index backlogs_numero_formato on backlogs (unidad_id, numero_formato) where numero_formato is not null;

-- v_backlog usa b.*: se recrea para que incluya la columna nueva (estado final Validado, de 010).
drop view if exists v_backlog;
create view v_backlog as
with hh as (
  select backlog_id,
         sum(hh) filter (where tipo = 'estimada') as hh_estimadas,
         sum(hh) filter (where tipo = 'real')     as hh_reales
  from backlog_hh group by backlog_id
),
rep as (
  select backlog_id,
         count(*) as repuestos_total,
         count(*) filter (where estado <> 'Recibido') as repuestos_pendientes
  from backlog_repuestos group by backlog_id
)
select b.*,
       e.cod_interno, e.modelo, e.flota,
       s.nombre as sistema,
       case when b.estado in ('Ejecutado','Validado') then coalesce(b.fecha_ejecucion, hoy()) - b.fecha_deteccion
            else hoy() - b.fecha_deteccion end as antiguedad_dias,
       case when b.estado in ('Ejecutado','Validado','Rechazado','Anulado') then null
            else b.fecha_limite - hoy() end as dias_para_limite,
       (b.estado not in ('Ejecutado','Validado','Rechazado','Anulado') and b.fecha_limite < hoy()) as vencido,
       coalesce(hh.hh_estimadas, 0) as hh_estimadas,
       coalesce(hh.hh_reales, 0)    as hh_reales,
       coalesce(rep.repuestos_total, 0)      as repuestos_total,
       coalesce(rep.repuestos_pendientes, 0) as repuestos_pendientes,
       e.marca
from backlogs b
join equipos e  on e.id = b.equipo_id
join sistemas s on s.id = b.sistema_id
left join hh  on hh.backlog_id = b.id
left join rep on rep.backlog_id = b.id;

alter view v_backlog set (security_invoker = true);

-- ===== 014_mejoras.sql =====
-- Mejoras del 06/11/2026: familias de equipo con sus sistemas, "Otro" con texto,
-- reportado y aprobado por, capacidad editable por el capturador de su unidad,
-- SAP solo en HEMCO, especialidad Electromecánico y prioridades de la OT de Dimelco.
-- Se puede repetir.

-- Familias de equipo (Scooptram ST1030, PowerROC T35...) y los sistemas de cada una.
create table if not exists familias (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  activo  boolean not null default true,
  orden   integer not null default 0
);
create table if not exists familia_sistemas (
  familia_id  uuid not null references familias(id) on delete cascade,
  sistema_id  uuid not null references sistemas(id) on delete cascade,
  primary key (familia_id, sistema_id)
);
alter table equipos add column if not exists familia_id uuid references familias(id);

-- Las flotas escritas a mano pasan a ser familias; cada equipo queda en la suya.
insert into familias (nombre)
select distinct trim(flota) from equipos where familia_id is null and coalesce(trim(flota), '') <> ''
on conflict (nombre) do nothing;
update equipos e set familia_id = f.id
from familias f
where e.familia_id is null and f.nombre = trim(e.flota);

alter table familias enable row level security;
alter table familia_sistemas enable row level security;
do $$
declare t text;
begin
  foreach t in array array['familias','familia_sistemas'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format('create policy leer_%I on %I for select to authenticated
                    using (rol_actual() is not null)', t, t);
    execute format('drop policy if exists administrar_%I on %I', t, t);
    execute format('create policy administrar_%I on %I for all to authenticated
                    using (rol_actual() = ''admin'') with check (rol_actual() = ''admin'')', t, t);
  end loop;
end $$;
grant select, insert, update, delete on familias, familia_sistemas to authenticated;

-- Backlog: texto del sistema cuando es "Otro" y quién aprueba la necesidad.
alter table backlogs add column if not exists sistema_otro text;
alter table backlogs add column if not exists aprobado_por text;

-- Validaciones al registrar y al editar. Reportado y aprobado se exigen solo a los
-- backlogs nuevos, y el texto de "Otro" solo cuando se cambia el sistema: los backlogs
-- anteriores a este cambio no los tienen.
create or replace function tg_backlog_validar() returns trigger
language plpgsql as $$
begin
  if (select nombre from sistemas where id = new.sistema_id) = 'Otro'
     and coalesce(trim(new.sistema_otro), '') = ''
     and (tg_op = 'INSERT' or new.sistema_id is distinct from old.sistema_id or new.sistema_otro is distinct from old.sistema_otro) then
    raise exception 'Con sistema "Otro" indique cuál es el sistema';
  end if;
  if (select nombre from sistemas where id = new.sistema_id) <> 'Otro' then
    new.sistema_otro := null;
  end if;
  if tg_op = 'INSERT' and (coalesce(trim(new.reportado_por), '') = '' or coalesce(trim(new.aprobado_por), '') = '') then
    raise exception 'Indique quién reporta la necesidad y quién la aprueba';
  end if;
  return new;
end $$;
drop trigger if exists backlog_validar on backlogs;
create trigger backlog_validar before insert or update on backlogs
  for each row execute function tg_backlog_validar();

-- Capacidad del taller: el capturador también la edita, solo en su unidad.
drop policy if exists administrar_capacidad_taller on capacidad_taller;
create policy administrar_capacidad_taller on capacidad_taller for all to authenticated
  using (rol_actual() in ('admin','capturador') and unidad_permitida(unidad_id))
  with check (rol_actual() in ('admin','capturador') and unidad_permitida(unidad_id));

-- SAP: solo HEMCO lo usa. Las demás unidades ven "N° OT" y nada más de SAP.
alter table unidades add column if not exists usa_sap boolean not null default false;
update unidades set usa_sap = (sigla = 'HEM');

do $$
declare
  f text;
begin
  select pg_get_functiondef(p.oid) into f
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cambiar_estado_backlog';
  execute replace(f, 'Para programar indique fecha programada y OT SAP', 'Para programar indique fecha programada y N° de OT');
end $$;

-- Especialidad nueva.
insert into especialidades (nombre, orden) values ('Electromecánico', 6)
on conflict (nombre) do nothing;

-- Prioridades según los niveles de criticidad de la OT de Dimelco:
-- 1 Urgente (24 horas), 2 Alto (3 días), 3 Medio (14 días), 4 Bajo (40 días).
update parametros set valor = v.dias, descripcion = v.texto
from (values
  ('plazo_p1_dias',  1, 'Días para atender un backlog 1 Urgente (máximo 24 horas)'),
  ('plazo_p2_dias',  3, 'Días para atender un backlog 2 Alto (hasta 3 días)'),
  ('plazo_p3_dias', 14, 'Días para atender un backlog 3 Medio (hasta 14 días)'),
  ('plazo_p4_dias', 40, 'Días para atender un backlog 4 Bajo (hasta 40 días)')
) as v(clave, dias, texto)
where parametros.clave = v.clave and not exists (select 1 from parametros where clave = 'prioridades_dimelco');
insert into parametros (clave, valor, descripcion)
values ('prioridades_dimelco', 1, 'Marca: plazos de la OT de Dimelco ya cargados (014). No borrar')
on conflict (clave) do nothing;
update backlogs
   set fecha_limite = fecha_deteccion + plazo_prioridad(prioridad)
 where estado in ('Identificado','En planificación','Esperando repuestos','Listo para programar','Programado')
   and fecha_limite is distinct from fecha_deteccion + plazo_prioridad(prioridad);

-- v_backlog usa b.*: se recrea con las columnas nuevas. La flota mostrada es la familia.
drop view if exists v_backlog;
create view v_backlog as
with hh as (
  select backlog_id,
         sum(hh) filter (where tipo = 'estimada') as hh_estimadas,
         sum(hh) filter (where tipo = 'real')     as hh_reales
  from backlog_hh group by backlog_id
),
rep as (
  select backlog_id,
         count(*) as repuestos_total,
         count(*) filter (where estado <> 'Recibido') as repuestos_pendientes
  from backlog_repuestos group by backlog_id
)
select b.*,
       e.cod_interno, e.modelo, coalesce(f.nombre, e.flota) as flota,
       case when s.nombre = 'Otro' and b.sistema_otro is not null then 'Otro: ' || b.sistema_otro else s.nombre end as sistema,
       case when b.estado in ('Ejecutado','Validado') then coalesce(b.fecha_ejecucion, hoy()) - b.fecha_deteccion
            else hoy() - b.fecha_deteccion end as antiguedad_dias,
       case when b.estado in ('Ejecutado','Validado','Rechazado','Anulado') then null
            else b.fecha_limite - hoy() end as dias_para_limite,
       (b.estado not in ('Ejecutado','Validado','Rechazado','Anulado') and b.fecha_limite < hoy()) as vencido,
       coalesce(hh.hh_estimadas, 0) as hh_estimadas,
       coalesce(hh.hh_reales, 0)    as hh_reales,
       coalesce(rep.repuestos_total, 0)      as repuestos_total,
       coalesce(rep.repuestos_pendientes, 0) as repuestos_pendientes,
       e.marca,
       e.familia_id,
       u.usa_sap
from backlogs b
join equipos e  on e.id = b.equipo_id
join unidades u on u.id = b.unidad_id
join sistemas s on s.id = b.sistema_id
left join familias f on f.id = e.familia_id
left join hh  on hh.backlog_id = b.id
left join rep on rep.backlog_id = b.id;

alter view v_backlog set (security_invoker = true);

-- ===== 015_borrar.sql =====
-- Borrar backlogs: admin o capturador de la unidad, en cualquier estado y con motivo.
-- El backlog no se elimina: se oculta de todas las vistas y el admin lo puede
-- restaurar. El folio no se reutiliza. Se puede repetir.

alter table backlogs add column if not exists borrado_en timestamptz;
alter table backlogs add column if not exists borrado_por uuid;
alter table backlogs add column if not exists motivo_borrado text;

alter table backlog_eventos drop constraint if exists backlog_eventos_tipo_check;
alter table backlog_eventos add constraint backlog_eventos_tipo_check
  check (tipo in ('estado','comentario','repuesto','reprogramación','borrado','restaurado'));

-- Un backlog borrado no se edita ni se le cambia el detalle; solo lo tocan
-- borrar_backlog() y restaurar_backlog(). Los triggers corren por nombre: backlog_cambio
-- (que fija actualizado_en) va antes que backlog_no_borrado.
create or replace function tg_backlog_no_borrado() returns trigger
language plpgsql as $$
begin
  -- Recalcular la fecha límite (al cambiar plazos) sí se permite.
  if old.borrado_en is not null and coalesce(current_setting('backlog.borrado', true), '') <> 'si'
     and to_jsonb(new) - 'fecha_limite' - 'actualizado_en' <> to_jsonb(old) - 'fecha_limite' - 'actualizado_en' then
    raise exception 'El backlog % está borrado: no se edita', old.folio;
  end if;
  if coalesce(current_setting('backlog.borrado', true), '') <> 'si'
     and (new.borrado_en is distinct from old.borrado_en or new.borrado_por is distinct from old.borrado_por
          or new.motivo_borrado is distinct from old.motivo_borrado) then
    raise exception 'Para borrar un backlog use borrar_backlog()';
  end if;
  return new;
end $$;
drop trigger if exists backlog_no_borrado on backlogs;
create trigger backlog_no_borrado before update on backlogs
  for each row execute function tg_backlog_no_borrado();

create or replace function tg_detalle_no_borrado() returns trigger
language plpgsql as $$
declare
  v_id uuid;
begin
  if tg_op = 'DELETE' then v_id := old.backlog_id; else v_id := new.backlog_id; end if;
  if exists (select 1 from backlogs where id = v_id and borrado_en is not null) then
    raise exception 'El backlog está borrado: su detalle no se edita';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['backlog_hh','backlog_repuestos','backlog_fotos'] loop
    execute format('drop trigger if exists detalle_no_borrado on %I', t);
    execute format('create trigger detalle_no_borrado before insert or update or delete on %I
                    for each row execute function tg_detalle_no_borrado()', t);
  end loop;
end $$;

create or replace function borrar_backlog(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_rol  text := rol_actual();
  b      backlogs;
begin
  select * into b from backlogs where id = p_id for update;
  if not found then
    raise exception 'Backlog inexistente';
  end if;
  if v_rol is null or v_rol not in ('admin', 'capturador') or not unidad_permitida(b.unidad_id) then
    raise exception 'Solo el administrador o un capturador de la unidad pueden borrar el backlog %', b.folio;
  end if;
  if b.borrado_en is not null then
    raise exception 'El backlog % ya está borrado', b.folio;
  end if;
  if length(coalesce(trim(p_motivo), '')) < 5 then
    raise exception 'Indique el motivo del borrado (mínimo 5 letras)';
  end if;
  perform set_config('backlog.borrado', 'si', true);
  perform set_config('backlog.transicion', 'si', true);
  update backlogs
     set borrado_en = now(), borrado_por = usuario_sesion(), motivo_borrado = trim(p_motivo)
   where id = p_id;
  perform set_config('backlog.transicion', 'no', true);
  perform set_config('backlog.borrado', 'no', true);
  insert into backlog_eventos (backlog_id, tipo, estado_anterior, texto, usuario)
  values (p_id, 'borrado', b.estado, 'Borrado: ' || trim(p_motivo), usuario_sesion());
end $$;

create or replace function restaurar_backlog(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  b backlogs;
begin
  if coalesce(rol_actual(), '') <> 'admin' then
    raise exception 'Solo el administrador puede restaurar un backlog borrado';
  end if;
  select * into b from backlogs where id = p_id for update;
  if not found or b.borrado_en is null then
    raise exception 'El backlog no está borrado';
  end if;
  perform set_config('backlog.borrado', 'si', true);
  perform set_config('backlog.transicion', 'si', true);
  update backlogs set borrado_en = null, borrado_por = null, motivo_borrado = null where id = p_id;
  perform set_config('backlog.transicion', 'no', true);
  perform set_config('backlog.borrado', 'no', true);
  insert into backlog_eventos (backlog_id, tipo, estado_nuevo, texto, usuario)
  values (p_id, 'restaurado', b.estado, 'Restaurado (había sido borrado por: ' || b.motivo_borrado || ')', usuario_sesion());
end $$;

revoke execute on function borrar_backlog(uuid, text), restaurar_backlog(uuid) from public;
grant execute on function borrar_backlog(uuid, text), restaurar_backlog(uuid) to authenticated;

-- Vistas: los borrados no cuentan en ninguna pantalla, reporte ni indicador.
drop view if exists v_backlog;
create view v_backlog as
with hh as (
  select backlog_id,
         sum(hh) filter (where tipo = 'estimada') as hh_estimadas,
         sum(hh) filter (where tipo = 'real')     as hh_reales
  from backlog_hh group by backlog_id
),
rep as (
  select backlog_id,
         count(*) as repuestos_total,
         count(*) filter (where estado <> 'Recibido') as repuestos_pendientes
  from backlog_repuestos group by backlog_id
)
select b.*,
       e.cod_interno, e.modelo, coalesce(f.nombre, e.flota) as flota,
       case when s.nombre = 'Otro' and b.sistema_otro is not null then 'Otro: ' || b.sistema_otro else s.nombre end as sistema,
       case when b.estado in ('Ejecutado','Validado') then coalesce(b.fecha_ejecucion, hoy()) - b.fecha_deteccion
            else hoy() - b.fecha_deteccion end as antiguedad_dias,
       case when b.estado in ('Ejecutado','Validado','Rechazado','Anulado') then null
            else b.fecha_limite - hoy() end as dias_para_limite,
       (b.estado not in ('Ejecutado','Validado','Rechazado','Anulado') and b.fecha_limite < hoy()) as vencido,
       coalesce(hh.hh_estimadas, 0) as hh_estimadas,
       coalesce(hh.hh_reales, 0)    as hh_reales,
       coalesce(rep.repuestos_total, 0)      as repuestos_total,
       coalesce(rep.repuestos_pendientes, 0) as repuestos_pendientes,
       e.marca,
       e.familia_id,
       u.usa_sap
from backlogs b
join equipos e  on e.id = b.equipo_id
join unidades u on u.id = b.unidad_id
join sistemas s on s.id = b.sistema_id
left join familias f on f.id = e.familia_id
left join hh  on hh.backlog_id = b.id
left join rep on rep.backlog_id = b.id
where b.borrado_en is null;

create or replace view v_hh_pendiente as
select b.unidad_id, h.especialidad_id, b.estado, sum(h.hh) as hh
from backlogs b
join backlog_hh h on h.backlog_id = b.id and h.tipo = 'estimada'
where b.estado in ('Identificado','En planificación','Esperando repuestos','Listo para programar','Programado')
  and b.borrado_en is null
group by b.unidad_id, h.especialidad_id, b.estado;

create or replace view v_carga_semanal as
select b.unidad_id, b.semana_programada as semana, h.especialidad_id, sum(h.hh) as hh_programadas,
       count(distinct b.id) as backlogs
from backlogs b
join backlog_hh h on h.backlog_id = b.id and h.tipo = 'estimada'
where b.estado = 'Programado' and b.borrado_en is null
group by b.unidad_id, b.semana_programada, h.especialidad_id;

create or replace view v_backlog_semanal as
with ing as (
  select unidad_id, date_trunc('week', fecha_deteccion)::date as semana,
         count(*) as ingresos,
         count(*) filter (where estado not in ('Rechazado','Anulado')) as ingresos_validos
  from backlogs where borrado_en is null group by 1, 2
),
cie as (
  select unidad_id, date_trunc('week', fecha_ejecucion)::date as semana,
         count(*) as cierres,
         count(*) filter (where fecha_ejecucion <= fecha_limite) as cierres_en_plazo
  from backlogs
  where estado in ('Ejecutado','Validado') and fecha_ejecucion is not null and borrado_en is null
  group by 1, 2
)
select coalesce(i.unidad_id, c.unidad_id) as unidad_id,
       coalesce(i.semana, c.semana) as semana,
       coalesce(i.ingresos, 0) as ingresos,
       coalesce(i.ingresos_validos, 0) as ingresos_validos,
       coalesce(c.cierres, 0) as cierres,
       coalesce(c.cierres_en_plazo, 0) as cierres_en_plazo
from ing i
full join cie c on c.unidad_id = i.unidad_id and c.semana = i.semana;

-- Lista de borrados para el administrador (cada uno ve solo lo de sus unidades).
create or replace view v_backlog_borrados as
select b.id, b.folio, b.unidad_id, un.nombre as unidad, e.cod_interno, e.modelo, b.descripcion, b.estado,
       b.prioridad, b.fecha_deteccion, b.borrado_en, b.borrado_por, p.nombre as borrado_por_nombre, b.motivo_borrado
from backlogs b
join equipos e   on e.id = b.equipo_id
join unidades un on un.id = b.unidad_id
left join perfiles p on p.user_id = b.borrado_por
where b.borrado_en is not null;

do $$
declare v text;
begin
  foreach v in array array['v_backlog','v_hh_pendiente','v_carga_semanal','v_backlog_semanal','v_backlog_borrados'] loop
    execute format('alter view %I set (security_invoker = true)', v);
  end loop;
end $$;
grant select on v_backlog_borrados to authenticated;

-- ===== 016_sistemas_por_familia.sql =====
-- Sistemas por familia de equipo, tomados de los listados de sistemas de la biblioteca
-- (BIblioteca > Equipos de perforacion > Listados de sistemas, 06/11/2026): capítulos de
-- los manuales de mantenimiento cruzados con los grupos de los catálogos de partes.
-- Un solo catálogo de sistemas con el mismo nombre en todas las familias, para que los
-- indicadores se puedan comparar entre equipos. Se puede repetir; no borra lo que el
-- administrador agregue después en Familias y sistemas.

-- 1. Nombres: los sistemas iniciales toman el nombre del catálogo nuevo (mismo id, así
--    los backlogs que ya los usan no cambian).
do $$
declare
  r record;
begin
  for r in select * from (values
    ('Motor', 'Motor diésel'),
    ('Transmisión', 'Tren de potencia'),
    ('Estructura y chasis', 'Bastidor y chasis'),
    ('Neumáticos', 'Ruedas y neumáticos'),
    ('Empernadora', 'Unidad de empernado'),
    ('Cabina y seguridad', 'Cabina y entorno del operador')
  ) v(antes, despues) loop
    update sistemas set nombre = r.despues
     where nombre = r.antes and not exists (select 1 from sistemas where nombre = r.despues);
    -- Al repetir la instalación, 002 vuelve a crear el nombre viejo: si nadie lo usa se
    -- borra; si algún backlog lo usa, se desactiva.
    delete from sistemas s
     where s.nombre = r.antes
       and not exists (select 1 from backlogs b where b.sistema_id = s.id)
       and not exists (select 1 from familia_sistemas fs where fs.sistema_id = s.id);
    update sistemas set activo = false where nombre = r.antes;
  end loop;
end $$;

insert into sistemas (nombre, orden) values
  ('Motor diésel', 1),
  ('Sistema de enfriamiento', 2),
  ('Admisión y escape', 3),
  ('Tren de potencia', 4),
  ('Frenos', 5),
  ('Dirección', 6),
  ('Sistema hidráulico', 7),
  ('Sistema eléctrico', 8),
  ('Control y electrónica', 9),
  ('Neumático y agua', 10),
  ('Compresor', 11),
  ('Neblina de agua', 12),
  ('Lubricación', 13),
  ('Extinción de incendios', 14),
  ('Cabina y entorno del operador', 15),
  ('Bastidor y chasis', 16),
  ('Ruedas y neumáticos', 17),
  ('Tren de rodaje (orugas)', 18),
  ('Brazo (boom)', 19),
  ('Cuchara', 20),
  ('Caja de carga', 21),
  ('Unidad de avance', 22),
  ('Perforadora', 23),
  ('Unidad de rotación', 24),
  ('Manejo de barras', 25),
  ('Colector de polvo', 26),
  ('Tambor de cable y manguera', 27),
  ('Unidad de empernado', 28),
  ('Manejo de malla', 29),
  ('Sistema de resina', 30),
  ('Bomba Swellex', 31),
  ('Cabrestante', 32),
  ('Cuba mezcladora', 33),
  ('Bomba de concreto', 34),
  ('Bomba dosificadora de aditivo', 35),
  ('Martillo de desatado', 36),
  ('Otro', 99)
on conflict (nombre) do update set orden = excluded.orden, activo = true;

-- 2. Familias, el patrón del modelo de sus equipos y sus sistemas.
drop table if exists pg_temp._familias;
create temporary table _familias (
  nombre   text primary key,
  orden    integer,
  patron   text,      -- expresión regular sobre equipos.modelo (sin distinguir mayúsculas)
  sistemas text[]
);

insert into _familias values
  ('Scooptram ST1030', 1, 'ST\s*1030',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Cuchara']),
  ('Scooptram ST3.5', 2, 'ST\s*3[.,]5',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Cuchara']),
  ('Caterpillar R1600H', 3, 'R\s*1600',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Cabina y entorno del operador','Bastidor y chasis','Cuchara']),
  ('Ground Force AT18E', 4, 'AT\s*18|UG\s*18',
   array['Motor diésel','Sistema de enfriamiento','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Cabina y entorno del operador','Bastidor y chasis','Caja de carga']),
  ('Boomer S1D', 5, 'S1\s*D',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Tambor de cable y manguera']),
  ('Boomer 282', 6, 'Boomer\s*282|^\s*282\s*$',
   array['Motor diésel','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Unidad de avance','Perforadora','Unidad de rotación','Tambor de cable y manguera']),
  ('Simba S7D', 7, 'S7\s*D|Simba',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Tambor de cable y manguera']),
  ('Boltec S', 8, 'Boltec',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Perforadora','Unidad de empernado','Manejo de malla','Sistema de resina','Bomba Swellex','Tambor de cable y manguera']),
  ('Resemin Bolter', 9, 'Bolter|77\s*D',
   array['Motor diésel','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Lubricación','Extinción de incendios','Bastidor y chasis','Ruedas y neumáticos','Brazo (boom)','Unidad de avance','Perforadora','Unidad de rotación','Unidad de empernado','Manejo de malla','Tambor de cable y manguera']),
  ('Resemin Raptor 44XP', 10, 'Raptor|44\s*XP',
   array['Motor diésel','Tren de potencia','Sistema hidráulico','Sistema eléctrico','Neumático y agua','Compresor','Lubricación','Bastidor y chasis','Brazo (boom)','Unidad de avance','Perforadora','Unidad de rotación']),
  ('Resemin Troidon 55XP', 11, 'Troidon|55\s*XP',
   array['Motor diésel','Tren de potencia','Dirección','Sistema hidráulico','Sistema eléctrico','Neumático y agua','Compresor','Lubricación','Extinción de incendios','Bastidor y chasis','Brazo (boom)','Unidad de avance','Perforadora']),
  ('Resemin Scalemin HT', 12, 'Scalemin',
   array['Motor diésel','Tren de potencia','Sistema hidráulico','Sistema eléctrico','Neumático y agua','Lubricación','Cabina y entorno del operador','Bastidor y chasis','Brazo (boom)','Tambor de cable y manguera','Martillo de desatado']),
  ('SmartROC T40', 13, 'SmartROC|T\s*40',
   array['Motor diésel','Sistema de enfriamiento','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Compresor','Neblina de agua','Lubricación','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Colector de polvo','Cabrestante']),
  ('PowerROC T50', 14, 'T\s*50',
   array['Motor diésel','Sistema de enfriamiento','Sistema hidráulico','Sistema eléctrico','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Colector de polvo']),
  ('PowerROC T25 / T30 / T35', 15, 'T\s*(25|30|35)',
   array['Motor diésel','Sistema de enfriamiento','Admisión y escape','Sistema hidráulico','Sistema eléctrico','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Colector de polvo']),
  ('PowerROC D55', 16, 'D\s*55',
   array['Motor diésel','Sistema de enfriamiento','Sistema hidráulico','Sistema eléctrico','Compresor','Neblina de agua','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Unidad de rotación','Manejo de barras','Colector de polvo','Cabrestante']),
  ('Furukawa HCR', 17, 'HCR|L\s*(90|100|110)|1[12]00\s*-?\s*ED',
   array['Motor diésel','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Colector de polvo']),
  ('Furukawa DCR', 18, 'DCR|L\s*130',
   array['Motor diésel','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Neumático y agua','Compresor','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Unidad de rotación','Manejo de barras','Colector de polvo']),
  ('XCMG XCZ115', 19, 'XCZ\s*115',
   array['Motor diésel','Sistema hidráulico','Sistema eléctrico','Compresor','Lubricación','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Manejo de barras','Colector de polvo']),
  ('XCMG XQZ152', 20, 'XQZ\s*152',
   array['Motor diésel','Sistema hidráulico','Sistema eléctrico','Neumático y agua','Compresor','Lubricación','Cabina y entorno del operador','Bastidor y chasis','Tren de rodaje (orugas)','Brazo (boom)','Unidad de avance','Perforadora','Unidad de rotación','Manejo de barras','Colector de polvo']),
  ('Putzmeister Mixkret 4', 21, 'Mixkret',
   array['Motor diésel','Tren de potencia','Frenos','Dirección','Sistema hidráulico','Sistema eléctrico','Neumático y agua','Extinción de incendios','Cabina y entorno del operador','Bastidor y chasis','Ruedas y neumáticos','Cuba mezcladora']),
  ('Putzmeister SPM 4210', 22, 'SPM|4210',
   array['Motor diésel','Tren de potencia','Sistema hidráulico','Sistema eléctrico','Control y electrónica','Compresor','Lubricación','Bastidor y chasis','Brazo (boom)','Tambor de cable y manguera','Bomba de concreto','Bomba dosificadora de aditivo']);

-- Un sistema mal escrito en la lista de arriba detiene la migración.
do $$
declare
  v_falta text;
begin
  select string_agg(distinct s, ', ') into v_falta
  from _familias, unnest(sistemas) s
  where not exists (select 1 from sistemas where nombre = s);
  if v_falta is not null then
    raise exception 'Sistemas que no están en el catálogo: %', v_falta;
  end if;
end $$;

insert into familias (nombre, orden)
select nombre, orden from _familias
on conflict (nombre) do update set orden = excluded.orden, activo = true;

-- Relaciones: se agregan las de la lista; las que el admin marcó a mano se conservan.
insert into familia_sistemas (familia_id, sistema_id)
select f.id, s.id
from _familias t
join familias f on f.nombre = t.nombre
cross join lateral unnest(t.sistemas) n
join sistemas s on s.nombre = n
on conflict do nothing;

-- 3. Equipos: los que no tienen familia, o están en una familia creada desde la flota
--    escrita (sin sistemas marcados), pasan a la familia que corresponde a su modelo.
--    Si el modelo calza con más de una familia, no se cambia.
with candidatos as (
  select e.id as equipo_id, min(f.id::text)::uuid as familia_id, count(*) as n
  from equipos e
  join _familias t on e.modelo ~* t.patron
  join familias f on f.nombre = t.nombre
  where e.familia_id is null
     or not exists (select 1 from familia_sistemas r where r.familia_id = e.familia_id)
  group by e.id
)
update equipos e
   set familia_id = c.familia_id,
       flota = (select nombre from familias where id = c.familia_id)
  from candidatos c
 where c.equipo_id = e.id and c.n = 1;

-- Las familias que quedaron sin equipos y sin sistemas (creadas desde la flota) se
-- desactivan; no se borran.
update familias f set activo = false
 where f.activo
   and not exists (select 1 from equipos e where e.familia_id = f.id)
   and not exists (select 1 from familia_sistemas r where r.familia_id = f.id)
   and f.nombre not in (select nombre from _familias);

drop table _familias;

-- ===== 017_varias_unidades.sql =====
-- Varias unidades por capturador o invitado. perfiles.unidades guarda todas las que
-- puede ver; unidad_id queda como la primera, para la restricción
-- perfiles_unidad_requerida y para la Edge Function admin-usuarios, que solo fija
-- unidad_id al crear (el disparador la pasa a unidades). El admin sigue viendo todas.
-- Se puede repetir.

alter table perfiles add column if not exists unidades uuid[] not null default '{}';
update perfiles set unidades = array[unidad_id] where cardinality(unidades) = 0 and unidad_id is not null;

create or replace function tg_perfil_unidades() returns trigger
language plpgsql as $$
begin
  new.unidades := coalesce(new.unidades, '{}');
  if tg_op = 'UPDATE' then
    -- Se quitaron todas las unidades: queda sin unidad (si está activo y no es admin,
    -- perfiles_unidad_requerida lo rechaza).
    if new.unidades is distinct from old.unidades and cardinality(new.unidades) = 0 then
      new.unidad_id := null;
      return new;
    end if;
    -- Cambio de unidad_id a la antigua (una sola unidad): reemplaza la lista.
    if new.unidad_id is distinct from old.unidad_id and new.unidades is not distinct from old.unidades
       and new.unidad_id is not null and not (new.unidad_id = any(new.unidades)) then
      new.unidades := array[new.unidad_id];
    end if;
  end if;
  if cardinality(new.unidades) = 0 and new.unidad_id is not null then
    new.unidades := array[new.unidad_id];
  elsif cardinality(new.unidades) > 0 and (new.unidad_id is null or not (new.unidad_id = any(new.unidades))) then
    new.unidad_id := new.unidades[1];
  end if;
  return new;
end $$;
drop trigger if exists perfil_unidades on perfiles;
create trigger perfil_unidades before insert or update on perfiles
  for each row execute function tg_perfil_unidades();

create or replace function unidades_actuales() returns uuid[]
language sql stable security definer set search_path = public as $$
  select unidades from perfiles where user_id = usuario_sesion() and activo
$$;

-- El admin ve y graba en todas las unidades; capturador e invitado, en las suyas.
create or replace function unidad_permitida(p_unidad uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(rol_actual() = 'admin', false)
      or (p_unidad is not null and p_unidad = any(coalesce(unidades_actuales(), '{}')))
$$;

revoke execute on function unidades_actuales() from public;
grant execute on function unidades_actuales() to authenticated;

-- ===== 018_capturador_autonomo.sql =====
-- Capturador autónomo (07/11/2026): el capturador avanza y retrocede los estados sin
-- depender del administrador (aprobar, esperar repuestos, programar, reprogramar,
-- ejecutar, validar, rechazar y anular) y edita el backlog mientras está abierto.
-- Una vez Validado, Rechazado o Anulado, el backlog queda bloqueado para el
-- capturador: solo el administrador lo revierte o lo borra.
-- Cada retroceso pide motivo y queda en la bitácora. Se puede repetir.
--
-- Flujo:
--   Identificado         -> En planificación | Rechazado | Anulado
--   En planificación     -> Esperando repuestos | Listo para programar | Identificado (atrás) | Anulado
--   Esperando repuestos  -> Listo para programar | En planificación (atrás) | Anulado
--   Listo para programar -> Programado | En planificación (atrás) | Anulado
--   Programado           -> Ejecutado | Programado (reprogramar) | Listo para programar (atrás) | Anulado
--   Ejecutado            -> Validado | Programado (atrás)
--   Validado             -> Ejecutado (atrás, solo admin)
--   Rechazado, Anulado   -> Identificado (reabrir, solo admin)

create or replace function cambiar_estado_backlog(p_id uuid, p_estado text, p_datos jsonb default '{}'::jsonb)
returns backlogs
language plpgsql security definer set search_path = public as $$
declare
  b           backlogs;
  v_rol       text := rol_actual();
  v_motivo    text := nullif(trim(p_datos->>'motivo'), '');
  v_coment    text := nullif(trim(p_datos->>'comentario'), '');
  v_tipo_ev   text := 'estado';
  v_pend      integer;
  v_total     integer;
  v_fecha     date;
  v_semana    date;
  v_anterior  text;
  v_detalle   text;
  v_fecha_ant date;
  v_atras     boolean;
begin
  select * into b from backlogs where id = p_id for update;
  if not found then
    raise exception 'Backlog inexistente';
  end if;
  if b.borrado_en is not null then
    raise exception 'El backlog % está borrado: no se edita', b.folio;
  end if;
  v_anterior := b.estado;
  if v_rol is null or v_rol = 'invitado' or not unidad_permitida(b.unidad_id) then
    raise exception 'Sin permiso para cambiar este backlog';
  end if;
  if p_estado = b.estado and p_estado <> 'Programado' then
    raise exception 'El backlog ya está %', b.estado;
  end if;

  select count(*), count(*) filter (where estado <> 'Recibido')
    into v_total, v_pend
  from backlog_repuestos where backlog_id = b.id;

  if not (
       (b.estado = 'Identificado'         and p_estado in ('En planificación','Rechazado','Anulado'))
    or (b.estado = 'En planificación'     and p_estado in ('Esperando repuestos','Listo para programar','Identificado','Anulado'))
    or (b.estado = 'Esperando repuestos'  and p_estado in ('Listo para programar','En planificación','Anulado'))
    or (b.estado = 'Listo para programar' and p_estado in ('Programado','En planificación','Anulado'))
    or (b.estado = 'Programado'           and p_estado in ('Ejecutado','Listo para programar','Programado','Anulado'))
    or (b.estado = 'Ejecutado'            and p_estado in ('Validado','Programado'))
    or (b.estado = 'Validado'             and p_estado = 'Ejecutado')
    or (b.estado in ('Rechazado','Anulado') and p_estado = 'Identificado')
  ) then
    raise exception 'No se puede pasar de % a %', b.estado, p_estado;
  end if;

  -- Validado, Rechazado y Anulado quedan bloqueados para el capturador.
  if v_rol <> 'admin' and b.estado in ('Validado','Rechazado','Anulado') then
    raise exception 'El backlog está %: solo el administrador puede revertirlo', b.estado;
  end if;

  -- Retrocesos: piden motivo.
  v_atras := (b.estado = 'En planificación' and p_estado = 'Identificado')
          or (b.estado in ('Esperando repuestos','Listo para programar') and p_estado = 'En planificación')
          or (b.estado = 'Programado' and p_estado = 'Listo para programar')
          or (b.estado = 'Ejecutado' and p_estado = 'Programado')
          or (b.estado = 'Validado' and p_estado = 'Ejecutado')
          or (b.estado in ('Rechazado','Anulado') and p_estado = 'Identificado');
  if v_atras and v_motivo is null then
    raise exception 'Indique el motivo para volver a %', p_estado;
  end if;

  perform set_config('backlog.transicion', 'si', true);

  if p_datos ? 'prioridad' and b.estado in ('Identificado','En planificación') then
    b.prioridad := p_datos->>'prioridad';
  end if;

  case p_estado
    when 'Identificado' then
      -- Reabrir un rechazado o anulado, o volver desde planificación.
      b.motivo_anulacion := null;
    when 'En planificación' then
      if b.estado = 'Identificado'
         and not exists (select 1 from backlog_hh where backlog_id = b.id and tipo = 'estimada') then
        raise exception 'Cargue las HH estimadas por especialidad antes de planificar';
      end if;
    when 'Esperando repuestos' then
      if v_pend = 0 then
        raise exception 'No hay repuestos pendientes de recibir';
      end if;
    when 'Listo para programar' then
      if v_pend > 0 and b.estado <> 'Programado' then
        raise exception 'Faltan % repuesto(s) por recibir', v_pend;
      end if;
      if b.estado = 'Programado' then
        b.reprogramaciones := b.reprogramaciones + 1;
        b.semana_programada := null;
        b.fecha_programada := null;
        v_tipo_ev := 'reprogramación';
      end if;
    when 'Programado' then
      if b.estado = 'Ejecutado' then
        -- Vuelve a programado: se borra la fecha de ejecución; fecha y OT se mantienen.
        b.fecha_ejecucion := null;
      else
        if b.estado = 'Programado' then
          -- Reprogramación directa: otra fecha, misma OT, con motivo.
          v_fecha_ant := b.fecha_programada;
          if v_motivo is null then
            raise exception 'Indique el motivo de la reprogramación';
          end if;
          if (p_datos->>'fecha_programada') is null or (p_datos->>'fecha_programada')::date = v_fecha_ant then
            raise exception 'Indique una fecha programada distinta a la actual';
          end if;
          b.reprogramaciones := b.reprogramaciones + 1;
          v_tipo_ev := 'reprogramación';
          v_detalle := format('%s → %s', to_char(v_fecha_ant, 'DD/MM/YYYY'),
                              to_char((p_datos->>'fecha_programada')::date, 'DD/MM/YYYY'));
        end if;
        v_fecha := coalesce((p_datos->>'fecha_programada')::date, b.fecha_programada);
        v_semana := coalesce((p_datos->>'semana_programada')::date, date_trunc('week', v_fecha)::date);
        b.ot_sap := coalesce(nullif(trim(p_datos->>'ot_sap'), ''), b.ot_sap);
        if v_fecha is null or b.ot_sap is null then
          raise exception 'Para programar indique fecha programada y N° de OT';
        end if;
        if v_fecha < hoy() then
          raise exception 'La fecha programada no puede ser pasada';
        end if;
        if date_trunc('week', v_fecha)::date <> v_semana then
          raise exception 'La fecha programada no cae en la semana indicada';
        end if;
        b.fecha_programada := v_fecha;
        b.semana_programada := v_semana;
        b.aprovechar_pm := coalesce((p_datos->>'aprovechar_pm')::boolean, b.aprovechar_pm);
      end if;
    when 'Ejecutado' then
      if b.estado = 'Programado' then
        v_fecha := (p_datos->>'fecha_ejecucion')::date;
        if v_fecha is null then
          raise exception 'Indique la fecha de ejecución';
        end if;
        if v_fecha > hoy() then
          raise exception 'La fecha de ejecución no puede ser futura';
        end if;
        if not exists (select 1 from backlog_hh where backlog_id = b.id and tipo = 'real') then
          raise exception 'Cargue las HH reales por especialidad antes de marcar ejecutado';
        end if;
        b.fecha_ejecucion := v_fecha;
      end if;
    when 'Rechazado', 'Anulado' then
      if v_motivo is null then
        raise exception 'Indique el motivo';
      end if;
      b.motivo_anulacion := v_motivo;
    else
      null;
  end case;

  update backlogs set
    estado = p_estado,
    prioridad = b.prioridad,
    ot_sap = b.ot_sap,
    semana_programada = b.semana_programada,
    fecha_programada = b.fecha_programada,
    aprovechar_pm = b.aprovechar_pm,
    fecha_ejecucion = b.fecha_ejecucion,
    reprogramaciones = b.reprogramaciones,
    motivo_anulacion = b.motivo_anulacion
  where id = b.id
  returning * into b;

  insert into backlog_eventos (backlog_id, tipo, estado_anterior, estado_nuevo, texto)
  values (b.id, v_tipo_ev, v_anterior, p_estado,
          nullif(concat_ws(' · ', case when v_atras then 'Retroceso' end, v_detalle, v_motivo, v_coment), ''));

  perform set_config('backlog.transicion', 'no', true);
  return b;
end $$;

revoke execute on function cambiar_estado_backlog(uuid, text, jsonb) from public;
grant execute on function cambiar_estado_backlog(uuid, text, jsonb) to authenticated;

-- Editar el backlog: el capturador mientras esté abierto (antes solo en Identificado).
drop policy if exists editar_backlogs on backlogs;
create policy editar_backlogs on backlogs for update to authenticated
  using (unidad_permitida(unidad_id)
         and (rol_actual() = 'admin'
              or (rol_actual() = 'capturador' and estado not in ('Validado','Rechazado','Anulado'))))
  with check (unidad_permitida(unidad_id));

-- Borrar: el capturador no borra un backlog Validado (solo el administrador).
create or replace function borrar_backlog(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_rol  text := rol_actual();
  b      backlogs;
begin
  select * into b from backlogs where id = p_id for update;
  if not found then
    raise exception 'Backlog inexistente';
  end if;
  if v_rol is null or v_rol not in ('admin', 'capturador') or not unidad_permitida(b.unidad_id) then
    raise exception 'Solo el administrador o un capturador de la unidad pueden borrar el backlog %', b.folio;
  end if;
  if v_rol <> 'admin' and b.estado = 'Validado' then
    raise exception 'El backlog % está Validado: solo el administrador puede borrarlo', b.folio;
  end if;
  if b.borrado_en is not null then
    raise exception 'El backlog % ya está borrado', b.folio;
  end if;
  if length(coalesce(trim(p_motivo), '')) < 5 then
    raise exception 'Indique el motivo del borrado (mínimo 5 letras)';
  end if;
  perform set_config('backlog.borrado', 'si', true);
  perform set_config('backlog.transicion', 'si', true);
  update backlogs
     set borrado_en = now(), borrado_por = usuario_sesion(), motivo_borrado = trim(p_motivo)
   where id = p_id;
  perform set_config('backlog.transicion', 'no', true);
  perform set_config('backlog.borrado', 'no', true);
  insert into backlog_eventos (backlog_id, tipo, estado_anterior, texto, usuario)
  values (p_id, 'borrado', b.estado, 'Borrado: ' || trim(p_motivo), usuario_sesion());
end $$;

-- ===== 019_preventivos.sql =====
-- CMMS 0.1.0 · Preventivo por horómetros sobre la base de backlog.
-- Trae el esquema de Control de Preventivos 0.6.0 (migraciones 001 a 017 de ese
-- repositorio) sin volver a crear unidades, perfiles, parametros ni equipos, que ya
-- existen aquí. Las tablas, vistas y funciones conservan los nombres de preventivos,
-- así la app Control de Preventivos puede apuntar a esta base sin cambios de código.
-- Diferencias con preventivos:
--   * El usuario de la sesión sale de usuario_sesion() (igual que auth.uid() en Supabase),
--     así todo corre también en la base local de pruebas.
--   * Las funciones de sesión y unidad (rol_actual, unidad_actual, unidades_actuales,
--     unidad_permitida, crear_perfil) son las de backlog; no se reemplazan.
-- Se puede repetir.

-- ---------------------------------------------------------------------------
-- Parámetros del control de horómetros
-- ---------------------------------------------------------------------------
insert into parametros (clave, valor, descripcion) values
  ('max_horas_turno',          12, 'Máximo de horas por turno; sobre esto la lectura es «Horas imposibles»'),
  ('umbral_cambio_horometro',   2, 'Baja de lectura mayor a esto = cambio de horómetro; menor o igual = error de digitación'),
  ('hueco_turnos',             14, 'Turnos sin lectura para avisar hueco (14 turnos = 7 días)'),
  ('tendencia_dias',           30, 'Ventana de la tendencia en días'),
  ('tendencia_max_turnos',     14, 'La tendencia excluye intervalos de más de estos turnos; si no hay datos, se calcula sin el filtro'),
  ('antiguedad_lectura_aviso', 30, 'Días de antigüedad de la última lectura para avisar en Observación')
on conflict (clave) do nothing;

-- ---------------------------------------------------------------------------
-- Equipos: columnas que usa preventivos
-- ---------------------------------------------------------------------------
alter table equipos add column if not exists fecha_inicio_operacion date;
alter table equipos add column if not exists creado_por uuid;
alter table equipos alter column creado_por set default usuario_sesion();

-- ---------------------------------------------------------------------------
-- Tablas de preventivos
-- ---------------------------------------------------------------------------
create table if not exists planes_mp (
  clave               text primary key,
  sistema             text not null,
  componente_desc     text,
  aplica_a            text,
  tipo_horometro_desc text,
  intervalo_h         numeric not null check (intervalo_h > 0),
  ciclo_gamas         numeric[] not null check (array_length(ciclo_gamas, 1) >= 1),
  dias_programar      integer not null,
  dias_verificar      integer not null,
  base_sin_pm         numeric,          -- si no hay PM registrado, la meta parte de aquí
  kits_sap            text,
  observaciones       text,
  orden               integer not null default 0
);

-- Unidad de control: cada fila de Control PM es un componente (equipo + tipo de horómetro).
create table if not exists componentes (
  id              uuid primary key default gen_random_uuid(),
  equipo_id       uuid not null references equipos(id),
  tipo_horometro  text not null check (tipo_horometro in
                    ('Diesel','Motor Eléctrico','Percusión #1','Percusión #2','Empernado')),
  nombre          text not null,
  sistema         text not null,
  seccion         integer not null default 1, -- 1 diésel · 2 compresor · 3 perforadoras y empernadoras
  cod_sap         text,
  plan_clave      text references planes_mp(clave),
  aplica_rutina40 boolean not null default false,
  lectura_manual  boolean not null default false,
  activo          boolean not null default true,
  creado_en       timestamptz not null default now(),
  unique (equipo_id, tipo_horometro)
);
create index if not exists componentes_equipo on componentes (equipo_id);

create table if not exists lecturas (
  id               uuid primary key default gen_random_uuid(),
  componente_id    uuid not null references componentes(id),
  fecha            date not null,
  turno            text not null check (turno in ('Dia','Noche')),
  lectura          numeric not null check (lectura >= 0),  -- lo que marca el contador al cierre del turno
  origen           text not null default 'app' check (origen in ('app','import','manual')),
  anulada          boolean not null default false,
  motivo_anulacion text,
  anulado_por      uuid,
  anulado_en       timestamptz,
  creado_por       uuid default usuario_sesion(),
  creado_en        timestamptz not null default now()
);
create unique index if not exists lecturas_unicas
  on lecturas (componente_id, fecha, turno) where not anulada;
create index if not exists lecturas_componente_fecha on lecturas (componente_id, fecha);

create table if not exists registros_pm (
  id               uuid primary key default gen_random_uuid(),
  componente_id    uuid not null references componentes(id),
  fecha            date not null,
  gama             numeric,                    -- null = sin gama (Control PM pide validar)
  lectura          numeric,                    -- contador del componente al ejecutar
  responsable      text,
  anulado          boolean not null default false,
  motivo_anulacion text,
  anulado_por      uuid,
  anulado_en       timestamptz,
  creado_por       uuid default usuario_sesion(),
  creado_en        timestamptz not null default now()
);
create index if not exists registros_pm_componente_fecha on registros_pm (componente_id, fecha);

create table if not exists cambios_horometro (
  id                    uuid primary key default gen_random_uuid(),
  componente_id         uuid not null references componentes(id),
  vigente_desde         date not null,
  offset_h              numeric not null,     -- offset TOTAL a sumar al contador desde esa fecha
  ultima_lectura_vieja  text,
  primera_lectura_nueva text,
  metodo                text,
  fuente                text,
  estado                text not null default 'Por validar' check (estado in ('Por validar','Validado')),
  creado_por            uuid default usuario_sesion(),
  creado_en             timestamptz not null default now()
);
create index if not exists cambios_componente_fecha on cambios_horometro (componente_id, vigente_desde);

-- Registro manual por turno (historial del Scooptram #4; ya no se usa para capturar).
create table if not exists registros_manuales (
  id             uuid primary key default gen_random_uuid(),
  componente_id  uuid not null references componentes(id),
  fecha          date not null,
  turno          text not null check (turno in ('Dia','Noche')),
  turno_texto    text,
  lectura_inicio numeric not null,
  lectura_final  numeric not null,
  lectura_id     uuid references lecturas(id),
  creado_por     uuid default usuario_sesion(),
  creado_en      timestamptz not null default now()
);

-- Columnas visibles de los tableros de control (configuración global del admin).
create table if not exists columnas_control (
  columna  text primary key,
  etiqueta text not null,
  visible  boolean not null default true,
  orden    integer not null
);
insert into columnas_control (columna, etiqueta, visible, orden) values
  ('nombre',                  'Componente',               true, 0),
  ('cod_sap',                 'Cód. interno',             true, 1),
  ('modelo',                  'Modelo',                   false, 2),
  ('fecha_ultimo_pm',         'Fecha último PM',          true, 3),
  ('gama_ultimo_pm',          'Gama último PM',           true, 4),
  ('horometro_ultimo_pm',     'Horómetro último PM',      true, 5),
  ('proxima_gama',            'Próxima gama',             true, 6),
  ('meta_acum',               'Meta (acum.)',             true, 7),
  ('meta_contador',           'Meta (contador)',          true, 8),
  ('ultima_lectura_acum',     'Última lectura (acum.)',   true, 9),
  ('ultima_lectura_contador', 'Última lectura (contador)', true, 10),
  ('fecha_ultima_lectura',    'Fecha última lectura',     true, 11),
  ('hrs_faltantes',           'Hrs faltantes',            true, 12),
  ('tendencia',               'Tendencia (h/día)',        true, 13),
  ('dias_restantes',          'Días restantes',           true, 14),
  ('fecha_estimada',          'Fecha estimada',           true, 15),
  ('estado',                  'Estado',                   true, 16),
  ('observacion',             'Observación',              true, 17)
on conflict (columna) do nothing;

-- ---------------------------------------------------------------------------
-- Funciones de cálculo
-- ---------------------------------------------------------------------------

-- Offset total vigente a una fecha: el del último "vigente desde" <= fecha
-- (si hay varios renglones con esa misma fecha, se suman, igual que el libro).
create or replace function offset_vigente(p_componente uuid, p_fecha date) returns numeric
language sql stable as $$
  select coalesce((
    select sum(c.offset_h)
    from cambios_horometro c
    where c.componente_id = p_componente
      and c.vigente_desde = (
        select max(c2.vigente_desde) from cambios_horometro c2
        where c2.componente_id = p_componente and c2.vigente_desde <= p_fecha)
  ), 0)
$$;

-- N° de turno correlativo: 2 por día, Noche después de Dia.
create or replace function n_turno(p_fecha date, p_turno text) returns integer
language sql immutable as $$
  select (p_fecha - date '2000-01-01') * 2 + case when p_turno = 'Noche' then 1 else 0 end
$$;

create or replace function unidad_de_equipo(p_equipo uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select unidad_id from equipos where id = p_equipo
$$;

create or replace function unidad_de_componente(p_componente uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select e.unidad_id from componentes c join equipos e on e.id = c.equipo_id where c.id = p_componente
$$;

-- ---------------------------------------------------------------------------
-- Vistas (versiones finales de preventivos 010 y 014)
-- ---------------------------------------------------------------------------

-- Lecturas con validación y acumulado. Las horas entre lecturas se calculan en
-- acumulado cuando entre ambas cambia el offset vigente.
create or replace view v_lecturas as
with base0 as (
  select l.*, n_turno(l.fecha, l.turno) as nt, offset_vigente(l.componente_id, l.fecha) as ofs
  from lecturas l
  where not l.anulada
),
base as (
  select b.*,
         lag(b.nt) over w as nt_prev,
         lag(b.lectura) over w as lectura_prev,
         lag(b.ofs) over w as ofs_prev
  from base0 b
  window w as (partition by b.componente_id order by b.nt)
),
horas as (
  select b.*,
         case when b.nt_prev is null then null
              when b.ofs <> b.ofs_prev then greatest((b.lectura + b.ofs) - (b.lectura_prev + b.ofs_prev), 0)
              when b.lectura >= b.lectura_prev then b.lectura - b.lectura_prev
              when b.lectura_prev - b.lectura <= param('umbral_cambio_horometro') then 0
              else b.lectura end as h,
         case when b.nt_prev is null then null
              when b.ofs <> b.ofs_prev then (b.lectura + b.ofs) - (b.lectura_prev + b.ofs_prev)
              else b.lectura - b.lectura_prev end as delta
  from base b
)
select x.id, x.componente_id, x.fecha, x.turno, x.lectura, x.origen, x.creado_por, x.creado_en,
       x.nt as num_turno,
       x.nt - x.nt_prev as turnos_transcurridos,
       x.h as horas_intervalo,
       x.lectura + x.ofs as lectura_acum,
       case
         when x.nt_prev is null then 'Primer registro'
         when x.h > (x.nt - x.nt_prev) * param('max_horas_turno') then 'Horas imposibles'
         when x.delta < 0 and -x.delta <= param('umbral_cambio_horometro') then 'Lectura menor a la anterior (validar)'
         when x.delta < 0 then 'Cambio de horómetro (validar)'
         when x.nt - x.nt_prev > param('hueco_turnos') then 'Hueco de ' || round((x.nt - x.nt_prev) / 2.0) || ' día(s)'
         else 'OK'
       end as control
from horas x;

-- Registros PM con clase y acumulado.
create or replace view v_registros_pm as
select r.id, r.componente_id, r.fecha, r.gama, r.lectura, r.responsable, r.creado_por, r.creado_en,
       case when r.gama is null then 'Sin gama'
            when r.gama = 40 then 'Rutina 40 h'
            else 'Mayor' end as clase,
       case when r.lectura is null then null
            else r.lectura + offset_vigente(r.componente_id, r.fecha) end as lectura_acum
from registros_pm r
where not r.anulado;

-- Última lectura de cada componente.
create or replace view v_ultima_lectura as
select distinct on (l.componente_id)
       l.componente_id, l.fecha, l.turno, l.lectura, l.lectura_acum, l.num_turno
from v_lecturas l
order by l.componente_id, l.num_turno desc;

-- Control PM (PM mayor): una fila por componente activo con plan.
-- Gamas repetidas en el ciclo se resuelven con la gama ancla: el último PM cuya gama
-- aparece una sola vez en el ciclo fija la posición; se avanza un paso por PM posterior.
create or replace view v_control_pm as
with comp as (
  select c.id, c.equipo_id, c.tipo_horometro, c.nombre, c.sistema, c.seccion, c.cod_sap,
         c.activo, c.lectura_manual,
         e.cod_interno, e.modelo, e.unidad_id,
         p.clave as plan_clave, p.intervalo_h, p.ciclo_gamas, p.dias_programar, p.dias_verificar,
         p.base_sin_pm, array_length(p.ciclo_gamas, 1) as ciclo_len
  from componentes c
  join equipos e on e.id = c.equipo_id
  left join planes_mp p on p.clave = c.plan_clave
  where c.activo and e.activo
),
ult_pm as (  -- último PM que no es rutina de 40 h (incluye los de gama sin validar)
  select distinct on (r.componente_id)
         r.componente_id, r.fecha,
         max(r.gama) over (partition by r.componente_id, r.fecha) as gama,
         max(r.lectura_acum) over (partition by r.componente_id, r.fecha) as lectura_acum
  from v_registros_pm r
  where r.clase <> 'Rutina 40 h'
  order by r.componente_id, r.fecha desc
),
ancla as (   -- último PM mayor cuya gama es única dentro del ciclo del plan
  select distinct on (r.componente_id)
         r.componente_id, r.fecha as ancla_fecha, r.gama as ancla_gama
  from v_registros_pm r
  join comp on comp.id = r.componente_id
  where r.clase <> 'Rutina 40 h'
    and r.gama is not null
    and r.gama = any (comp.ciclo_gamas)
    and (select count(*) from unnest(comp.ciclo_gamas) g where g = r.gama) = 1
  order by r.componente_id, r.fecha desc
),
pos as (
  select comp.id as componente_id,
         case
           when u.fecha is null then null
           when a.ancla_fecha is null then array_position(comp.ciclo_gamas, u.gama)
           else ((array_position(comp.ciclo_gamas, a.ancla_gama) - 1
                 + (select count(*) from v_registros_pm r
                    where r.componente_id = comp.id and r.clase <> 'Rutina 40 h'
                      and r.fecha > a.ancla_fecha)
                 ) % comp.ciclo_len) + 1
         end as pos_ultimo
  from comp
  left join ult_pm u on u.componente_id = comp.id
  left join ancla a on a.componente_id = comp.id
),
ult_lect as (
  select distinct on (l.componente_id)
         l.componente_id, l.fecha, l.lectura, l.num_turno
  from v_lecturas l
  order by l.componente_id, l.num_turno desc
),
tend as (
  select l.componente_id,
         sum(l.horas_intervalo) filter (where l.turnos_transcurridos <= param('tendencia_max_turnos')) as h1,
         sum(l.turnos_transcurridos) filter (where l.turnos_transcurridos <= param('tendencia_max_turnos')) as t1,
         sum(l.horas_intervalo) as h2,
         sum(l.turnos_transcurridos) as t2
  from v_lecturas l
  join ult_lect u on u.componente_id = l.componente_id
  where l.fecha >= u.fecha - (param('tendencia_dias')::int - 1)
    and l.horas_intervalo is not null
  group by l.componente_id
),
calc as (
  select comp.*,
         u.fecha  as fecha_ultimo_pm,
         u.gama   as gama_ultimo_pm,
         coalesce(u.lectura_acum, comp.base_sin_pm) as horometro_ultimo_pm,
         p.pos_ultimo,
         ul.fecha as fecha_ultima_lectura,
         ul.lectura as ultima_lectura_contador,
         case when ul.fecha is null then 0
              else offset_vigente(comp.id, ul.fecha) end as offset_act,
         case when t.t1 > 0 then round(t.h1 / (t.t1 / 2.0), 2)
              when t.t2 > 0 then round(t.h2 / (t.t2 / 2.0), 2)
              else null end as tendencia
  from comp
  left join ult_pm u on u.componente_id = comp.id
  left join pos p on p.componente_id = comp.id
  left join ult_lect ul on ul.componente_id = comp.id
  left join tend t on t.componente_id = comp.id
),
calc2 as (
  select c.*,
         case when c.horometro_ultimo_pm is null then null
              else c.horometro_ultimo_pm + c.intervalo_h end as meta_acum,
         case when c.ultima_lectura_contador is null then null
              else c.ultima_lectura_contador + c.offset_act end as ultima_lectura_acum,
         case
           when c.horometro_ultimo_pm is null then null
           when c.pos_ultimo is null then
             case when c.fecha_ultimo_pm is null then c.ciclo_gamas[1]::text
                  else 'Validar gama' end
           else c.ciclo_gamas[(c.pos_ultimo % c.ciclo_len) + 1]::text
         end as proxima_gama
  from calc c
),
calc3 as (
  select c.*,
         case when c.meta_acum is null then null else c.meta_acum - c.offset_act end as meta_contador,
         case when c.fecha_ultima_lectura is null then null
              else hoy() - c.fecha_ultima_lectura end as antiguedad_dias,
         case when c.meta_acum is null or c.ultima_lectura_acum is null then null
              else c.meta_acum - c.ultima_lectura_acum end as hrs_faltantes
  from calc2 c
),
calc4 as (
  select c.*,
         case
           when c.hrs_faltantes is null or c.fecha_ultima_lectura is null then null
           when c.hrs_faltantes <= 0 then coalesce(
             (select min(l.fecha) from v_lecturas l
              where l.componente_id = c.id
                and l.lectura >= c.meta_acum - c.offset_act
                and l.fecha >= coalesce(c.fecha_ultimo_pm, date '1900-01-01')),
             c.fecha_ultima_lectura)
           when c.tendencia is null or c.tendencia = 0 then null
           else c.fecha_ultima_lectura + floor(c.hrs_faltantes / c.tendencia)::int
         end as fecha_estimada
  from calc3 c
)
select c.id as componente_id, c.cod_interno, c.cod_sap, c.modelo, c.nombre, c.sistema, c.seccion,
       c.tipo_horometro, c.plan_clave, c.lectura_manual,
       c.fecha_ultimo_pm, c.gama_ultimo_pm, c.horometro_ultimo_pm,
       c.proxima_gama, c.meta_acum, c.meta_contador,
       c.ultima_lectura_acum, c.ultima_lectura_contador, c.fecha_ultima_lectura,
       c.antiguedad_dias, c.hrs_faltantes, c.tendencia,
       case when c.fecha_estimada is null then null
            else c.fecha_estimada - hoy() end as dias_restantes,
       c.fecha_estimada,
       case
         when c.plan_clave is null then 'Plan no definido'
         when c.ultima_lectura_acum is null then '⚪ Sin lecturas'
         when c.horometro_ultimo_pm is null then '⚪ Sin PM registrado'
         when c.hrs_faltantes <= 0 then '🔴 Vencido'
         when c.fecha_estimada is null then '⚪ Sin tendencia'
         when c.fecha_estimada - hoy() < 0 then '🔴 Vencido'
         when c.fecha_estimada - hoy() <= c.dias_programar then '📅 Programar'
         when c.fecha_estimada - hoy() <= c.dias_verificar then '🔧 Verificar repuestos'
         else '🟢 Normal'
       end as estado,
       trim(
         case when exists (select 1 from cambios_horometro ch
                           where ch.componente_id = c.id and ch.estado = 'Por validar')
              then '⚠ Cambio de horómetro por validar. ' else '' end ||
         case when c.proxima_gama = 'Validar gama'
              then '⚠ Última gama no registrada. ' else '' end ||
         case when c.antiguedad_dias > param('antiguedad_lectura_aviso')
              then '⚠ Lectura con ' || c.antiguedad_dias || ' días de antigüedad. ' else '' end ||
         case when c.fecha_ultimo_pm is null and c.base_sin_pm is not null
              then 'Sin PM registrado: meta desde ' || c.base_sin_pm || ' h. ' else '' end
       ) as observacion,
       c.unidad_id, un.nombre as unidad
from calc4 c
left join unidades un on un.id = c.unidad_id;

-- Rutina de percusión de 40 h: una fila por brazo. Cualquier PM reinicia el conteo.
create or replace view v_control_40 as
with plan as (
  select * from planes_mp where clave = 'RUTINA-40'
),
comp as (
  select c.id, c.tipo_horometro, c.nombre, c.sistema, c.cod_sap,
         e.cod_interno, e.modelo, e.unidad_id
  from componentes c
  join equipos e on e.id = c.equipo_id
  where c.activo and e.activo and c.aplica_rutina40
),
ult_pm as (
  select distinct on (r.componente_id)
         r.componente_id, r.fecha,
         max(r.gama) over (partition by r.componente_id, r.fecha) as gama,
         max(r.lectura_acum) over (partition by r.componente_id, r.fecha) as lectura_acum
  from v_registros_pm r
  order by r.componente_id, r.fecha desc
),
ult_lect as (
  select distinct on (l.componente_id)
         l.componente_id, l.fecha, l.lectura, l.num_turno
  from v_lecturas l
  order by l.componente_id, l.num_turno desc
),
tend as (
  select l.componente_id,
         sum(l.horas_intervalo) filter (where l.turnos_transcurridos <= param('tendencia_max_turnos')) as h1,
         sum(l.turnos_transcurridos) filter (where l.turnos_transcurridos <= param('tendencia_max_turnos')) as t1,
         sum(l.horas_intervalo) as h2,
         sum(l.turnos_transcurridos) as t2
  from v_lecturas l
  join ult_lect u on u.componente_id = l.componente_id
  where l.fecha >= u.fecha - (param('tendencia_dias')::int - 1)
    and l.horas_intervalo is not null
  group by l.componente_id
),
calc as (
  select comp.*,
         plan.intervalo_h, plan.dias_programar, plan.dias_verificar,
         u.fecha as fecha_ultimo_pm, u.gama as gama_ultimo_pm, u.lectura_acum as horometro_ultimo_pm,
         ul.fecha as fecha_ultima_lectura, ul.lectura as ultima_lectura_contador,
         case when ul.fecha is null then 0 else offset_vigente(comp.id, ul.fecha) end as offset_act,
         case when t.t1 > 0 then round(t.h1 / (t.t1 / 2.0), 2)
              when t.t2 > 0 then round(t.h2 / (t.t2 / 2.0), 2)
              else null end as tendencia
  from comp cross join plan
  left join ult_pm u on u.componente_id = comp.id
  left join ult_lect ul on ul.componente_id = comp.id
  left join tend t on t.componente_id = comp.id
),
calc2 as (
  select c.*,
         case when c.horometro_ultimo_pm is null then null
              else c.horometro_ultimo_pm + c.intervalo_h end as meta_acum,
         case when c.ultima_lectura_contador is null then null
              else c.ultima_lectura_contador + c.offset_act end as ultima_lectura_acum
  from calc c
),
calc3 as (
  select c.*,
         case when c.meta_acum is null then null else c.meta_acum - c.offset_act end as meta_contador,
         case when c.fecha_ultima_lectura is null then null
              else hoy() - c.fecha_ultima_lectura end as antiguedad_dias,
         case when c.meta_acum is null or c.ultima_lectura_acum is null then null
              else c.meta_acum - c.ultima_lectura_acum end as hrs_faltantes
  from calc2 c
),
calc4 as (
  select c.*,
         case
           when c.hrs_faltantes is null or c.fecha_ultima_lectura is null then null
           when c.hrs_faltantes <= 0 then coalesce(
             (select min(l.fecha) from v_lecturas l
              where l.componente_id = c.id
                and l.lectura >= c.meta_acum - c.offset_act
                and l.fecha >= coalesce(c.fecha_ultimo_pm, date '1900-01-01')),
             c.fecha_ultima_lectura)
           when c.tendencia is null or c.tendencia = 0 then null
           else c.fecha_ultima_lectura + floor(c.hrs_faltantes / c.tendencia)::int
         end as fecha_estimada
  from calc3 c
)
select c.id as componente_id, c.cod_interno, c.cod_sap, c.modelo, c.nombre, c.sistema,
       c.tipo_horometro,
       c.fecha_ultimo_pm, c.gama_ultimo_pm, c.horometro_ultimo_pm,
       40::numeric as proxima_gama, c.meta_acum, c.meta_contador,
       c.ultima_lectura_acum, c.ultima_lectura_contador, c.fecha_ultima_lectura,
       c.antiguedad_dias, c.hrs_faltantes, c.tendencia,
       case when c.fecha_estimada is null then null
            else c.fecha_estimada - hoy() end as dias_restantes,
       c.fecha_estimada,
       case
         when c.ultima_lectura_acum is null then '⚪ Sin lecturas'
         when c.horometro_ultimo_pm is null then '⚪ Sin PM registrado'
         when c.hrs_faltantes <= 0 then '🔴 Vencido'
         when c.fecha_estimada is null then '⚪ Sin tendencia'
         when c.fecha_estimada - hoy() < 0 then '🔴 Vencido'
         when c.fecha_estimada - hoy() <= c.dias_programar then '📅 Programar'
         when c.fecha_estimada - hoy() <= c.dias_verificar then '🔧 Verificar repuestos'
         else '🟢 Normal'
       end as estado,
       case when c.gama_ultimo_pm is distinct from 40 and c.fecha_ultimo_pm is not null
            then 'Sin rutina 40 h registrada: el conteo parte del último MP mayor.' else '' end as observacion,
       c.unidad_id, un.nombre as unidad
from calc4 c
left join unidades un on un.id = c.unidad_id;

-- Cumplimiento: cada PM mayor contra la meta que tenía al ejecutarse.
create or replace view v_cumplimiento_pm as
with pm as (
  select r.componente_id, r.fecha, max(r.gama) as gama, max(r.lectura_acum) as lectura_acum
  from v_registros_pm r
  where r.clase <> 'Rutina 40 h'
  group by r.componente_id, r.fecha
),
seq as (
  select pm.*,
         lag(pm.lectura_acum) over w as acum_anterior,
         lag(pm.fecha) over w as fecha_anterior,
         row_number() over w as n
  from pm
  window w as (partition by pm.componente_id order by pm.fecha)
),
meta as (
  select s.*, c.sistema, c.seccion, c.nombre, c.tipo_horometro, e.id as equipo_id, e.cod_interno, e.unidad_id,
         p.intervalo_h,
         case when s.n = 1 then p.base_sin_pm else s.acum_anterior end + p.intervalo_h as meta_acum
  from seq s
  join componentes c on c.id = s.componente_id
  join equipos e on e.id = c.equipo_id
  left join planes_mp p on p.clave = c.plan_clave
)
select m.componente_id, m.equipo_id, m.cod_interno, m.nombre, m.tipo_horometro, m.sistema, m.seccion,
       m.fecha, date_trunc('month', m.fecha)::date as mes, m.gama, m.lectura_acum,
       m.fecha_anterior, m.meta_acum,
       m.lectura_acum - m.meta_acum as horas_atraso,
       case when m.lectura_acum is null or m.meta_acum is null then null
            else m.lectura_acum <= m.meta_acum end as a_tiempo,
       m.unidad_id, un.nombre as unidad
from meta m
left join unidades un on un.id = m.unidad_id;

-- Utilización: horas por día de cada componente por mes.
create or replace view v_utilizacion_mensual as
select l.componente_id, c.equipo_id, e.cod_interno, c.nombre, c.tipo_horometro, c.seccion,
       date_trunc('month', l.fecha)::date as mes,
       sum(l.horas_intervalo) as horas,
       sum(l.turnos_transcurridos) / 2.0 as dias,
       round(sum(l.horas_intervalo) / nullif(sum(l.turnos_transcurridos) / 2.0, 0), 2) as h_dia,
       count(*) as lecturas,
       e.unidad_id, un.nombre as unidad
from v_lecturas l
join componentes c on c.id = l.componente_id
join equipos e on e.id = c.equipo_id
left join unidades un on un.id = e.unidad_id
where l.horas_intervalo is not null and c.activo and e.activo
group by l.componente_id, c.equipo_id, e.cod_interno, c.nombre, c.tipo_horometro, c.seccion,
         date_trunc('month', l.fecha), e.unidad_id, un.nombre;

-- Las vistas respetan las políticas de las tablas base.
alter view v_lecturas set (security_invoker = true);
alter view v_registros_pm set (security_invoker = true);
alter view v_ultima_lectura set (security_invoker = true);
alter view v_control_pm set (security_invoker = true);
alter view v_control_40 set (security_invoker = true);
alter view v_cumplimiento_pm set (security_invoker = true);
alter view v_utilizacion_mensual set (security_invoker = true);

-- ---------------------------------------------------------------------------
-- Validaciones de captura (preventivos 007 y 010)
-- ---------------------------------------------------------------------------

-- Control de lecturas en registros PM, en horas acumuladas.
create or replace function validar_registro_pm(
  p_componente uuid,
  p_fecha date,
  p_lectura numeric,
  p_excluir uuid default null
) returns text
language plpgsql stable as $$
declare
  v_acum    numeric;
  v_max_dia numeric := 2 * param('max_horas_turno');
  v_tol     numeric := param('umbral_cambio_horometro');
  v_fecha   date;
  v_ref     numeric;
  v_dias    integer;
begin
  if p_componente is null or p_fecha is null or p_lectura is null then
    return null;
  end if;
  v_acum := p_lectura + offset_vigente(p_componente, p_fecha);

  -- PM anterior (incluye el mismo día)
  select r.fecha, r.lectura + offset_vigente(r.componente_id, r.fecha)
    into v_fecha, v_ref
  from registros_pm r
  where r.componente_id = p_componente and not r.anulado and r.lectura is not null
    and r.fecha <= p_fecha and r.id is distinct from p_excluir
  order by r.fecha desc, r.lectura + offset_vigente(r.componente_id, r.fecha) desc
  limit 1;
  if found then
    if v_acum < v_ref then
      return format('Lectura menor al PM anterior del %s (%s h acumuladas). Si el horómetro se reinició, registre primero el cambio de horómetro.',
                    to_char(v_fecha, 'DD/MM/YYYY'), round(v_ref, 1));
    end if;
    v_dias := p_fecha - v_fecha;
    if v_acum - v_ref > (v_dias + 1) * v_max_dia then
      return format('Horas imposibles: %s h desde el PM anterior del %s, en %s día(s); el máximo posible es %s h.',
                    round(v_acum - v_ref, 1), to_char(v_fecha, 'DD/MM/YYYY'), v_dias, (v_dias + 1) * v_max_dia);
    end if;
  end if;

  -- PM posterior
  select r.fecha, r.lectura + offset_vigente(r.componente_id, r.fecha)
    into v_fecha, v_ref
  from registros_pm r
  where r.componente_id = p_componente and not r.anulado and r.lectura is not null
    and r.fecha > p_fecha and r.id is distinct from p_excluir
  order by r.fecha asc, r.lectura + offset_vigente(r.componente_id, r.fecha) asc
  limit 1;
  if found and v_acum > v_ref then
    return format('Lectura mayor al PM posterior del %s (%s h acumuladas).',
                  to_char(v_fecha, 'DD/MM/YYYY'), round(v_ref, 1));
  end if;

  -- Última lectura de horómetro de un día anterior
  select l.fecha, l.lectura_acum into v_fecha, v_ref
  from v_lecturas l
  where l.componente_id = p_componente and l.fecha < p_fecha
  order by l.num_turno desc
  limit 1;
  if found then
    if v_acum < v_ref - v_tol then
      return format('Lectura menor a la lectura de horómetro del %s (%s h acumuladas). Si el horómetro se reinició, registre primero el cambio de horómetro.',
                    to_char(v_fecha, 'DD/MM/YYYY'), round(v_ref, 1));
    end if;
    v_dias := p_fecha - v_fecha;
    if v_acum - v_ref > (v_dias + 1) * v_max_dia then
      return format('Horas imposibles: %s h desde la lectura de horómetro del %s, en %s día(s); el máximo posible es %s h.',
                    round(v_acum - v_ref, 1), to_char(v_fecha, 'DD/MM/YYYY'), v_dias, (v_dias + 1) * v_max_dia);
    end if;
  end if;

  -- Primera lectura de horómetro de un día posterior
  select l.fecha, l.lectura_acum into v_fecha, v_ref
  from v_lecturas l
  where l.componente_id = p_componente and l.fecha > p_fecha
  order by l.num_turno asc
  limit 1;
  if found and v_acum > v_ref + v_tol then
    return format('Lectura mayor a la lectura de horómetro del %s (%s h acumuladas), que es posterior al PM.',
                  to_char(v_fecha, 'DD/MM/YYYY'), round(v_ref, 1));
  end if;

  return null;
end $$;

create or replace function tg_validar_registro_pm() returns trigger
language plpgsql as $$
declare
  v_msg text;
begin
  if new.anulado then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.lectura is not distinct from old.lectura
     and new.fecha = old.fecha
     and new.componente_id = old.componente_id
     and old.anulado = false then
    return new;
  end if;
  v_msg := validar_registro_pm(new.componente_id, new.fecha, new.lectura, new.id);
  if v_msg is not null then
    raise exception using message = v_msg, errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists validar_registro_pm on registros_pm;
create trigger validar_registro_pm
  before insert or update on registros_pm
  for each row execute function tg_validar_registro_pm();

-- Control de lecturas de horómetro, en horas acumuladas.
create or replace function validar_lectura(
  p_componente uuid,
  p_fecha date,
  p_turno text,
  p_lectura numeric,
  p_excluir uuid default null
) returns json
language plpgsql stable as $$
declare
  v_nt     integer;
  v_acum   numeric;
  v_max    numeric := param('max_horas_turno');
  v_tol    numeric := param('umbral_cambio_horometro');
  v_hueco  numeric := param('hueco_turnos');
  r        record;
  v_turnos integer;
  v_horas  numeric;
  v_aviso  text;
begin
  if p_componente is null or p_fecha is null or p_turno is null or p_lectura is null then
    return null;
  end if;
  v_nt := n_turno(p_fecha, p_turno);
  v_acum := p_lectura + offset_vigente(p_componente, p_fecha);

  if exists (select 1 from lecturas l
             where l.componente_id = p_componente and not l.anulada and l.fecha = p_fecha
               and l.turno = p_turno and l.id is distinct from p_excluir) then
    return json_build_object('nivel', 'error', 'mensaje', 'Duplicado: ya hay lectura de ese turno');
  end if;

  select l.fecha, l.turno, l.lectura, n_turno(l.fecha, l.turno) as nt,
         l.lectura + offset_vigente(l.componente_id, l.fecha) as acum
    into r
  from lecturas l
  where l.componente_id = p_componente and not l.anulada and l.id is distinct from p_excluir
    and n_turno(l.fecha, l.turno) < v_nt
  order by n_turno(l.fecha, l.turno) desc
  limit 1;

  if not found then
    v_aviso := 'Primer registro';
  else
    v_turnos := v_nt - r.nt;
    if v_acum < r.acum - v_tol then
      return json_build_object('nivel', 'error', 'mensaje', format(
        'Lectura %s h menor que la anterior (%s h el %s %s). Si se cambió o reinició el horómetro, registre primero el cambio en Cambios horómetro.',
        trim_scale(round(r.acum - v_acum, 1)), trim_scale(round(r.lectura, 1)), to_char(r.fecha, 'DD/MM/YYYY'), r.turno));
    end if;
    v_horas := greatest(v_acum - r.acum, 0);
    if v_horas > v_turnos * v_max then
      return json_build_object('nivel', 'error', 'mensaje', format(
        'Horas imposibles: %s h en %s turno(s) desde la lectura del %s %s; el máximo es %s h.',
        trim_scale(round(v_horas, 1)), v_turnos, to_char(r.fecha, 'DD/MM/YYYY'), r.turno, v_turnos * v_max));
    end if;
    if v_acum < r.acum then
      v_aviso := 'Lectura menor a la anterior (validar)';
    elsif v_turnos > v_hueco then
      v_aviso := format('Hueco de %s día(s) sin lectura', round(v_turnos / 2.0));
    end if;
  end if;

  select l.fecha, l.turno, l.lectura, n_turno(l.fecha, l.turno) as nt,
         l.lectura + offset_vigente(l.componente_id, l.fecha) as acum
    into r
  from lecturas l
  where l.componente_id = p_componente and not l.anulada and l.id is distinct from p_excluir
    and n_turno(l.fecha, l.turno) > v_nt
  order by n_turno(l.fecha, l.turno) asc
  limit 1;
  if found then
    if v_acum > r.acum + v_tol then
      return json_build_object('nivel', 'error', 'mensaje', format(
        'Lectura mayor que la lectura posterior del %s %s (%s h).',
        to_char(r.fecha, 'DD/MM/YYYY'), r.turno, trim_scale(round(r.lectura, 1))));
    end if;
    if r.acum - v_acum > (r.nt - v_nt) * v_max then
      return json_build_object('nivel', 'error', 'mensaje', format(
        'Horas imposibles hasta la lectura del %s %s: %s h en %s turno(s).',
        to_char(r.fecha, 'DD/MM/YYYY'), r.turno, trim_scale(round(r.acum - v_acum, 1)), r.nt - v_nt));
    end if;
  end if;

  return json_build_object('nivel', case when v_aviso is null then 'ok' else 'aviso' end,
                           'mensaje', coalesce(v_aviso, 'OK'));
end $$;

create or replace function tg_validar_lectura() returns trigger
language plpgsql as $$
declare
  v json;
begin
  if new.anulada then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.lectura = old.lectura and new.fecha = old.fecha and new.turno = old.turno
     and new.componente_id = old.componente_id and old.anulada = false then
    return new;
  end if;
  v := validar_lectura(new.componente_id, new.fecha, new.turno, new.lectura, new.id);
  if v->>'nivel' = 'error' then
    raise exception using message = v->>'mensaje', errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists validar_lectura on lecturas;
create trigger validar_lectura
  before insert or update on lecturas
  for each row execute function tg_validar_lectura();

-- Auditoría de anulaciones: quién anuló y cuándo (la app no manda estos campos).
create or replace function tg_auditar_anulacion() returns trigger
language plpgsql as $$
declare
  v_antes   boolean := coalesce(to_jsonb(old)->>'anulada', to_jsonb(old)->>'anulado')::boolean;
  v_despues boolean := coalesce(to_jsonb(new)->>'anulada', to_jsonb(new)->>'anulado')::boolean;
begin
  if v_despues and not v_antes then
    new.anulado_por := usuario_sesion();
    new.anulado_en := now();
  elsif not v_despues then
    new.anulado_por := null;
    new.anulado_en := null;
  else
    new.anulado_por := old.anulado_por;
    new.anulado_en := old.anulado_en;
  end if;
  return new;
end $$;

drop trigger if exists auditar_anulacion on lecturas;
create trigger auditar_anulacion
  before update on lecturas
  for each row execute function tg_auditar_anulacion();

drop trigger if exists auditar_anulacion on registros_pm;
create trigger auditar_anulacion
  before update on registros_pm
  for each row execute function tg_auditar_anulacion();

-- ---------------------------------------------------------------------------
-- Seguridad por rol y unidad (preventivos 002, 004 y 015)
--   lectura:  cualquier perfil activo, en sus unidades
--   captura:  admin y capturador insertan lecturas, PM, cambios y registros manuales
--   cambios posteriores (anular, validar, editar) y administración: solo admin
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['planes_mp','componentes','lecturas','registros_pm','cambios_horometro',
                           'registros_manuales','columnas_control'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists administrar_%I on %I', t, t);
    execute format('create policy administrar_%I on %I for all to authenticated
                    using (rol_actual() = ''admin'') with check (rol_actual() = ''admin'')', t, t);
  end loop;

  foreach t in array array['planes_mp','columnas_control'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format('create policy leer_%I on %I for select to authenticated
                    using (rol_actual() is not null)', t, t);
  end loop;

  foreach t in array array['lecturas','registros_pm','cambios_horometro','registros_manuales'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format('create policy leer_%I on %I for select to authenticated
                    using (rol_actual() is not null and unidad_permitida(unidad_de_componente(componente_id)))', t, t);
    execute format('drop policy if exists capturar_%I on %I', t, t);
    execute format('create policy capturar_%I on %I for insert to authenticated
                    with check (rol_actual() in (''admin'',''capturador'')
                                and unidad_permitida(unidad_de_componente(componente_id)))', t, t);
  end loop;
end $$;

drop policy if exists leer_componentes on componentes;
create policy leer_componentes on componentes for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_de_equipo(equipo_id)));

revoke execute on function unidad_de_equipo(uuid), unidad_de_componente(uuid),
  validar_registro_pm(uuid, date, numeric, uuid),
  validar_lectura(uuid, date, text, numeric, uuid) from public;
grant execute on function unidad_de_equipo(uuid), unidad_de_componente(uuid),
  validar_registro_pm(uuid, date, numeric, uuid),
  validar_lectura(uuid, date, text, numeric, uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on v_lecturas, v_registros_pm, v_ultima_lectura, v_control_pm, v_control_40,
      v_cumplimiento_pm, v_utilizacion_mensual to authenticated;
  end if;
end $$;

-- Tiempo real de Supabase.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['planes_mp','componentes','lecturas','registros_pm','cambios_horometro',
                             'registros_manuales','columnas_control','unidades'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table %I', t);
      end if;
    end loop;
  end if;
end $$;

-- ===== 020_ordenes_trabajo.sql =====
-- CMMS 0.2.0 · Órdenes de trabajo para el tablero de programación.
-- Una OT junta en un equipo, día y turno un PM (mayor o rutina 40 h) y/o backlogs.
-- El tablero crea, mueve, agrupa y anula OT solo con las funciones de abajo; la app no
-- escribe las tablas directo. La ejecución y el cierre de la OT vienen después.
-- Los backlogs ligados pasan a Programado con cambiar_estado_backlog() (misma regla
-- que el Calendario de backlog), con el folio de la OT como N° de OT si no tienen otro.
-- Se puede repetir.

create table if not exists folios_ot (
  unidad_id  uuid primary key references unidades(id),
  ultimo     integer not null default 0
);

create table if not exists ordenes_trabajo (
  id                 uuid primary key default gen_random_uuid(),
  folio              text not null unique,                  -- OT-HEM-000001
  unidad_id          uuid not null references unidades(id),
  equipo_id          uuid not null references equipos(id),
  tipo               text not null check (tipo in ('Preventiva','Rutina 40 h','Correctiva','Emergencia')),
  componente_id      uuid references componentes(id),       -- PM: el componente del horómetro
  plan_clave         text references planes_mp(clave),
  gama               numeric,
  fecha_estimada_pm  date,                                  -- la de Control PM al programar
  titulo             text not null,
  prioridad          text check (prioridad in ('P1','P2','P3','P4')),
  estado             text not null default 'Programada' check (estado in
                       ('Programada','En ejecución','Ejecutada','Cerrada','Anulada')),
  fecha              date not null,
  turno              text not null check (turno in ('Dia','Noche')),
  reprogramaciones   integer not null default 0,
  motivo_anulacion   text,
  creado_por         uuid default usuario_sesion(),
  creado_en          timestamptz not null default now(),
  actualizado_en     timestamptz not null default now(),
  constraint ot_pm_con_componente check (tipo not in ('Preventiva','Rutina 40 h') or componente_id is not null)
);
create index if not exists ot_unidad_fecha on ordenes_trabajo (unidad_id, fecha);
create index if not exists ot_equipo on ordenes_trabajo (equipo_id);
-- Un componente no tiene dos OT abiertas del mismo tipo de PM.
create unique index if not exists ot_pm_abierta on ordenes_trabajo (componente_id, tipo)
  where componente_id is not null and estado in ('Programada','En ejecución');

-- Backlogs que se hacen en la OT. Un backlog está en una sola OT a la vez.
create table if not exists ot_backlogs (
  ot_id       uuid not null references ordenes_trabajo(id),
  backlog_id  uuid not null references backlogs(id),
  creado_en   timestamptz not null default now(),
  primary key (ot_id, backlog_id),
  unique (backlog_id)
);

-- HH estándar del PM en la OT (las de los backlogs salen de backlog_hh).
create table if not exists ot_hh (
  ot_id            uuid not null references ordenes_trabajo(id),
  especialidad_id  uuid not null references especialidades(id),
  hh               numeric not null check (hh >= 0),
  primary key (ot_id, especialidad_id)
);

create table if not exists ot_eventos (
  id         uuid primary key default gen_random_uuid(),
  ot_id      uuid not null references ordenes_trabajo(id),
  tipo       text not null check (tipo in ('creación','reprogramación','backlog','anulación','comentario')),
  texto      text,
  usuario    uuid default usuario_sesion(),
  creado_en  timestamptz not null default now()
);
create index if not exists ot_eventos_ot on ot_eventos (ot_id, creado_en);

-- HH estándar por plan y gama (gama vacía = todas las gamas del plan). Las carga el admin;
-- sin pauta, la OT preventiva sale sin HH y el tablero lo avisa.
create table if not exists pautas_gama (
  id               uuid primary key default gen_random_uuid(),
  plan_clave       text not null references planes_mp(clave),
  gama             numeric,
  especialidad_id  uuid not null references especialidades(id),
  hh               numeric not null check (hh > 0)
);
create unique index if not exists pautas_gama_unica
  on pautas_gama (plan_clave, coalesce(gama, -1), especialidad_id);

-- ---------------------------------------------------------------------------
-- Funciones
-- ---------------------------------------------------------------------------

create or replace function unidad_de_ot(p_ot uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select unidad_id from ordenes_trabajo where id = p_ot
$$;

-- Permiso común: admin o capturador de la unidad.
create or replace function ot_validar_permiso(p_unidad uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if rol_actual() is null or rol_actual() not in ('admin','capturador') or not unidad_permitida(p_unidad) then
    raise exception 'Sin permiso para programar en esta unidad';
  end if;
end $$;

create or replace function ot_nueva(p_equipo uuid, p_tipo text, p_titulo text, p_fecha date, p_turno text,
                                    p_prioridad text default null, p_componente uuid default null,
                                    p_plan text default null, p_gama numeric default null,
                                    p_fecha_estimada date default null)
returns ordenes_trabajo
language plpgsql security definer set search_path = public as $$
declare
  e      equipos;
  v_num  integer;
  v_sig  text;
  o      ordenes_trabajo;
begin
  select * into e from equipos where id = p_equipo;
  if not found or not e.activo then raise exception 'Equipo inexistente o inactivo'; end if;
  perform ot_validar_permiso(e.unidad_id);
  if p_fecha is null or p_turno not in ('Dia','Noche') then raise exception 'Indique día y turno'; end if;
  if p_fecha < hoy() then raise exception 'La fecha programada no puede ser pasada'; end if;
  insert into folios_ot (unidad_id, ultimo) values (e.unidad_id, 1)
  on conflict (unidad_id) do update set ultimo = folios_ot.ultimo + 1
  returning ultimo into v_num;
  select sigla into v_sig from unidades where id = e.unidad_id;
  insert into ordenes_trabajo (folio, unidad_id, equipo_id, tipo, componente_id, plan_clave, gama,
                               fecha_estimada_pm, titulo, prioridad, fecha, turno)
  values (format('OT-%s-%s', v_sig, lpad(v_num::text, 6, '0')), e.unidad_id, e.id, p_tipo, p_componente,
          p_plan, p_gama, p_fecha_estimada, p_titulo, p_prioridad, p_fecha, p_turno)
  returning * into o;
  insert into ot_eventos (ot_id, tipo, texto)
  values (o.id, 'creación', format('%s %s %s', p_tipo, to_char(p_fecha, 'DD/MM/YYYY'), p_turno));
  return o;
end $$;

-- Programa el próximo PM de un componente: tipo 'Preventiva' (gama siguiente de Control PM)
-- o 'Rutina 40 h'. Las HH salen de pautas_gama.
create or replace function programar_pm(p_componente uuid, p_tipo text, p_fecha date, p_turno text)
returns ordenes_trabajo
language plpgsql security definer set search_path = public as $$
declare
  c        componentes;
  v_gama   numeric;
  v_plan   text;
  v_est    date;
  v_texto  text;
  o        ordenes_trabajo;
begin
  select * into c from componentes where id = p_componente;
  if not found or not c.activo then raise exception 'Componente inexistente o inactivo'; end if;
  if exists (select 1 from ordenes_trabajo where componente_id = c.id and tipo = p_tipo
             and estado in ('Programada','En ejecución')) then
    raise exception 'El componente ya tiene una OT de % abierta', p_tipo;
  end if;
  if p_tipo = 'Preventiva' then
    select proxima_gama, fecha_estimada into v_texto, v_est from v_control_pm where componente_id = c.id;
    if v_texto is null then raise exception 'El componente no tiene PM calculado en Control PM'; end if;
    if v_texto = 'Validar gama' then raise exception 'Registre la gama del último PM antes de programar'; end if;
    v_gama := v_texto::numeric;
    v_plan := c.plan_clave;
    v_texto := format('PM %s h · %s', trim_scale(v_gama), c.nombre);
  elsif p_tipo = 'Rutina 40 h' then
    if not c.aplica_rutina40 then raise exception 'El componente no lleva rutina de 40 h'; end if;
    select fecha_estimada into v_est from v_control_40 where componente_id = c.id;
    v_gama := 40;
    v_plan := 'RUTINA-40';
    v_texto := format('Rutina 40 h · %s', c.nombre);
  else
    raise exception 'Tipo de PM no válido: %', p_tipo;
  end if;
  o := ot_nueva(c.equipo_id, p_tipo, v_texto, p_fecha, p_turno, null, c.id, v_plan, v_gama, v_est);
  insert into ot_hh (ot_id, especialidad_id, hh)
  select o.id, p.especialidad_id, p.hh
  from pautas_gama p
  where p.plan_clave = v_plan
    and (p.gama = v_gama
         or (p.gama is null and not exists (select 1 from pautas_gama q where q.plan_clave = v_plan
                                            and q.gama = v_gama and q.especialidad_id = p.especialidad_id)));
  return o;
end $$;

-- Liga un backlog a una OT y lo deja Programado en la fecha de la OT.
create or replace function ot_ligar_backlog(o ordenes_trabajo, b backlogs, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into ot_backlogs (ot_id, backlog_id) values (o.id, b.id);
  if b.estado = 'Listo para programar' then
    perform cambiar_estado_backlog(b.id, 'Programado', jsonb_build_object(
      'fecha_programada', o.fecha, 'ot_sap', coalesce(b.ot_sap, o.folio),
      'aprovechar_pm', o.tipo in ('Preventiva','Rutina 40 h')));
  elsif b.fecha_programada is distinct from o.fecha then
    perform cambiar_estado_backlog(b.id, 'Programado', jsonb_build_object(
      'fecha_programada', o.fecha, 'motivo', coalesce(p_motivo, 'Agrupado en ' || o.folio)));
  end if;
  insert into ot_eventos (ot_id, tipo, texto) values (o.id, 'backlog', 'Agrega ' || b.folio);
end $$;

-- Programa un backlog: en una OT existente (p_ot) o en una OT correctiva nueva.
-- Acepta backlogs Listo para programar y Programado sin OT (programados desde el Calendario).
create or replace function programar_backlog(p_backlog uuid, p_fecha date, p_turno text,
                                             p_ot uuid default null, p_motivo text default null)
returns ordenes_trabajo
language plpgsql security definer set search_path = public as $$
declare
  b  backlogs;
  o  ordenes_trabajo;
begin
  select * into b from backlogs where id = p_backlog for update;
  if not found or b.borrado_en is not null then raise exception 'Backlog inexistente'; end if;
  perform ot_validar_permiso(b.unidad_id);
  if b.estado not in ('Listo para programar','Programado') then
    raise exception 'El backlog % está %: solo se programan los listos para programar', b.folio, b.estado;
  end if;
  if exists (select 1 from ot_backlogs where backlog_id = b.id) then
    raise exception 'El backlog % ya está en una OT: mueva la OT', b.folio;
  end if;
  if p_ot is not null then
    select * into o from ordenes_trabajo where id = p_ot for update;
    if not found or o.estado <> 'Programada' then raise exception 'La OT no está programada'; end if;
    if o.equipo_id <> b.equipo_id then raise exception 'El backlog es de otro equipo'; end if;
  else
    o := ot_nueva(b.equipo_id, case when b.prioridad = 'P1' then 'Emergencia' else 'Correctiva' end,
                  b.descripcion, p_fecha, p_turno, b.prioridad);
  end if;
  perform ot_ligar_backlog(o, b, p_motivo);
  return o;
end $$;

-- Mueve una OT a otro día o turno. Cambiar de día pide motivo y reprograma sus backlogs.
create or replace function mover_ot(p_ot uuid, p_fecha date, p_turno text, p_motivo text default null)
returns ordenes_trabajo
language plpgsql security definer set search_path = public as $$
declare
  o       ordenes_trabajo;
  v_ant   date;
  r       record;
  v_mot   text := nullif(trim(p_motivo), '');
begin
  select * into o from ordenes_trabajo where id = p_ot for update;
  if not found then raise exception 'OT inexistente'; end if;
  perform ot_validar_permiso(o.unidad_id);
  if o.estado <> 'Programada' then raise exception 'La OT % está %: no se mueve', o.folio, o.estado; end if;
  if p_turno not in ('Dia','Noche') then raise exception 'Turno no válido'; end if;
  if p_fecha < hoy() then raise exception 'La fecha programada no puede ser pasada'; end if;
  if p_fecha = o.fecha and p_turno = o.turno then return o; end if;
  v_ant := o.fecha;
  if p_fecha <> v_ant and v_mot is null then raise exception 'Indique el motivo de la reprogramación'; end if;
  update ordenes_trabajo set fecha = p_fecha, turno = p_turno, actualizado_en = now(),
         reprogramaciones = reprogramaciones + case when p_fecha <> v_ant then 1 else 0 end
  where id = o.id returning * into o;
  if p_fecha <> v_ant then
    for r in select b.id, b.estado, b.fecha_programada from ot_backlogs ob join backlogs b on b.id = ob.backlog_id
             where ob.ot_id = o.id loop
      if r.estado = 'Programado' and r.fecha_programada is distinct from p_fecha then
        perform cambiar_estado_backlog(r.id, 'Programado',
          jsonb_build_object('fecha_programada', p_fecha, 'motivo', format('%s: %s', o.folio, v_mot)));
      end if;
    end loop;
  end if;
  insert into ot_eventos (ot_id, tipo, texto)
  values (o.id, 'reprogramación', concat_ws(' · ',
    format('%s → %s %s', to_char(v_ant, 'DD/MM/YYYY'), to_char(p_fecha, 'DD/MM/YYYY'), p_turno), v_mot));
  return o;
end $$;

-- Saca un backlog de su OT: vuelve a Listo para programar. Una OT correctiva que queda
-- sin backlogs se anula.
create or replace function quitar_backlog_ot(p_backlog uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  o      ordenes_trabajo;
  b      backlogs;
  v_mot  text := nullif(trim(p_motivo), '');
begin
  select o2.* into o from ot_backlogs ob join ordenes_trabajo o2 on o2.id = ob.ot_id where ob.backlog_id = p_backlog;
  if not found then raise exception 'El backlog no está en una OT'; end if;
  perform ot_validar_permiso(o.unidad_id);
  if v_mot is null then raise exception 'Indique el motivo'; end if;
  select * into b from backlogs where id = p_backlog;
  delete from ot_backlogs where backlog_id = p_backlog;
  if b.estado = 'Programado' then
    perform cambiar_estado_backlog(b.id, 'Listo para programar',
      jsonb_build_object('motivo', format('Sale de %s: %s', o.folio, v_mot)));
  end if;
  insert into ot_eventos (ot_id, tipo, texto) values (o.id, 'backlog', format('Quita %s · %s', b.folio, v_mot));
  if o.tipo in ('Correctiva','Emergencia') and not exists (select 1 from ot_backlogs where ot_id = o.id) then
    update ordenes_trabajo set estado = 'Anulada', motivo_anulacion = 'Sin backlogs', actualizado_en = now() where id = o.id;
    insert into ot_eventos (ot_id, tipo, texto) values (o.id, 'anulación', 'Sin backlogs');
  end if;
end $$;

-- Anula una OT: sus backlogs vuelven a Listo para programar.
create or replace function anular_ot(p_ot uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  o      ordenes_trabajo;
  r      record;
  v_mot  text := nullif(trim(p_motivo), '');
begin
  select * into o from ordenes_trabajo where id = p_ot for update;
  if not found then raise exception 'OT inexistente'; end if;
  perform ot_validar_permiso(o.unidad_id);
  if o.estado not in ('Programada','En ejecución') then raise exception 'La OT % ya está %', o.folio, o.estado; end if;
  if v_mot is null then raise exception 'Indique el motivo'; end if;
  for r in select b.id, b.estado from ot_backlogs ob join backlogs b on b.id = ob.backlog_id where ob.ot_id = o.id loop
    delete from ot_backlogs where backlog_id = r.id;
    if r.estado = 'Programado' then
      perform cambiar_estado_backlog(r.id, 'Listo para programar',
        jsonb_build_object('motivo', format('%s anulada: %s', o.folio, v_mot)));
    end if;
  end loop;
  update ordenes_trabajo set estado = 'Anulada', motivo_anulacion = v_mot, actualizado_en = now() where id = o.id;
  insert into ot_eventos (ot_id, tipo, texto) values (o.id, 'anulación', v_mot);
end $$;

-- ---------------------------------------------------------------------------
-- Vistas del tablero
-- ---------------------------------------------------------------------------

-- HH de cada OT por especialidad: las del PM (ot_hh) más las estimadas de sus backlogs.
create or replace view v_ot_hh as
select ot_id, especialidad_id, sum(hh) as hh
from (
  select h.ot_id, h.especialidad_id, h.hh from ot_hh h
  union all
  select ob.ot_id, bh.especialidad_id, bh.hh
  from ot_backlogs ob join backlog_hh bh on bh.backlog_id = ob.backlog_id and bh.tipo = 'estimada'
) x
group by ot_id, especialidad_id;

create or replace view v_ot as
select o.*, e.cod_interno, e.modelo, e.familia_id, coalesce(f.nombre, e.flota) as flota,
       c.nombre as componente, c.tipo_horometro, un.nombre as unidad,
       coalesce((select sum(h.hh) from v_ot_hh h where h.ot_id = o.id), 0) as hh_total,
       coalesce((select jsonb_agg(jsonb_build_object(
                   'id', b.id, 'folio', b.folio, 'descripcion', b.descripcion, 'prioridad', b.prioridad,
                   'estado', b.estado, 'fecha_programada', b.fecha_programada) order by b.folio)
                 from ot_backlogs ob join backlogs b on b.id = ob.backlog_id where ob.ot_id = o.id), '[]'::jsonb) as backlogs,
       trim(
         case when o.fecha_estimada_pm is not null and o.fecha > o.fecha_estimada_pm
              then format('PM después de su fecha estimada (%s). ', to_char(o.fecha_estimada_pm, 'DD/MM/YYYY')) else '' end ||
         case when o.tipo in ('Preventiva','Rutina 40 h') and not exists (select 1 from ot_hh h where h.ot_id = o.id)
              then 'Sin HH estándar para esta gama. ' else '' end ||
         case when exists (select 1 from ot_backlogs ob join backlogs b on b.id = ob.backlog_id
                           where ob.ot_id = o.id and b.estado = 'Programado' and b.fecha_programada is distinct from o.fecha)
              then 'Un backlog tiene otra fecha en el Calendario. ' else '' end
       ) as avisos
from ordenes_trabajo o
join equipos e on e.id = o.equipo_id
left join familias f on f.id = e.familia_id
left join componentes c on c.id = o.componente_id
left join unidades un on un.id = o.unidad_id;

alter view v_ot_hh set (security_invoker = true);
alter view v_ot set (security_invoker = true);

-- ---------------------------------------------------------------------------
-- Seguridad: se lee por unidad; se escribe solo con las funciones (security definer).
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['folios_ot','ordenes_trabajo','ot_backlogs','ot_hh','ot_eventos','pautas_gama'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists leer_%I on %I', t, t);
  end loop;
end $$;
create policy leer_ordenes_trabajo on ordenes_trabajo for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_id));
create policy leer_ot_backlogs on ot_backlogs for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_de_ot(ot_id)));
create policy leer_ot_hh on ot_hh for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_de_ot(ot_id)));
create policy leer_ot_eventos on ot_eventos for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_de_ot(ot_id)));
create policy leer_pautas_gama on pautas_gama for select to authenticated using (rol_actual() is not null);
drop policy if exists administrar_pautas_gama on pautas_gama;
create policy administrar_pautas_gama on pautas_gama for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

revoke execute on function unidad_de_ot(uuid), ot_validar_permiso(uuid),
  ot_nueva(uuid, text, text, date, text, text, uuid, text, numeric, date),
  ot_ligar_backlog(ordenes_trabajo, backlogs, text) from public, anon, authenticated;
grant execute on function unidad_de_ot(uuid) to authenticated;
revoke execute on function programar_pm(uuid, text, date, text), programar_backlog(uuid, date, text, uuid, text),
  mover_ot(uuid, date, text, text), quitar_backlog_ot(uuid, text), anular_ot(uuid, text) from public, anon;
grant execute on function programar_pm(uuid, text, date, text), programar_backlog(uuid, date, text, uuid, text),
  mover_ot(uuid, date, text, text), quitar_backlog_ot(uuid, text), anular_ot(uuid, text) to authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on v_ot, v_ot_hh to authenticated;
  end if;
end $$;

do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['ordenes_trabajo','ot_backlogs','ot_hh','pautas_gama'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table %I', t);
      end if;
    end loop;
  end if;
end $$;
