-- Esquema principal: control de mantenimiento preventivo HEMCO
-- Replica la lógica del libro "Registro de horometros HEMCO v2" (guía 1.0, 15/10/2026).
-- Convención: lecturas y registros PM guardan SIEMPRE lo que marca el contador;
-- el acumulado se deriva con los offsets de cambios_horometro (offset total vigente por fecha).

create table if not exists parametros (
  clave  text primary key,
  valor  numeric,
  valor_texto text,
  descripcion text
);

insert into parametros (clave, valor, descripcion) values
  ('max_horas_turno',        12, 'Máximo de horas por turno; sobre esto la lectura es «Horas imposibles»'),
  ('umbral_cambio_horometro', 2, 'Baja de lectura mayor a esto = cambio de horómetro; menor o igual = error de digitación'),
  ('hueco_turnos',           14, 'Turnos sin lectura para avisar hueco (14 turnos = 7 días)'),
  ('tendencia_dias',         30, 'Ventana de la tendencia en días'),
  ('tendencia_max_turnos',   14, 'La tendencia excluye intervalos de más de estos turnos; si no hay datos, se calcula sin el filtro'),
  ('antiguedad_lectura_aviso', 30, 'Días de antigüedad de la última lectura para avisar en Observación')
on conflict (clave) do nothing;

insert into parametros (clave, valor, valor_texto, descripcion) values
  ('fecha_referencia', null, null, 'Solo pruebas: fija el «hoy» de los controles (YYYY-MM-DD). Vacío = fecha actual')
on conflict (clave) do nothing;

create or replace function hoy() returns date
language sql stable as $fn$
  select coalesce(
    (select nullif(valor_texto, '')::date from parametros where clave = 'fecha_referencia'),
    current_date)
$fn$;

create table if not exists perfiles (
  user_id   uuid primary key,
  nombre    text not null,
  correo    text,
  rol       text not null check (rol in ('admin','capturador')),
  activo    boolean not null default true,
  creado_en timestamptz not null default now()
);

create table if not exists planes_mp (
  clave            text primary key,
  sistema          text not null,
  componente_desc  text,
  aplica_a         text,
  tipo_horometro_desc text,
  intervalo_h      numeric not null check (intervalo_h > 0),
  ciclo_gamas      numeric[] not null check (array_length(ciclo_gamas, 1) >= 1),
  dias_programar   integer not null,
  dias_verificar   integer not null,
  base_sin_pm      numeric,          -- si no hay PM registrado, la meta parte de aquí
  kits_sap         text,
  observaciones    text,
  orden            integer not null default 0
);

create table if not exists equipos (
  id            uuid primary key default gen_random_uuid(),
  cod_interno   text not null unique,        -- Scooptram #1, Boomer #2...
  cod_sap       text,
  modelo        text not null,
  fecha_inicio_operacion date,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  creado_por    uuid
);

-- Unidad de control: cada fila de Control PM es un componente (equipo + tipo de horómetro).
create table if not exists componentes (
  id              uuid primary key default gen_random_uuid(),
  equipo_id       uuid not null references equipos(id),
  tipo_horometro  text not null check (tipo_horometro in
                    ('Diesel','Motor Eléctrico','Percusión #1','Percusión #2','Empernado')),
  nombre          text not null,             -- Motor Diésel · Compresor · Perforadora B1 · COP 1838HD+ ...
  sistema         text not null,             -- Motor Diésel / Compresor / Perforadora / Empernadora
  seccion         integer not null default 1,-- 1 diésel · 2 compresor · 3 perforadoras y empernadoras
  cod_sap         text,                      -- del percutor en perforadoras/empernadoras; del equipo en el resto
  plan_clave      text references planes_mp(clave),
  aplica_rutina40 boolean not null default false,
  lectura_manual  boolean not null default false, -- caso Scooptram #4: acumulado reconstruido por turno
  activo          boolean not null default true,  -- compresores Boomer #2/#3 sin horómetro instalado = false
  creado_en       timestamptz not null default now(),
  unique (equipo_id, tipo_horometro)
);

