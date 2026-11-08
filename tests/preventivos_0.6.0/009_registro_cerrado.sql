-- Todo perfil nuevo nace inactivo y como invitado: no ve ni graba nada hasta que
-- un administrador lo active y le asigne rol desde la pantalla Usuarios.
-- (El registro abierto de cuentas se cierra además en la configuración de Supabase.)
create or replace function crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (user_id, nombre, correo, rol, activo)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
          new.email, 'invitado', false)
  on conflict (user_id) do nothing;
  return new;
end $$;

-- Cada usuario puede leer su propio perfil aunque esté inactivo, para que la app
-- le muestre que su acceso está pendiente de activación.
drop policy if exists leer_propio_perfil on perfiles;
create policy leer_propio_perfil on perfiles for select to authenticated
  using (user_id = auth.uid());

-- Borrar una cuenta en Authentication borra también su perfil.
delete from perfiles p where not exists (select 1 from auth.users u where u.id = p.user_id);
alter table perfiles drop constraint if exists perfiles_user_id_fkey;
alter table perfiles add constraint perfiles_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete cascade;
