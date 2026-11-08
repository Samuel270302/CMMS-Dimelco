-- La columna Componente también se puede ocultar; solo Equipo queda fija.
insert into columnas_control (columna, etiqueta, visible, orden)
values ('nombre', 'Componente', true, 0)
on conflict (columna) do nothing;