create table if not exists lecturas (
  id             uuid primary key default gen_random_uuid(),
  componente_id  uuid not null references componentes(id),
  fecha          date not null,
  turno          text not null check (turno in ('Dia','Noche')),
  lectura        numeric not null check (lectura >= 0),  -- lo que marca el contador al cierre del turno
  origen         text not null default 'app' check (origen in ('app','import','manual')),
  anulada        boolean not null default false,
  motivo_anulacion text,
  creado_por     uuid,
  creado_en      timestamptz not null default now()
);

create unique index if not exists lecturas_unicas
  on lecturas (componente_id, fecha, turno) where not anulada;
create index if not exists lecturas_componente_fecha on lecturas (componente_id, fecha);

create table if not exists registros_pm (
  id             uuid primary key default gen_random_uuid(),
  componente_id  uuid not null references componentes(id),
  fecha          date not null,
  gama           numeric,                    -- null = sin gama (Control PM pide validar)
  lectura        numeric,                    -- contador del componente al ejecutar
  responsable    text,
  anulado        boolean not null default false,
  motivo_anulacion text,
  creado_por     uuid,
  creado_en      timestamptz not null default now()
);

create index if not exists registros_pm_componente_fecha on registros_pm (componente_id, fecha);

create table if not exists cambios_horometro (
  id             uuid primary key default gen_random_uuid(),
  componente_id  uuid not null references componentes(id),
  vigente_desde  date not null,
  offset_h       numeric not null,           -- offset TOTAL a sumar al contador desde esa fecha
  ultima_lectura_vieja  text,
  primera_lectura_nueva text,
  metodo         text,
  fuente         text,
  estado         text not null default 'Por validar' check (estado in ('Por validar','Validado')),
  creado_por     uuid,
  creado_en      timestamptz not null default now()
);

create index if not exists cambios_componente_fecha on cambios_horometro (componente_id, vigente_desde);

