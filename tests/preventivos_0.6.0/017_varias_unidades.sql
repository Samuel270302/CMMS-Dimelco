-- Un capturador o invitado puede ver y capturar en varias unidades.
-- perfiles.unidades guarda la lista; perfiles.unidad_id queda como la primera de la lista
-- (orden de la tabla unidades) para las versiones anteriores de la app.

alter table perfiles add column if not exists unidades uuid[] not null default '{}';

update perfiles set unidades = array[unidad_id]
where unidad_id is not null and cardinality(unidades) = 0;

-- Mantiene la lista limpia (sin repetidos ni unidades inexistentes, en el orden de la tabla
-- unidades) y unidad_id igual a la primera. Si una versión anterior de la app cambia solo
-- unidad_id, la lista pasa a ser esa unidad.
create or replace function sincronizar_unidades_perfil()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if cardinality(new.unidades) = 0 and new.unidad_id is not null then
      new.unidades := array[new.unidad_id];
    end if;
  elsif new.unidad_id is distinct from old.unidad_id and new.unidades = old.unidades then
    new.unidades := case when new.unidad_id is null then '{}'::uuid[] else array[new.unidad_id] end;
  end if;
  if new.rol = 'admin' then
    new.unidades := '{}';
  else
    new.unidades := coalesce(
      (select array_agg(u.id order by u.orden) from unidades u where u.id = any(new.unidades)), '{}');
  end if;
  new.unidad_id := new.unidades[1];
  return new;
end $$;

drop trigger if exists sincronizar_unidades_perfil on perfiles;
create trigger sincronizar_unidades_perfil
  before insert or update on perfiles
  for each row execute function sincronizar_unidades_perfil();

alter table perfiles drop constraint if exists perfiles_unidad_requerida;
alter table perfiles add constraint perfiles_unidad_requerida
  check (rol = 'admin' or not activo or cardinality(unidades) > 0);

-- Acceso: el admin ve todo; el resto, las unidades de su lista.
create or replace function unidad_permitida(p_unidad uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(rol_actual() = 'admin', false)
      or (p_unidad is not null and exists (
            select 1 from perfiles
            where user_id = auth.uid() and activo and p_unidad = any(unidades)))
$$;
