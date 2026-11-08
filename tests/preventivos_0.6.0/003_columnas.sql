-- Columnas visibles de los tableros de control, configuradas por el administrador.
-- La configuración es global: todos los usuarios ven las mismas columnas.
-- Equipo y Componente siempre se muestran y no están en esta tabla.

create table if not exists columnas_control (
  columna  text primary key,
  etiqueta text not null,
  visible  boolean not null default true,
  orden    integer not null
);

insert into columnas_control (columna, etiqueta, visible, orden) values
  ('cod_sap',                 'Cód. SAP',                 true, 1),
  ('modelo',                  'Modelo',                   false, 2),
  ('fecha_ultimo_pm',         'Fecha último PM',          true, 3),
  ('gama_ultimo_pm',          'Gama último PM',           true, 4),
  ('horometro_ultimo_pm',     'Horómetro último PM',      true, 5),
  ('proxima_gama',            'Próxima gama',             true, 6),
  ('meta_acum',               'Meta (acum.)',             true, 7),
  ('meta_contador',           'Meta (contador)',          true, 8),
  ('ultima_lectura_acum',     'Última lectura (acum.)',   true, 9),
  ('ultima_lectura_contador', 'Última lectura (contador)', true, 10),
  ('fecha_ultima_lectura',    'Fecha última lectura',     true, 11),
  ('hrs_faltantes',           'Hrs faltantes',            true, 12),
  ('tendencia',               'Tendencia (h/día)',        true, 13),
  ('dias_restantes',          'Días restantes',           true, 14),
  ('fecha_estimada',          'Fecha estimada',           true, 15),
  ('estado',                  'Estado',                   true, 16),
  ('observacion',             'Observación',              true, 17)
on conflict (columna) do nothing;

-- El Scooptram #4 deja de ser caso especial: captura la lectura del contador
-- como el resto. El historial manual queda guardado como referencia.
update componentes set lectura_manual = false where lectura_manual;