-- Registro manual por turno (Scooptram #4: el horómetro no retiene la lectura).
-- Al grabar, la app inserta además la lectura reconstruida en lecturas (origen = 'manual').
create table if not exists registros_manuales (
  id             uuid primary key default gen_random_uuid(),
  componente_id  uuid not null references componentes(id),
  fecha          date not null,
  turno          text not null check (turno in ('Dia','Noche')),
  turno_texto    text,
  lectura_inicio numeric not null,
  lectura_final  numeric not null,
  lectura_id     uuid references lecturas(id),
  creado_por     uuid,
  creado_en      timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Funciones y vistas de cálculo
-- ---------------------------------------------------------------------------

create or replace function param(p_clave text) returns numeric
language sql stable as $$
  select valor from parametros where clave = p_clave
$$;

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

-- N° de turno correlativo: 2 por día, Noche después de Dia (equivale a fecha*2 + noche del libro).
create or replace function n_turno(p_fecha date, p_turno text) returns integer
language sql immutable as $$
  select (p_fecha - date '2000-01-01') * 2 + case when p_turno = 'Noche' then 1 else 0 end
$$;

-- Lecturas con validación (la columna Control del libro) y acumulado.
create or replace view v_lecturas as
with base as (
  select l.*,
         n_turno(l.fecha, l.turno) as nt,
         lag(n_turno(l.fecha, l.turno)) over w as nt_prev,
         lag(l.lectura) over w as lectura_prev
  from lecturas l
  where not l.anulada
  window w as (partition by l.componente_id order by n_turno(l.fecha, l.turno))
)
select b.id, b.componente_id, b.fecha, b.turno, b.lectura, b.origen, b.creado_por, b.creado_en,
       b.nt as num_turno,
       b.nt - b.nt_prev as turnos_transcurridos,
       case when b.nt_prev is null then null
            when b.lectura >= b.lectura_prev then b.lectura - b.lectura_prev
            when b.lectura_prev - b.lectura <= param('umbral_cambio_horometro') then 0
            else b.lectura end as horas_intervalo,
       b.lectura + offset_vigente(b.componente_id, b.fecha) as lectura_acum,
       case
         when b.nt_prev is null then 'Primer registro'
         when (case when b.lectura >= b.lectura_prev then b.lectura - b.lectura_prev
                    when b.lectura_prev - b.lectura <= param('umbral_cambio_horometro') then 0
                    else b.lectura end) > (b.nt - b.nt_prev) * param('max_horas_turno')
           then 'Horas imposibles'
         when b.lectura < b.lectura_prev and b.lectura_prev - b.lectura <= param('umbral_cambio_horometro')
           then 'Lectura menor a la anterior (validar)'
         when b.lectura < b.lectura_prev
           then 'Cambio de horómetro (validar)'
         when b.nt - b.nt_prev > param('hueco_turnos')
           then 'Hueco de ' || round((b.nt - b.nt_prev) / 2.0) || ' día(s)'
         else 'OK'
       end as control
from base b;

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

-- Control PM (PM mayor): una fila por componente activo con plan.
-- Gamas repetidas en el ciclo se resuelven con la gama ancla: el último PM cuya gama
-- aparece una sola vez en el ciclo fija la posición; se avanza un paso por PM posterior.
create or replace view v_control_pm as
with comp as (
  select c.id, c.equipo_id, c.tipo_horometro, c.nombre, c.sistema, c.seccion, c.cod_sap,
         c.activo, c.lectura_manual,
         e.cod_interno, e.modelo,
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
         coalesce(u.lectura_acum, comp.base_sin_pm) as horometro_ultimo_pm,   -- G
         p.pos_ultimo,
         ul.fecha as fecha_ultima_lectura,                                    -- M
         ul.lectura as ultima_lectura_contador,                               -- L / AD
         case when ul.fecha is null then 0
              else offset_vigente(comp.id, ul.fecha) end as offset_act,       -- AE
         case when t.t1 > 0 then round(t.h1 / (t.t1 / 2.0), 2)
              when t.t2 > 0 then round(t.h2 / (t.t2 / 2.0), 2)
              else null end as tendencia                                      -- P
  from comp
  left join ult_pm u on u.componente_id = comp.id
  left join pos p on p.componente_id = comp.id
  left join ult_lect ul on ul.componente_id = comp.id
  left join tend t on t.componente_id = comp.id
),
calc2 as (
  select c.*,
         case when c.horometro_ultimo_pm is null then null
              else c.horometro_ultimo_pm + c.intervalo_h end as meta_acum,    -- I
         case when c.ultima_lectura_contador is null then null
              else c.ultima_lectura_contador + c.offset_act end as ultima_lectura_acum,  -- K
         case
           when c.horometro_ultimo_pm is null then null
           when c.pos_ultimo is null then
             case when c.fecha_ultimo_pm is null then c.ciclo_gamas[1]::text
                  else 'Validar gama' end
           else c.ciclo_gamas[(c.pos_ultimo % c.ciclo_len) + 1]::text
         end as proxima_gama                                                  -- H
  from calc c
),
calc3 as (
  select c.*,
         case when c.meta_acum is null then null else c.meta_acum - c.offset_act end as meta_contador,  -- J
         case when c.fecha_ultima_lectura is null then null
              else hoy() - c.fecha_ultima_lectura end as antiguedad_dias,                        -- N
         case when c.meta_acum is null or c.ultima_lectura_acum is null then null
              else c.meta_acum - c.ultima_lectura_acum end as hrs_faltantes                             -- O
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
         end as fecha_estimada                                                -- R
  from calc3 c
)
select c.id as componente_id, c.cod_interno, c.cod_sap, c.modelo, c.nombre, c.sistema, c.seccion,
       c.tipo_horometro, c.plan_clave, c.lectura_manual,
       c.fecha_ultimo_pm, c.gama_ultimo_pm, c.horometro_ultimo_pm,
       c.proxima_gama, c.meta_acum, c.meta_contador,
       c.ultima_lectura_acum, c.ultima_lectura_contador, c.fecha_ultima_lectura,
       c.antiguedad_dias, c.hrs_faltantes, c.tendencia,
       case when c.fecha_estimada is null then null
            else c.fecha_estimada - hoy() end as dias_restantes,       -- Q
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
       ) as observacion
from calc4 c;

-- Control de la rutina de percusión de 40 h: una fila por brazo.
-- Cualquier PM (rutina o mayor) reinicia el conteo; la meta es último PM + 40 h.
create or replace view v_control_40 as
with plan as (
  select * from planes_mp where clave = 'RUTINA-40'
),
comp as (
  select c.id, c.tipo_horometro, c.nombre, c.sistema, c.cod_sap,
         e.cod_interno, e.modelo
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
            then 'Sin rutina 40 h registrada: el conteo parte del último MP mayor.' else '' end as observacion
from calc4 c;
