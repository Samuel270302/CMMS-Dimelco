# Fusión de datos: preventivos a la base del CMMS

Procedimiento para traer los datos de Control de Preventivos al proyecto Supabase de backlog, que es la base del CMMS. No se ejecuta sin la aprobación del dueño: hay usuarios cargando información en las dos apps.

Nada de esto corre solo. Los dos flujos de GitHub Actions que tocan producción se lanzan a mano y piden escribir una palabra de confirmación.

## Antes del día de la fusión

1. En el repositorio CMMS-Dimelco, Settings > Secrets and variables > Actions, crear dos secretos:
   - `SUPABASE_DB_URL`: cadena de conexión del proyecto de backlog (la misma que tiene el repositorio Backlog-Dimelco; pooler en modo sesión, puerto 5432).
   - `DSN_PREVENTIVOS`: cadena de conexión del proyecto de preventivos (la misma `SUPABASE_DB_URL` del repositorio Control-de-preventivos-Dimelco).
2. Actions > "Actualizar base de datos" > Run workflow, escribir `APLICAR`. Aplica `supabase/instalar_todo.sql`: las migraciones 001 a 018 ya están en la base de backlog y se saltan; la 019 agrega las tablas y vistas de preventivos y la 020 las de órdenes de trabajo, vacías. La app de backlog sigue funcionando igual. Al final muestra la verificación; el punto "Preventivo por horómetros (019)" tiene que salir OK.
3. Actions > "Traer datos de preventivos" > Run workflow, modo `ensayo`. Hace la copia completa y la verificación dentro de una transacción y la deshace: ninguna base cambia. Revisar en el registro:
   - conteos origen / destino de cada tabla, todos iguales;
   - vistas de cálculo con todas las filas iguales;
   - avisos: equipos que solo existían en preventivos (se crean sin familia), usuarios con perfiles distintos en las dos apps, equipos con cód. SAP o modelo distinto.
   Si un equipo aparece como creado pero en backlog existe con otro código (por ejemplo "Scooptram #1" contra "PS001"), corregir el código en una de las dos apps y repetir el ensayo.

## Día de la fusión

1. Avisar a los capturadores de preventivos que no graben durante la ventana.
2. Correr a mano "Mantenimiento de la base" en Backlog-Dimelco y en Control-de-preventivos-Dimelco, para tener un respaldo cifrado de las dos bases del mismo momento.
3. "Traer datos de preventivos" en modo `ensayo` otra vez, con los datos del momento.
4. "Traer datos de preventivos" en modo `grabar`, escribir `GRABAR`. Confirma solo si la verificación sale sin diferencias; si hay una, no graba nada y muestra cuál.
5. En el SQL Editor del proyecto de preventivos, dejar a todos inactivos para que ningún PC con la conexión vieja siga grabando ahí:

       update perfiles set activo = false;

6. Publicar en el proyecto de backlog la Edge Function `admin-usuarios` de preventivos (`supabase/functions/admin-usuarios` del repositorio Control-de-preventivos-Dimelco), que acepta la lista de unidades de la app 0.6.0 y el `unidad_id` de las versiones anteriores.
7. Control de Preventivos en cada PC: en la pantalla de configuración, URL y llave anon del proyecto de backlog. En la web: en `.github/workflows/web.yml` de Control-de-preventivos-Dimelco, cambiar `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` por las del proyecto de backlog (las mismas que usa el sitio de Backlog-Dimelco); al subir el cambio a main el sitio se vuelve a publicar.
8. Entrar con un capturador de cada unidad a Control de Preventivos, Control de Backlog y CMMS y revisar Control PM, Lecturas y Kanban.

## Después

- Asignar familia en Equipos a los equipos que solo existían en preventivos.
- El proyecto de preventivos queda sin uso 30 días como respaldo y después se pausa.
- En Control-de-preventivos-Dimelco, el secreto `SUPABASE_DB_URL` pasa a la cadena del proyecto de backlog, para que su reporte semanal lea los datos nuevos; o se apaga ese reporte cuando el CMMS tenga el suyo.

## Qué copia la herramienta

`tools/traer_preventivos.mjs` (el flujo la llama con los secretos):

| Dato | Cómo |
|---|---|
| Unidades | se cruzan por nombre; no se crean |
| Usuarios | los que no están en backlog se copian con su cuenta (`auth.users` y `auth.identities`, misma contraseña) y su perfil; los que ya están conservan el perfil de backlog |
| Parámetros | las seis claves del control de horómetros, con los valores de preventivos |
| Equipos | por unidad + código; los que ya existen conservan los datos de backlog y se completa la fecha de inicio de operación; los demás se crean |
| Planes MP, componentes, lecturas, registros PM, cambios de horómetro, registros manuales | con los mismos id; las lecturas y PM anulados también, con quién y cuándo |
| Columnas visibles de Control PM | se copia la configuración del admin |

La copia se hace una sola vez: si el destino ya tiene componentes, lecturas o registros PM, se detiene sin tocar nada.

## Ensayo local

`tests/ensayo_traer_preventivos.sh` arma dos PostgreSQL locales (uno con el esquema de preventivos 0.6.0 y datos de prueba, otro con el del CMMS y datos de backlog), corre la herramienta en ensayo y en grabar, y comprueba que los datos de backlog no cambian, que una segunda copia se rechaza, que `instalar_todo.sql` se puede repetir y que un capturador de Veta Nueva no ve ni graba en HEMCO. Corre en cada push (flujo "Pruebas").
