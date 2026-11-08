#!/usr/bin/env node
// Copia los datos de Control de Preventivos a la base del CMMS (el proyecto de backlog).
//
//   node tools/traer_preventivos.mjs --origen "<cadena preventivos>" --destino "<cadena CMMS>" [--grabar]
//
// Sin --grabar es un ensayo: hace toda la copia y la verificación dentro de una
// transacción y al final la deshace. Con --grabar confirma solo si la verificación
// sale sin diferencias. El origen se abre en solo lectura.
//
// Qué copia:
//   usuarios     los de preventivos que no están en el destino (auth.users y auth.identities,
//                misma contraseña) con su perfil; si ya están, el perfil del destino no se toca
//                y las diferencias se listan
//   parametros   las claves del control de horómetros, con los valores de preventivos
//   equipos      se cruzan por unidad (nombre) + cod_interno; los que ya existen conservan
//                los datos del destino y se completa fecha_inicio_operacion; los demás se crean
//   planes_mp, componentes, lecturas, registros_pm, cambios_horometro, registros_manuales,
//   columnas_control, con los mismos id
// Verificación: v_control_pm, v_control_40, v_cumplimiento_pm y v_utilizacion_mensual
// tienen que dar lo mismo en las dos bases, fila por fila, además de los conteos.
import pg from "pg";

const args = process.argv.slice(2);
const opcion = (n) => {
  const i = args.indexOf(n);
  return i >= 0 ? args[i + 1] : undefined;
};
const ORIGEN = opcion("--origen") ?? process.env.DSN_PREVENTIVOS;
const DESTINO = opcion("--destino") ?? process.env.DSN_CMMS;
const GRABAR = args.includes("--grabar");
if (!ORIGEN || !DESTINO) {
  console.error("Uso: node tools/traer_preventivos.mjs --origen <cadena> --destino <cadena> [--grabar]");
  process.exit(2);
}

const TABLAS_DATOS = ["planes_mp", "componentes", "lecturas", "registros_pm", "cambios_horometro", "registros_manuales"];
const CLAVES_PARAMETROS = ["max_horas_turno", "umbral_cambio_horometro", "hueco_turnos", "tendencia_dias",
  "tendencia_max_turnos", "antiguedad_lectura_aviso"];
const TRIGGERS = [["lecturas", "validar_lectura"], ["lecturas", "auditar_anulacion"],
  ["registros_pm", "validar_registro_pm"], ["registros_pm", "auditar_anulacion"]];
const VISTAS = [
  ["v_control_pm", "componente_id"],
  ["v_control_40", "componente_id"],
  ["v_cumplimiento_pm", "componente_id, fecha"],
  ["v_utilizacion_mensual", "componente_id, mes"],
];
const LOTE = 2000;

const avisos = [];
const aviso = (t) => { avisos.push(t); console.log("  aviso: " + t); };

async function filas(cliente, sql, params = []) {
  return (await cliente.query(sql, params)).rows;
}

async function existeTabla(cliente, esquema, tabla) {
  const r = await filas(cliente, "select to_regclass($1) is not null as hay", [`${esquema}.${tabla}`]);
  return r[0].hay;
}

async function columnas(cliente, esquema, tabla) {
  const r = await filas(cliente,
    `select column_name from information_schema.columns
     where table_schema = $1 and table_name = $2 and is_generated = 'NEVER' order by ordinal_position`,
    [esquema, tabla]);
  return r.map((x) => x.column_name);
}

// Inserta filas (objetos) con json_populate_recordset, solo con las columnas que tiene el destino.
async function insertar(cliente, tabla, datos, { esquema = "public", conflicto = "" } = {}) {
  if (datos.length === 0) return 0;
  const cols = await columnas(cliente, esquema, tabla);
  const lista = cols.map((c) => `"${c}"`).join(", ");
  let n = 0;
  for (let i = 0; i < datos.length; i += LOTE) {
    const lote = datos.slice(i, i + LOTE);
    const r = await cliente.query(
      `insert into ${esquema}.${tabla} (${lista})
       select ${lista} from json_populate_recordset(null::${esquema}.${tabla}, $1::json) ${conflicto}`,
      [JSON.stringify(lote)]);
    n += r.rowCount;
  }
  return n;
}

