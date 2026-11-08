-- 0.5.0 · Seguridad por unidad (solo Supabase: usa auth.uid()).
-- El admin ve y graba en todas las unidades. Capturador e invitado, solo en la suya.

create or replace function unidad_actual() returns uuid
language sql stable security definer set search_path = public as $$
  select unidad_id from perfiles where user_id = auth.uid() and activo
$$;

create or replace function unidad_permitida(p_unidad uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(rol_actual() = 'admin', false)
      or (p_unidad is not null and p_unidad = unidad_actual())
$$;

create or replace function unidad_de_equipo(p_equipo uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select unidad_id from equipos where id = p_equipo
$$;

create or replace function unidad_de_componente(p_componente uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select e.unidad_id from componentes c join equipos e on e.id = c.equipo_id where c.id = p_componente
$$;

revoke execute on function unidad_actual(), unidad_permitida(uuid), unidad_de_equipo(uuid),
  unidad_de_componente(uuid) from public, anon;
grant execute on function unidad_actual(), unidad_permitida(uuid), unidad_de_equipo(uuid),
  unidad_de_componente(uuid) to authenticated;

-- Unidades: las leen todos los usuarios activos; las administra el admin.
alter table unidades enable row level security;
drop policy if exists leer_unidades on unidades;
create policy leer_unidades on unidades for select to authenticated using (rol_actual() is not null);
drop policy if exists administrar_unidades on unidades;
create policy administrar_unidades on unidades for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

-- Lectura por unidad (reemplaza las políticas leer_* de 002_rls.sql).
drop policy if exists leer_equipos on equipos;
create policy leer_equipos on equipos for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_id));

drop policy if exists leer_componentes on componentes;
create policy leer_componentes on componentes for select to authenticated
  using (rol_actual() is not null and unidad_permitida(unidad_de_equipo(equipo_id)));

do $$
declare t text;
begin
  foreach t in array array['lecturas','registros_pm','cambios_horometro','registros_manuales'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format(
      'create policy leer_%I on %I for select to authenticated
       using (rol_actual() is not null and unidad_permitida(unidad_de_componente(componente_id)))', t, t);
    execute format('drop policy if exists capturar_%I on %I', t, t);
    execute format(
      'create policy capturar_%I on %I for insert to authenticated
       with check (rol_actual() in (''admin'',''capturador'')
                   and unidad_permitida(unidad_de_componente(componente_id)))', t, t);
  end loop;
end $$;
