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