// Las vistas se comparan sin unidad_id (cada base tiene sus id de unidad) y con el
// equipo_id del origen traducido al del destino.
const normalizar = (fila, equipo) => {
  const { unidad_id, ...resto } = fila;
  if (equipo && resto.equipo_id) resto.equipo_id = equipo.get(resto.equipo_id) ?? resto.equipo_id;
  return JSON.stringify(resto);
};

async function main() {
  const origen = new pg.Client({ connectionString: ORIGEN });
  const destino = new pg.Client({ connectionString: DESTINO });
  await origen.connect();
  await destino.connect();
  await origen.query("begin transaction isolation level repeatable read read only");
  await destino.query("begin");
  let confirmar = false;
  try {
    console.log(GRABAR ? "Modo: grabar (confirma si la verificación sale limpia)" : "Modo: ensayo (se deshace al final)");

    // 0. El destino no debe tener datos de preventivos.
    for (const t of ["componentes", "lecturas", "registros_pm"]) {
      const [{ n }] = await filas(destino, `select count(*)::int as n from ${t}`);
      if (n > 0) throw new Error(`El destino ya tiene ${n} filas en ${t}: la copia se hace una sola vez.`);
    }

    // 1. Unidades por nombre.
    const uO = await filas(origen, "select id, nombre from unidades");
    const uD = await filas(destino, "select id, nombre from unidades");
    const unidad = new Map();
    for (const u of uO) {
      const d = uD.find((x) => x.nombre === u.nombre);
      if (!d) throw new Error(`La unidad «${u.nombre}» de preventivos no existe en el destino.`);
      unidad.set(u.id, d.id);
    }
    const mapUnidades = (lista) => (lista ?? []).map((id) => unidad.get(id)).filter(Boolean);

    // 2. Usuarios.
    const usuario = new Map(); // id origen -> id destino
    const usuariosO = await filas(origen, "select to_jsonb(u) as u from auth.users u");
    const usuariosD = await filas(destino, "select id, lower(email) as email from auth.users");
    const nuevos = [];
    for (const { u } of usuariosO) {
      const mismoId = usuariosD.find((x) => x.id === u.id);
      const mismoCorreo = usuariosD.find((x) => u.email && x.email === u.email.toLowerCase());
      if (mismoId) usuario.set(u.id, u.id);
      else if (mismoCorreo) {
        usuario.set(u.id, mismoCorreo.id);
        aviso(`${u.email}: en el destino tiene otro id; sus registros quedan con el usuario del destino.`);
      } else {
        usuario.set(u.id, u.id);
        nuevos.push(u);
      }
    }
    await insertar(destino, "users", nuevos, { esquema: "auth", conflicto: "on conflict do nothing" });
    if (nuevos.length && (await existeTabla(origen, "auth", "identities")) && (await existeTabla(destino, "auth", "identities"))) {
      const ids = nuevos.map((u) => u.id);
      const ident = (await filas(origen, "select to_jsonb(i) as i from auth.identities i where i.user_id = any($1::uuid[])", [ids])).map((x) => x.i);
      await insertar(destino, "identities", ident, { esquema: "auth", conflicto: "on conflict do nothing" });
    }
    const perfilesO = await filas(origen, "select user_id, nombre, correo, rol, activo, unidades from perfiles");
    const perfilesD = await filas(destino, "select user_id, rol, activo, unidades from perfiles");
    for (const p of perfilesO) {
      const idD = usuario.get(p.user_id);
      const unidades = mapUnidades(p.unidades);
      if (nuevos.some((u) => u.id === p.user_id)) {
        // crear_perfil ya dejó el perfil; se fija lo que tiene en preventivos.
        await destino.query(
          `insert into perfiles (user_id, nombre, correo, rol, activo, unidades)
           values ($1, $2, $3, $4, $5, $6::uuid[])
           on conflict (user_id) do update set nombre = excluded.nombre, rol = excluded.rol,
             activo = excluded.activo, unidades = excluded.unidades`,
          [idD, p.nombre, p.correo, p.rol, p.activo, unidades]);
      } else {
        const d = perfilesD.find((x) => x.user_id === idD);
        const mismas = d && [...(d.unidades ?? [])].sort().join() === [...unidades].sort().join();
        if (d && (d.rol !== p.rol || d.activo !== p.activo || (p.rol !== "admin" && !mismas))) {
          aviso(`${p.correo ?? p.nombre}: perfil distinto en las dos apps (preventivos ${p.rol}${p.activo ? "" : " inactivo"}, `
            + `destino ${d.rol}${d.activo ? "" : " inactivo"}); queda el del destino.`);
        }
      }
    }
    const usr = (id) => (id == null ? id : usuario.get(id) ?? id);
    console.log(`Usuarios: ${usuariosO.length} en preventivos, ${nuevos.length} nuevos en el destino.`);

    // 3. Parámetros del control.
    for (const p of await filas(origen, "select clave, valor, valor_texto, descripcion from parametros where clave = any($1)", [CLAVES_PARAMETROS])) {
      await destino.query(
        `insert into parametros (clave, valor, valor_texto, descripcion) values ($1, $2, $3, $4)
         on conflict (clave) do update set valor = excluded.valor, valor_texto = excluded.valor_texto,
           descripcion = excluded.descripcion`,
        [p.clave, p.valor, p.valor_texto, p.descripcion]);
    }

    // 4. Equipos.
    const equipo = new Map();
    const eqO = await filas(origen, `select id, unidad_id, cod_interno, cod_sap, modelo, activo,
      fecha_inicio_operacion::text as fecha_inicio_operacion, creado_por, creado_en::text as creado_en from equipos`);
    const eqD = await filas(destino, "select id, unidad_id, cod_interno, cod_sap, modelo, activo from equipos");
    const nuevosEq = [];
    for (const e of eqO) {
      const u = unidad.get(e.unidad_id);
      const d = eqD.find((x) => x.unidad_id === u && x.cod_interno.trim().toLowerCase() === e.cod_interno.trim().toLowerCase());
      if (d) {
        equipo.set(e.id, d.id);
        const dif = [];
        if ((d.cod_sap ?? "") !== (e.cod_sap ?? "")) dif.push(`cód. SAP ${e.cod_sap ?? "vacío"} / ${d.cod_sap ?? "vacío"}`);
        if (d.modelo !== e.modelo) dif.push(`modelo ${e.modelo} / ${d.modelo}`);
        if (d.activo !== e.activo) dif.push(`activo ${e.activo} / ${d.activo}`);
        if (dif.length) aviso(`Equipo ${e.cod_interno}: preventivos / destino distintos (${dif.join("; ")}); quedan los del destino.`);
        await destino.query(
          `update equipos set fecha_inicio_operacion = coalesce(fecha_inicio_operacion, $2),
             cod_sap = coalesce(cod_sap, $3), creado_por = coalesce(creado_por, $4) where id = $1`,
          [d.id, e.fecha_inicio_operacion, e.cod_sap, usr(e.creado_por)]);
      } else {
        const idLibre = !eqD.some((x) => x.id === e.id);
        const nuevo = { ...e, id: idLibre ? e.id : undefined, unidad_id: u, creado_por: usr(e.creado_por),
          flota: e.cod_interno.split("#")[0].trim() || null };
        nuevosEq.push(nuevo);
      }
    }
    for (const e of nuevosEq) {
      const r = await destino.query(
        `insert into equipos (id, unidad_id, cod_interno, cod_sap, modelo, flota, activo, fecha_inicio_operacion, creado_por, creado_en)
         values (coalesce($1::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8, $9, $10) returning id`,
        [e.id ?? null, e.unidad_id, e.cod_interno, e.cod_sap, e.modelo, e.flota, e.activo,
         e.fecha_inicio_operacion, e.creado_por, e.creado_en]);
      equipo.set(eqO.find((x) => x.cod_interno === e.cod_interno && unidad.get(x.unidad_id) === e.unidad_id).id, r.rows[0].id);
    }
    if (nuevosEq.length) aviso(`${nuevosEq.length} equipo(s) solo existían en preventivos y se crearon sin familia: ${nuevosEq.map((e) => e.cod_interno).join(", ")}. Asígneles familia en Equipos.`);
    console.log(`Equipos: ${eqO.length} en preventivos, ${eqO.length - nuevosEq.length} cruzados, ${nuevosEq.length} creados.`);

    // 5. Datos de preventivos, con los mismos id.
    for (const [t, g] of TRIGGERS) await destino.query(`alter table ${t} disable trigger ${g}`);
    const conteo = {};
    for (const t of TABLAS_DATOS) {
      const datos = (await filas(origen, `select to_jsonb(x) as f from ${t} x`)).map(({ f }) => {
        if (t === "componentes") f.equipo_id = equipo.get(f.equipo_id);
        for (const c of ["creado_por", "anulado_por"]) if (c in f) f[c] = usr(f[c]);
        return f;
      });
      conteo[t] = { origen: datos.length, copiadas: await insertar(destino, t, datos) };
    }
    for (const [t, g] of TRIGGERS) await destino.query(`alter table ${t} enable trigger ${g}`);
    for (const c of await filas(origen, "select columna, etiqueta, visible, orden from columnas_control")) {
      await destino.query(
        `insert into columnas_control (columna, etiqueta, visible, orden) values ($1, $2, $3, $4)
         on conflict (columna) do update set etiqueta = excluded.etiqueta, visible = excluded.visible, orden = excluded.orden`,
        [c.columna, c.etiqueta, c.visible, c.orden]);
    }

    // 6. Verificación.
    let diferencias = 0;
    console.log("\nConteos (origen / destino):");
    for (const t of TABLAS_DATOS) {
      const [{ n }] = await filas(destino, `select count(*)::int as n from ${t}`);
      const ok = n === conteo[t].origen;
      if (!ok) diferencias++;
      console.log(`  ${t.padEnd(20)} ${conteo[t].origen} / ${n}${ok ? "" : "  DIFERENCIA"}`);
    }
    console.log("\nVistas de cálculo (filas iguales / total):");
    for (const [v, orden] of VISTAS) {
      const sql = `select to_jsonb(x) as f from ${v} x order by ${orden}`;
      const a = (await filas(origen, sql)).map(({ f }) => normalizar(f, equipo));
      const b = (await filas(destino, sql)).map(({ f }) => normalizar(f));
      let iguales = 0;
      for (let i = 0; i < Math.max(a.length, b.length); i++) {
        if (a[i] === b[i]) iguales++;
        else if (diferencias < 20) console.log(`    ${v} fila ${i + 1}\n      origen:  ${a[i]}\n      destino: ${b[i]}`);
      }
      if (iguales !== a.length || a.length !== b.length) diferencias++;
      console.log(`  ${v.padEnd(22)} ${iguales} / ${a.length}${a.length !== b.length ? ` (destino ${b.length})` : ""}`);
    }

    console.log(`\nAvisos: ${avisos.length}`);
    if (diferencias) throw new Error(`Verificación con ${diferencias} diferencia(s): no se graba nada.`);
    confirmar = GRABAR;
    console.log(confirmar ? "\nVerificación sin diferencias. Se confirma la copia." : "\nVerificación sin diferencias. Ensayo: se deshace.");
  } finally {
    await destino.query(confirmar ? "commit" : "rollback");
    await origen.query("rollback");
    await origen.end();
    await destino.end();
  }
}

main().catch((e) => {
  console.error("\nERROR: " + e.message);
  process.exit(1);
});
