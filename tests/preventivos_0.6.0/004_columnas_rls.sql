-- Seguridad y tiempo real de columnas_control (solo en Supabase).
alter table columnas_control enable row level security;

drop policy if exists leer_columnas_control on columnas_control;
create policy leer_columnas_control on columnas_control
  for select to authenticated using (rol_actual() is not null);

drop policy if exists administrar_columnas_control on columnas_control;
create policy administrar_columnas_control on columnas_control
  for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

alter publication supabase_realtime add table columnas_control;
