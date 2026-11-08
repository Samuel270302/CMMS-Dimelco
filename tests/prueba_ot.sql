-- Prueba de las órdenes de trabajo del tablero (020) con el rol y el usuario de la sesión.
create or replace function pg_temp.espera_error(p_sql text, p_patron text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'Se esperaba error «%» y no lo hubo: %', p_patron, p_sql;
exception when others then
  if sqlerrm like 'Se esperaba error%' then raise; end if;
  if sqlerrm !~* p_patron then raise exception 'Error distinto: «%» (se esperaba «%»)', sqlerrm, p_patron; end if;
end $$;
create or replace function pg_temp.comp(p_cod text, p_tipo text) returns uuid language sql as $$
  select c.id from componentes c join equipos e on e.id = c.equipo_id where e.cod_interno = p_cod and c.tipo_horometro = p_tipo $$;

-- Id de un componente de HEMCO, tomado antes de entrar con un usuario (que no lo ve si es de otra unidad).
select set_config('prueba.ju005', pg_temp.comp('JU005', 'Diesel')::text, false);
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000c"}', false);
do $$
declare o1 ordenes_trabajo; o2 ordenes_trabajo; o3 ordenes_trabajo; n int; b backlogs; v numeric; g text;
begin
  -- 1. PM de PS011 con la gama siguiente de Control PM y las HH de la pauta.
  select proxima_gama into g from v_control_pm where componente_id = pg_temp.comp('PS011', 'Diesel');
  o1 := programar_pm(pg_temp.comp('PS011', 'Diesel'), 'Preventiva', current_date + 2, 'Dia');
  if o1.folio <> 'OT-HEM-000001' or o1.gama::text <> g then raise exception 'OT de PM: % gama % (Control PM %)', o1.folio, o1.gama, g; end if;
  select hh_total into v from v_ot where id = o1.id;
  if v <> 7 then raise exception 'HH del PM: % (esperado 7)', v; end if;
  perform pg_temp.espera_error(format('select programar_pm(%L, ''Preventiva'', current_date + 3, ''Dia'')', pg_temp.comp('PS011', 'Diesel')), 'ya tiene una OT');
  perform pg_temp.espera_error(format('select programar_pm(%L, ''Preventiva'', current_date - 1, ''Dia'')', pg_temp.comp('JU005', 'Diesel')), 'pasada');

  -- 2. Backlog de otro equipo no entra en la OT de PS011.
  perform pg_temp.espera_error(format('select programar_backlog(''30000000-0000-0000-0000-000000000002'', null, null, %L)', o1.id), 'otro equipo');

  -- 3. Backlog listo -> OT correctiva nueva; queda Programado con el folio como N° de OT.
  o2 := programar_backlog('30000000-0000-0000-0000-000000000003', current_date + 2, 'Noche');
  select * into b from backlogs where id = '30000000-0000-0000-0000-000000000003';
  if o2.tipo <> 'Correctiva' or b.estado <> 'Programado' or b.ot_sap <> o2.folio or b.fecha_programada <> current_date + 2 then
    raise exception 'Correctiva: % % % %', o2.tipo, b.estado, b.ot_sap, b.fecha_programada;
  end if;

  -- 4. Rutina 40 h de JU005 y el backlog programado desde el Calendario (sin OT) se agrupa en ella.
  o3 := programar_pm(pg_temp.comp('JU005', 'Percusión #1'), 'Rutina 40 h', current_date + 3, 'Noche');
  perform programar_backlog('30000000-0000-0000-0000-000000000004', null, null, o3.id);
  select * into b from backlogs where id = '30000000-0000-0000-0000-000000000004';
  if b.fecha_programada <> current_date + 3 or b.ot_sap <> '4001190' then
    raise exception 'Agrupar en rutina: fecha % OT %', b.fecha_programada, b.ot_sap;
  end if;
  select hh_total into v from v_ot where id = o3.id;
  if v <> 9 then raise exception 'HH de rutina + backlog: % (esperado 1 + 8)', v; end if;
  perform pg_temp.espera_error('select programar_backlog(''30000000-0000-0000-0000-000000000004'', current_date + 5, ''Dia'')', 'ya está en una OT');

  -- 5. Mover de día pide motivo y arrastra al backlog; cambiar solo el turno, no.
  perform pg_temp.espera_error(format('select mover_ot(%L, current_date + 4, ''Dia'')', o3.id), 'motivo');
  o3 := mover_ot(o3.id, current_date + 4, 'Dia', 'Equipo en producción');
  select * into b from backlogs where id = '30000000-0000-0000-0000-000000000004';
  if o3.reprogramaciones <> 1 or b.fecha_programada <> current_date + 4 then raise exception 'Mover: % %', o3.reprogramaciones, b.fecha_programada; end if;
  o3 := mover_ot(o3.id, current_date + 4, 'Noche');
  if o3.reprogramaciones <> 1 or o3.turno <> 'Noche' then raise exception 'Cambio de turno contó reprogramación'; end if;
  -- La rutina quedó después de su fecha estimada: el tablero lo avisa.
  select count(*) into n from v_ot where id = o3.id and avisos like 'PM después de su fecha estimada%';
  if n <> 1 then raise exception 'Falta el aviso de PM atrasado: «%»', (select avisos from v_ot where id = o3.id); end if;

  -- 6. Quitar el único backlog de una correctiva la anula y el backlog vuelve a Listo.
  perform quitar_backlog_ot('30000000-0000-0000-0000-000000000003', 'Falta el técnico eléctrico');
  select * into b from backlogs where id = '30000000-0000-0000-0000-000000000003';
  select * into o2 from ordenes_trabajo where id = o2.id;
  if b.estado <> 'Listo para programar' or o2.estado <> 'Anulada' then raise exception 'Quitar: % %', b.estado, o2.estado; end if;

  -- 7. Anular la rutina devuelve su backlog a Listo para programar.
  perform anular_ot(o3.id, 'Se adelanta la parada');
  select * into b from backlogs where id = '30000000-0000-0000-0000-000000000004';
  if b.estado <> 'Listo para programar' then raise exception 'Anular: backlog %', b.estado; end if;
  select count(*) into n from ot_eventos where ot_id = o3.id;
  if n < 4 then raise exception 'Bitácora de la rutina con % eventos', n; end if;

  -- 8. La app no escribe las tablas directo.
  perform pg_temp.espera_error(format('insert into ordenes_trabajo (folio, unidad_id, equipo_id, tipo, titulo, fecha, turno) select ''X'', unidad_id, id, ''Correctiva'', ''x'', current_date, ''Dia'' from equipos limit 1'), 'row-level security|permission denied');
end $$;

-- 9. El capturador de Veta Nueva no programa en HEMCO, sí en su unidad, y no ve las OT de HEMCO.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000d"}', false);
do $$
declare o ordenes_trabajo; n int;
begin
  perform pg_temp.espera_error(format('select programar_pm(%L, ''Preventiva'', current_date + 2, ''Dia'')', current_setting('prueba.ju005')), 'Sin permiso');
  o := programar_backlog('30000000-0000-0000-0000-000000000005', current_date + 1, 'Dia');
  if o.folio <> 'OT-VTN-000001' then raise exception 'Folio de Veta Nueva: %', o.folio; end if;
  select count(*) into n from v_ot where unidad <> 'Veta Nueva';
  if n > 0 then raise exception 'Veta Nueva ve % OT de otra unidad', n; end if;
end $$;
reset role;
select 'PRUEBA OT OK' as resultado;
