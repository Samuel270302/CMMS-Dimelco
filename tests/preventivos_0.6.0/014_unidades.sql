-- 0.5.0 · Unidades mineras: HEMCO, Veta Nueva, Mina La India y Explotec.
-- Cada equipo pertenece a una unidad; cada perfil que no es admin tiene una unidad.
-- Las políticas por unidad están en 015_unidades_rls.sql (solo Supabase).

create table if not exists unidades (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  activo  boolean not null default true,
  orden   integer not null default 0
);
insert into unidades (nombre, orden) values
  ('HEMCO', 1), ('Veta Nueva', 2), ('Mina La India', 3), ('Explotec', 4)
on conflict (nombre) do nothing;

alter table equipos add column if not exists unidad_id uuid references unidades(id);
update equipos set unidad_id = (select id from unidades where nombre = 'HEMCO') where unidad_id is null;
alter table equipos alter column unidad_id set not null;
create index if not exists equipos_unidad on equipos (unidad_id);
-- Otra mina puede tener su propio "Scooptram #1": el código es único dentro de la unidad.
alter table equipos drop constraint if exists equipos_cod_interno_key;
alter table equipos drop constraint if exists equipos_unidad_cod_interno_key;
alter table equipos add constraint equipos_unidad_cod_interno_key unique (unidad_id, cod_interno);

alter table perfiles add column if not exists unidad_id uuid references unidades(id);
update perfiles set unidad_id = (select id from unidades where nombre = 'HEMCO')
  where unidad_id is null and rol <> 'admin';
-- Un perfil activo que no es admin siempre tiene unidad. Los perfiles nuevos nacen
-- inactivos y sin unidad; el admin la asigna al activarlos.
alter table perfiles drop constraint if exists perfiles_unidad_requerida;
alter table perfiles add constraint perfiles_unidad_requerida
  check (rol = 'admin' or not activo or unidad_id is not null);

-- Última lectura de cada componente (reemplaza la carga de las 1.500 lecturas más
-- recientes en Lecturas y Registro PM).
create or replace view v_ultima_lectura as
select distinct on (l.componente_id)
       l.componente_id, l.fecha, l.turno, l.lectura, l.lectura_acum, l.num_turno
from v_lecturas l
order by l.componente_id, l.num_turno desc;

-- Vistas de control con la unidad al final (create or replace solo admite columnas nuevas al final).
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
       ) as observacion,
       c.unidad_id, un.nombre as unidad
from calc4 c
left join unidades un on un.id = c.unidad_id;

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

-- create or replace view reinicia las opciones: se vuelven a fijar.
alter view v_control_pm set (security_invoker = true);
alter view v_control_40 set (security_invoker = true);
alter view v_cumplimiento_pm set (security_invoker = true);
alter view v_utilizacion_mensual set (security_invoker = true);
alter view v_ultima_lectura set (security_invoker = true);
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on unidades, v_ultima_lectura to authenticated;
  end if;
end $$;
