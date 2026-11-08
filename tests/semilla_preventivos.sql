-- Datos de prueba para una base de Control de Preventivos 0.6.0 (ensayo de traer_preventivos).
-- Fechas relativas a hoy: 60 días de lecturas por turno, PM, un cambio de horómetro,
-- una lectura y un PM anulados. Equipos que cruzan con la semilla de backlog (PS011 y
-- JU005 de HEMCO) y equipos que solo existen aquí (PS013 de HEMCO y PS012 de Veta Nueva).

-- Usuarios: el admin y el capturador también están en la semilla de backlog (mismo id);
-- el capturador tiene aquí otro rol, para que el ensayo muestre el aviso.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@prueba', '{"nombre":"Ana Admin"}'),
  ('00000000-0000-0000-0000-00000000000c', 'cap@prueba', '{"nombre":"Carlos Capturador"}'),
  ('00000000-0000-0000-0000-00000000000e', 'cap.prev@prueba', '{"nombre":"Pedro Preventivos"}');
update perfiles set rol = 'admin', activo = true where correo = 'admin@prueba';
update perfiles set rol = 'invitado', activo = true, unidades = array[(select id from unidades where nombre = 'HEMCO')]
  where correo = 'cap@prueba';
update perfiles set rol = 'capturador', activo = true, unidades = array[(select id from unidades where nombre = 'Veta Nueva')]
  where correo = 'cap.prev@prueba';

update parametros set valor = 11 where clave = 'max_horas_turno';

insert into planes_mp (clave, sistema, componente_desc, intervalo_h, ciclo_gamas, dias_programar, dias_verificar, base_sin_pm, kits_sap, orden) values
  ('DIESEL-HEM', 'Motor Diésel', 'Motor diésel', 250, '{250,500,250,1000}', 10, 28, null, 'KIT-250 / KIT-500', 1),
  ('PERC-HEM', 'Perforadora', 'Perforadora COP', 250, '{250,500}', 7, 14, null, null, 2),
  ('RUTINA-40', 'Perforadora', 'Rutina de percusión', 40, '{40}', 3, 5, null, null, 3),
  ('DIESEL-VN', 'Motor Diésel', 'Motor diésel (Veta Nueva)', 250, '{250,500,750,1000}', 10, 28, 5000, null, 4);

insert into equipos (cod_interno, cod_sap, modelo, unidad_id, fecha_inicio_operacion, creado_por)
select v.cod, v.sap, v.modelo, u.id, v.inicio::date, '00000000-0000-0000-0000-00000000000a'
from (values ('HEMCO', 'PS011', '10002345', 'ST1030', '2021-03-01'),
             ('HEMCO', 'PS013', '10002347', 'ST1030', '2022-06-15'),
             ('HEMCO', 'JU005', '10002399', 'Boomer S1D', '2020-01-10'),
             ('Veta Nueva', 'PS012', '20001112', 'ST1030', null)) v(unidad, cod, sap, modelo, inicio)
join unidades u on u.nombre = v.unidad;

