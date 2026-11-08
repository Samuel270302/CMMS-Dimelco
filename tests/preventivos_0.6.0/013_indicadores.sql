-- F4 · Indicadores de gestión.

-- Cumplimiento: cada PM mayor contra la meta que tenía al ejecutarse.
-- Meta = acumulado del PM mayor anterior (o la base sin PM, si es el primero)
-- + intervalo del plan, igual que el Control PM. Varios registros del mismo día
-- cuentan como un PM. horas_atraso > 0 significa que se ejecutó después de la meta.
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
  select s.*, c.sistema, c.seccion, c.nombre, c.tipo_horometro, e.id as equipo_id, e.cod_interno,
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
            else m.lectura_acum <= m.meta_acum end as a_tiempo
from meta m;

-- Utilización: horas por día de cada componente por mes, con las horas de cada
-- intervalo entre lecturas asignadas al mes de la lectura que lo cierra.
create or replace view v_utilizacion_mensual as
select l.componente_id, c.equipo_id, e.cod_interno, c.nombre, c.tipo_horometro, c.seccion,
       date_trunc('month', l.fecha)::date as mes,
       sum(l.horas_intervalo) as horas,
       sum(l.turnos_transcurridos) / 2.0 as dias,
       round(sum(l.horas_intervalo) / nullif(sum(l.turnos_transcurridos) / 2.0, 0), 2) as h_dia,
       count(*) as lecturas
from v_lecturas l
join componentes c on c.id = l.componente_id
join equipos e on e.id = c.equipo_id
where l.horas_intervalo is not null and c.activo and e.activo
group by l.componente_id, c.equipo_id, e.cod_interno, c.nombre, c.tipo_horometro, c.seccion,
         date_trunc('month', l.fecha);

alter view v_cumplimiento_pm set (security_invoker = true);
alter view v_utilizacion_mensual set (security_invoker = true);
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on v_cumplimiento_pm, v_utilizacion_mensual to authenticated;
  end if;
end $$;
