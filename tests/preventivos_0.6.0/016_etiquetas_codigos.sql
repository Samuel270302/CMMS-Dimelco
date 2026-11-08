-- Nombres de los códigos en pantalla: el código del equipo (cod_interno) se muestra como
-- "Cód. equipo" y el código SAP (cod_sap) como "Cód. interno". Las columnas de la base no cambian.
update columnas_control set etiqueta = 'Cód. interno' where columna = 'cod_sap';