insert into componentes (equipo_id, tipo_horometro, nombre, sistema, seccion, cod_sap, plan_clave, aplica_rutina40)
select e.id, v.tipo, v.nombre, v.sistema, v.seccion, e.cod_sap, v.plan, v.r40
from (values ('PS011', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-HEM', false),
             ('PS013', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-HEM', false),
             ('JU005', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-HEM', false),
             ('JU005', 'Percusión #1', 'Perforadora B1', 'Perforadora', 3, 'PERC-HEM', true),
             ('PS012', 'Diesel', 'Motor Diésel', 'Motor Diésel', 1, 'DIESEL-VN', false)) v(cod, tipo, nombre, sistema, seccion, plan, r40)
join equipos e on e.cod_interno = v.cod;

-- PS013: el horómetro se cambió el día 40; desde ahí el contador parte de 5 h.
insert into cambios_horometro (componente_id, vigente_desde, offset_h, ultima_lectura_vieja, primera_lectura_nueva, metodo, fuente, estado, creado_por)
select c.id, current_date - 20, 8000 + 80 * 7.5 - 5, '8592.5', '5', 'Diferencia de lecturas', 'Bitácora', 'Validado', '00000000-0000-0000-0000-00000000000a'
from componentes c join equipos e on e.id = c.equipo_id where e.cod_interno = 'PS013';

-- Lecturas: 60 días, dos turnos, horas por turno según el componente.
insert into lecturas (componente_id, fecha, turno, lectura, origen, creado_por)
select c.id, current_date - 60 + d, t.turno,
       case when e.cod_interno = 'PS013' and d >= 40 then 5 + (d * 2 + t.n - 80) * v.tasa
            else v.base + (d * 2 + t.n) * v.tasa end,
       'app', '00000000-0000-0000-0000-00000000000c'
from componentes c
join equipos e on e.id = c.equipo_id
join (values ('PS011', 'Diesel', 12000.0, 7.5), ('PS013', 'Diesel', 8000.0, 7.5),
             ('JU005', 'Diesel', 6000.0, 5.0), ('JU005', 'Percusión #1', 900.0, 2.5),
             ('PS012', 'Diesel', 5100.0, 4.0)) v(cod, tipo, base, tasa)
  on v.cod = e.cod_interno and v.tipo = c.tipo_horometro
cross join generate_series(0, 59) d
cross join (values ('Dia', 0), ('Noche', 1)) t(turno, n)
order by c.id, d, t.n;

-- Una lectura mal digitada y anulada.
insert into lecturas (componente_id, fecha, turno, lectura, origen, anulada, motivo_anulacion, creado_por)
select c.id, current_date - 50, 'Dia', 99999, 'app', true, 'Digitación', '00000000-0000-0000-0000-00000000000c'
from componentes c join equipos e on e.id = c.equipo_id where e.cod_interno = 'PS011';

-- PM: PS011 gama 250 el día 20; JU005 diésel gama 500 el día 5; perforadora gama 250 el
-- día 30 y rutina 40 h el día 55; PS013 gama 1000 el día 10 y gama 250 el día 50.
insert into registros_pm (componente_id, fecha, gama, lectura, responsable, creado_por)
select c.id, current_date - 60 + v.d, v.gama, l.lectura, 'Taller ' || e.cod_interno, '00000000-0000-0000-0000-00000000000c'
from (values ('PS011', 'Diesel', 20, 250), ('JU005', 'Diesel', 5, 500),
             ('JU005', 'Percusión #1', 30, 250), ('JU005', 'Percusión #1', 55, 40),
             ('PS013', 'Diesel', 10, 1000), ('PS013', 'Diesel', 50, 250)) v(cod, tipo, d, gama)
join equipos e on e.cod_interno = v.cod
join componentes c on c.equipo_id = e.id and c.tipo_horometro = v.tipo
join lecturas l on l.componente_id = c.id and l.fecha = current_date - 60 + v.d and l.turno = 'Dia' and not l.anulada
order by v.d;

-- Un PM cargado dos veces y anulado.
insert into registros_pm (componente_id, fecha, gama, lectura, responsable, anulado, motivo_anulacion, creado_por)
select c.id, current_date - 40, 250, l.lectura, 'Taller PS011', true, 'Registrado dos veces', '00000000-0000-0000-0000-00000000000c'
from componentes c join equipos e on e.id = c.equipo_id
join lecturas l on l.componente_id = c.id and l.fecha = current_date - 40 and l.turno = 'Dia'
where e.cod_interno = 'PS011';

insert into registros_manuales (componente_id, fecha, turno, turno_texto, lectura_inicio, lectura_final, creado_por)
select c.id, current_date - 59, 'Dia', 'Día 1', 12000, 12007.5, '00000000-0000-0000-0000-00000000000c'
from componentes c join equipos e on e.id = c.equipo_id where e.cod_interno = 'PS011';

update columnas_control set visible = false where columna = 'meta_contador';
