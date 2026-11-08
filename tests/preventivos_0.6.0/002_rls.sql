-- Seguridad por rol (solo se aplica en Supabase: requiere el esquema auth).
-- Roles: admin (todo) y capturador (captura lecturas, PM y cambios de horómetro).
-- Nada se borra físico desde la app: las anulaciones son updates con motivo.

create or replace function rol_actual() returns text
language sql stable security definer set search_path = public as $$
  select rol from perfiles where user_id = auth.uid() and activo
$$;

-- Perfil automático al crear un usuario en Authentication → Users.
create or replace function crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (user_id, nombre, correo, rol)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
          new.email, 'capturador')
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario after insert on auth.users
  for each row execute function crear_perfil();

alter table lecturas alter column creado_por set default auth.uid();
alter table registros_pm alter column creado_por set default auth.uid();
alter table cambios_horometro alter column creado_por set default auth.uid();
alter table registros_manuales alter column creado_por set default auth.uid();
alter table equipos alter column creado_por set default auth.uid();

-- Las vistas deben respetar las políticas de las tablas base.
alter view v_lecturas set (security_invoker = true);
alter view v_registros_pm set (security_invoker = true);
alter view v_control_pm set (security_invoker = true);
alter view v_control_40 set (security_invoker = true);

alter table parametros enable row level security;
alter table perfiles enable row level security;
alter table planes_mp enable row level security;
alter table equipos enable row level security;
alter table componentes enable row level security;
alter table lecturas enable row level security;
alter table registros_pm enable row level security;
alter table cambios_horometro enable row level security;
alter table registros_manuales enable row level security;

-- Lectura: cualquier usuario activo.
do $$
declare t text;
begin
  foreach t in array array['parametros','perfiles','planes_mp','equipos','componentes',
                           'lecturas','registros_pm','cambios_horometro','registros_manuales'] loop
    execute format('drop policy if exists leer_%I on %I', t, t);
    execute format(
      'create policy leer_%I on %I for select to authenticated using (rol_actual() is not null)',
      t, t);
  end loop;
end $$;

-- Captura: admin y capturador insertan lecturas, PM, cambios y registros manuales.
do $$
declare t text;
begin
  foreach t in array array['lecturas','registros_pm','cambios_horometro','registros_manuales'] loop
    execute format('drop policy if exists capturar_%I on %I', t, t);
    execute format(
      'create policy capturar_%I on %I for insert to authenticated
       with check (rol_actual() in (''admin'',''capturador''))', t, t);
  end loop;
end $$;

-- Cambios posteriores (anular, validar, editar) y administración: solo admin.
do $$
declare t text;
begin
  foreach t in array array['parametros','planes_mp','equipos','componentes',
                           'lecturas','registros_pm','cambios_horometro','registros_manuales'] loop
    execute format('drop policy if exists administrar_%I on %I', t, t);
    execute format(
      'create policy administrar_%I on %I for all to authenticated
       using (rol_actual() = ''admin'') with check (rol_actual() = ''admin'')', t, t);
  end loop;
end $$;

drop policy if exists administrar_perfiles on perfiles;
create policy administrar_perfiles on perfiles for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');
