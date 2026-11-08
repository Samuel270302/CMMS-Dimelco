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
