-- Permiso para que la app consulte el control mientras se escribe (solo en Supabase).
revoke execute on function validar_registro_pm(uuid, date, numeric, uuid) from public, anon;
grant execute on function validar_registro_pm(uuid, date, numeric, uuid) to authenticated;
