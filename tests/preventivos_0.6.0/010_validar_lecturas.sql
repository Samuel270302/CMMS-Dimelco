-- F11 · Control de lecturas de horómetro en la base, en horas acumuladas.
--
-- Una lectura se rechaza (error) cuando:
--   1. Ya existe una lectura del mismo componente, fecha y turno.
--   2. Es más de 2 h menor que la anterior en acumulado. Si el horómetro se cambió
--      o reinició, primero se registra el cambio (offset) y la lectura pasa sola.
--   3. Suma más horas que las posibles en los turnos transcurridos.
--   4. Es mayor que una lectura posterior ya registrada (carga atrasada) o deja
--      horas imposibles hasta ella.
-- Se acepta con aviso: primer registro, baja de hasta 2 h (posible digitación) y
-- hueco de más de 7 días sin lectura.

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

  -- Lectura anterior
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

  -- Lectura posterior (cuando se carga una lectura atrasada)
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

-- La vista calcula las horas entre lecturas en acumulado cuando entre ambas hay
-- un cambio de horómetro registrado (cambia el offset vigente); en el resto de los
-- casos conserva la regla del libro sobre el contador.
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

-- create or replace view reinicia las opciones de la vista: sin esto v_lecturas
-- deja de aplicar las políticas de lecturas (quedó así en producción hasta el 03/11/2026).
alter view v_lecturas set (security_invoker = true);
