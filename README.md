# CMMS Dimelco

Aplicación de mantenimiento que junta Control de Preventivos (preventivo por horómetros) y Control de Backlog (trabajos pendientes con HH, repuestos y programación) en una sola app, con un login, un menú y una base. Las órdenes de trabajo y el tablero de programación de preventivos y correctivos vienen en las versiones siguientes (ver `docs/PLAN_CMMS.md`).

Las dos apps actuales siguen funcionando. La base del CMMS es el proyecto Supabase de backlog; los datos de preventivos se traen una sola vez, con aprobación, siguiendo `docs/FUSION.md`. Después de eso las tres apps leen y graban en la misma base.

## Arquitectura

Electron + React + TypeScript para escritorio Windows; el mismo código compila como sitio web (`npm run build:web`). PostgreSQL en Supabase con seguridad por rol (admin, capturador, invitado) y por unidad (HEMCO, Veta Nueva, Mina La India, Explotec).

- Backlog: migraciones 001 a 018, las mismas del repositorio Backlog-Dimelco. Pantallas en `src/pages`.
- Preventivo: migración 019, con el esquema de Control de Preventivos 0.6.0 sobre las tablas de backlog (unidades, perfiles, parámetros y equipos son las mismas). Pantallas en `src/preventivo`.
- Ficha de equipo con pestañas Preventivo y Backlog (`src/pages/FichaEquipoCmms.tsx`).

## Estructura

    supabase/migrations/   001-018 backlog, 019 preventivo
    supabase/instalar_todo.sql   todas las migraciones en un archivo (tools/armar_instalacion.sh)
    src/pages, src/components, src/lib     backlog y partes comunes
    src/preventivo/        pantallas, consultas y componentes de preventivo
    tools/traer_preventivos.mjs    copia de datos de preventivos a la base del CMMS
    tests/                 pruebas de base, de navegador y de la copia
    docs/                  plan del CMMS y procedimiento de fusión

## Comandos

    npm install                 dependencias
    npm run dev                 interfaz en modo desarrollo (navegador)
    npm run build               compila renderer y proceso principal
    npm run dist                instalador de Windows
    tools/prueba_local.sh       migraciones y flujo de estados de backlog en un PostgreSQL temporal
    tests/ensayo_traer_preventivos.sh   ensayo de la copia de preventivos en dos PostgreSQL temporales
    tests/e2e.sh                         backlog en navegador (35 pasos)
    tests/e2e.sh flujo_preventivo.mjs    preventivo en navegador
    SIN_BUILD=1 APP_DIST=<dist de Control de Preventivos> tests/e2e.sh compat_preventivos.mjs
                                la app actual de preventivos contra la base del CMMS
    SIN_BUILD=1 APP_DIST=<dist de Control de Backlog> CLAVE_CONEXION=backlog.conexion tests/e2e.sh
                                la app actual de backlog contra la base del CMMS

## Entorno de pruebas

    tools/entorno_pruebas.sh             base local con datos de las dos apps y la app web en el puerto 5180
    tools/entorno_pruebas.sh reiniciar   vuelve a crear la base de pruebas desde cero
    tools/entorno_pruebas.sh detener     apaga la app y la base (los datos quedan en .pruebas/)

No toca Supabase. Los datos de preventivos entran con `tools/traer_preventivos.mjs`, la misma copia que se usará en producción. Usuarios: admin@prueba, cap@prueba (HEMCO), cap.vtn@prueba y cap.prev@prueba (Veta Nueva), todos con la contraseña `prueba`. Sin tiempo real: los cambios de otro usuario se ven al recargar.

## Flujos de GitHub Actions

- Pruebas: en cada push; base local, compilación y ensayo de la copia.
- Instalador de Windows: publica un release cuando cambia la versión de `package.json`.
- Web para celular: publica en GitHub Pages solo si existe la variable `SUPABASE_ANON_KEY`.
- Actualizar base de datos: solo a mano, pide escribir APLICAR.
- Traer datos de preventivos: solo a mano, modo ensayo o grabar (pide escribir GRABAR).
