-- Permiso para que la app consulte el control de lecturas mientras se escribe (solo en Supabase).
revoke execute on function validar_lectura(uuid, date, text, numeric, uuid) from public, anon;
grant execute on function validar_lectura(uuid, date, text, numeric, uuid) to authenticated;
