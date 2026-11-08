-- Rol invitado: solo consulta. Las políticas de lectura ya admiten cualquier
-- perfil activo; las de captura y administración exigen admin o capturador,
-- así que el invitado queda bloqueado para escribir desde la propia base.
alter table perfiles drop constraint if exists perfiles_rol_check;
alter table perfiles add constraint perfiles_rol_check
  check (rol in ('admin', 'capturador', 'invitado'));
