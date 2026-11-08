-- Control de lecturas en registros PM.
-- Todo se compara en horas acumuladas (contador + offset vigente), así un reinicio
-- de horómetro ya registrado en cambios_horometro no se confunde con una lectura menor.
--
-- Bloquea:
--   1. Lectura menor al PM anterior del mismo componente.
--   2. Más horas desde el PM anterior de las posibles en los días transcurridos.
--   3. Lectura mayor a un PM posterior (registro cargado con fecha atrasada).
--   4. Lectura menor a la última lectura de horómetro de un día anterior
--      (con la misma tolerancia de digitación que usan las lecturas).
--   5. Más horas desde esa lectura de las posibles en los días transcurridos.
--   6. Lectura mayor a la primera lectura de horómetro de un día posterior.
-- Horas posibles por día = 2 turnos × max_horas_turno; se suma un día de holgura
-- porque el PM y la lectura pueden caer en extremos opuestos del día.

create or replace function validar_registro_pm(
  p_componente uuid,
  p_fecha date,
  p_lectura numeric,
  p_excluir uuid default null
) returns text
language plpgsql stable as $$
declare
  v_acum   numeric;
  v_max_dia numeric := 2 * param('max_horas_turno');
  v_tol    numeric := param('umbral_cambio_horometro');
  v_fecha  date;
  v_ref    numeric;
  v_dias   integer;
begin
  if p_componente is null or p_fecha is null or p_lectura is null then
    return null;
  end if;
  v_acum := p_lectura + offset_vigente(p_componente, p_fecha);

  -- 1 y 2: PM anterior (incluye el mismo día)
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

  -- 3: PM posterior
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

  -- 4 y 5: última lectura de horómetro de un día anterior
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

  -- 6: primera lectura de horómetro de un día posterior
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
  -- Anular nunca se bloquea; una edición solo se revisa si cambia lo que se valida.
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
