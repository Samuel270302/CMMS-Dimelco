-- Datos de preventivo para la prueba de navegador del CMMS (después de semilla_e2e.sql).
-- Usa los equipos de backlog: PS011 y JU005 de HEMCO, PS090 de Veta Nueva. 30 días de
-- lecturas por turno hasta ayer y un PM por componente.
insert into planes_mp (clave, sistema, componente_desc, intervalo_h, ciclo_gamas, dias_programar, dias_verificar, orden) values
  ('DIESEL-HEM', 'Motor Diésel', 'Motor diésel', 250, '{250,500,250,1000}', 10, 28, 1),
  ('PERC-HEM', 'Perforadora', 'Perforadora COP', 250, '{250,500}', 7, 14, 2),
  ('RUTINA-40', 'Perforadora', 'Rutina de percusión', 40, '{40}', 3, 5, 3)
on conflict (clave) do nothing;

insert into componentes (equipo_id, tipo_horometro, nombre, sistema, seccion, cod_sap, plan_clave, aplica_rutina40)
select e.id, v.tipo, v.nombre, v.sistema, v.seccion, e.cod_sap, v.plan, v.r40
from (values ('PS011', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-HEM', false),
             ('JU005', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-HEM', false),
             ('JU005', 'Percusión #1', 'Perforadora B1', 'Perforadora', 3, 'PERC-HEM', true),
             ('PS090', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-HEM', false)) v(cod, tipo, nombre, sistema, seccion, plan, r40)
join equipos e on e.cod_interno = v.cod;

insert into lecturas (componente_id, fecha, turno, lectura, origen)
select c.id, current_date - 30 + d, t.turno, v.base + (d * 2 + t.n) * v.tasa, 'import'
from componentes c
join equipos e on e.id = c.equipo_id
join (values ('PS011', 'Diesel', 12000.0, 7.5), ('JU005', 'Diesel', 6000.0, 5.0),
             ('JU005', 'Percusión #1', 900.0, 2.5), ('PS090', 'Diesel', 3000.0, 4.0)) v(cod, tipo, base, tasa)
  on v.cod = e.cod_interno and v.tipo = c.tipo_horometro
cross join generate_series(0, 29) d
cross join (values ('Dia', 0), ('Noche', 1)) t(turno, n);

-- PS011: gama 250 hace 25 días (le faltan pocas horas: queda en Programar o Vencido).
-- JU005 diésel: gama 500 hace 5 días. Perforadora: gama 250 hace 20 días y rutina 40 h hace 4.
-- PS090: gama 1000 hace 10 días.
insert into registros_pm (componente_id, fecha, gama, lectura, responsable)
select c.id, l.fecha, v.gama, l.lectura, 'Taller'
from (values ('PS011', 'Diesel', 25, 250), ('JU005', 'Diesel', 5, 500),
             ('JU005', 'Percusión #1', 20, 250), ('JU005', 'Percusión #1', 4, 40),
             ('PS090', 'Diesel', 10, 1000)) v(cod, tipo, dias, gama)
join equipos e on e.cod_interno = v.cod
join componentes c on c.equipo_id = e.id and c.tipo_horometro = v.tipo
join lecturas l on l.componente_id = c.id and l.fecha = current_date - v.dias and l.turno = 'Dia';
