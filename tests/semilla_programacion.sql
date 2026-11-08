-- Datos para programar en el tablero (después de semilla_e2e.sql y semilla_e2e_preventivo.sql):
-- tres backlogs más en Listo para programar, capacidad de Mecánico y HH estándar por gama.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a"}', false);
insert into backlog_hh (backlog_id, especialidad_id, tipo, personas, horas)
select '30000000-0000-0000-0000-000000000005', id, 'estimada', 1, 3 from especialidades where nombre = 'Mecánico';
select cambiar_estado_backlog(v.id::uuid, 'En planificación')
from (values ('30000000-0000-0000-0000-000000000002'), ('30000000-0000-0000-0000-000000000003'),
             ('30000000-0000-0000-0000-000000000005')) v(id);
select cambiar_estado_backlog(v.id::uuid, 'Listo para programar')
from (values ('30000000-0000-0000-0000-000000000002'), ('30000000-0000-0000-0000-000000000003'),
             ('30000000-0000-0000-0000-000000000005')) v(id);
select set_config('request.jwt.claims', '', false);

insert into capacidad_taller (unidad_id, especialidad_id, hh_semana, vigente_desde)
select u.id, e.id, 40, current_date - 30 from unidades u, especialidades e
where u.sigla = 'HEM' and e.nombre = 'Mecánico'
on conflict do nothing;
insert into capacidad_taller (unidad_id, especialidad_id, hh_semana, vigente_desde)
select u.id, e.id, 24, current_date - 30 from unidades u, especialidades e
where u.sigla = 'VTN' and e.nombre = 'Mecánico'
on conflict do nothing;

insert into pautas_gama (plan_clave, gama, especialidad_id, hh)
select v.plan, v.gama, e.id, v.hh
from (values ('DIESEL-HEM', null::numeric, 'Mecánico', 6), ('DIESEL-HEM', null, 'Eléctrico', 1),
             ('DIESEL-HEM', 1000, 'Mecánico', 12), ('DIESEL-HEM', 1000, 'Eléctrico', 2),
             ('PERC-HEM', null, 'Mecánico', 4), ('RUTINA-40', null, 'Mecánico', 1)) v(plan, gama, esp, hh)
join especialidades e on e.nombre = v.esp
on conflict do nothing;
