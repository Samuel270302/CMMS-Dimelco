-- F8 · Auditoría de anulaciones: quién anuló y cuándo.
-- La base llena anulado_por y anulado_en al anular; la app no los manda.
-- El usuario sale del token de la sesión (lo mismo que hace auth.uid()), así la
-- función también corre en la base local, que no tiene el esquema auth.

alter table lecturas add column if not exists anulado_por uuid;
alter table lecturas add column if not exists anulado_en timestamptz;
alter table registros_pm add column if not exists anulado_por uuid;
alter table registros_pm add column if not exists anulado_en timestamptz;

create or replace function usuario_sesion() returns uuid
language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid
$$;

create or replace function tg_auditar_anulacion() returns trigger
language plpgsql as $$
declare
  -- lecturas usa "anulada" y registros_pm "anulado"
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
