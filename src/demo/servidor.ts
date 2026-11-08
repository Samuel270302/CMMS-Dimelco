// Demo web del CMMS: PostgreSQL corre dentro del navegador (PGlite) con el mismo esquema
// que producción (migraciones 001-020) y datos de prueba. Esta función reemplaza el
// fetch de supabase-js: atiende /rest/v1, /auth/v1, /storage/v1 y /functions/v1 contra
// esa base, con el rol "authenticated" y el usuario de la sesión, así las políticas y
// funciones son las reales. Los datos quedan en IndexedDB de este navegador.
// Solo entra en el sitio compilado con VITE_DEMO=1.
import { PGlite, type Transaction } from "@electric-sql/pglite";
import baseLocal from "../../tools/base_local.sql?raw";
import instalarTodo from "../../supabase/instalar_todo.sql?raw";
import semillaBacklog from "../../tests/semilla_e2e.sql?raw";
import semillaPreventivo from "../../tests/semilla_e2e_preventivo.sql?raw";
import semillaProgramacion from "../../tests/semilla_programacion.sql?raw";

export const CLAVE_DEMO = "prueba";
const VERSION_DATOS = "cmms-demo-2";
const DIR = `idb://${VERSION_DATOS}`;

let base: Promise<PGlite> | null = null;
const archivos = new Map<string, Blob>(); // fotos subidas en esta pestaña (se pierden al recargar)

async function abrir(): Promise<PGlite> {
  const db = new PGlite(DIR);
  await db.waitReady;
  const { rows } = await db.query<{ hay: boolean }>("select to_regclass('public.v_ot') is not null as hay");
  if (!rows[0]?.hay) {
    for (const sql of [baseLocal, instalarTodo, semillaBacklog, semillaPreventivo, semillaProgramacion]) await db.exec(sql);
    await db.exec("select set_config('request.jwt.claims', '', false); reset role;");
  }
  return db;
}
export const baseDemo = () => (base ??= abrir());

// Borra los datos de prueba de este navegador y vuelve a sembrarlos.
export async function reiniciarDemo() {
  try {
    const db = await baseDemo();
    await db.close();
  } catch {
    // base dañada: se borra igual
  }
  await new Promise<void>((ok) => {
    const r = indexedDB.deleteDatabase(`/pglite/${VERSION_DATOS}`);
    r.onsuccess = r.onerror = r.onblocked = () => ok();
  });
  localStorage.clear();
  location.reload();
}

// ---------------------------------------------------------------- utilidades
const ID = /^[a-z_][a-z0-9_]*$/;
const ident = (s: string) => {
  if (!ID.test(s)) throw new Error(`Identificador no permitido: ${s}`);
  return `"${s}"`;
};
const json = (estado: number, cuerpo: unknown, extra: Record<string, string> = {}) =>
  new Response(cuerpo === undefined ? null : JSON.stringify(cuerpo), {
    status: estado,
    headers: { "content-type": "application/json", ...extra },
  });

function usuarioDe(h: Headers): { sub?: string; email?: string } | null {
  const token = (h.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  try {
    const p = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(decodeURIComponent(escape(atob(p))));
  } catch {
    return null;
  }
}

function filtros(params: URLSearchParams, valores: unknown[]): string {
  const partes: string[] = [];
  for (const [clave, valor] of params) {
    if (["select", "order", "limit", "offset", "columns"].includes(clave)) continue;
    if (valor.startsWith("eq.")) {
      valores.push(valor.slice(3));
      partes.push(`${ident(clave)}::text = $${valores.length}`);
    } else if (/^(gte|lte|gt|lt|neq)\./.test(valor)) {
      const [op, ...resto] = valor.split(".");
      const signo = { gte: ">=", lte: "<=", gt: ">", lt: "<", neq: "<>" }[op];
      valores.push(resto.join("."));
      partes.push(`${ident(clave)} ${signo} $${valores.length}`);
    } else if (valor === "is.null" || valor === "not.is.null") {
      partes.push(`${ident(clave)} is ${valor === "is.null" ? "" : "not "}null`);
    } else if (valor.startsWith("in.(")) {
      valores.push(JSON.stringify(valor.slice(4, -1).split(",").map((s) => s.replaceAll('"', ""))));
      partes.push(`${ident(clave)}::text in (select jsonb_array_elements_text($${valores.length}::jsonb))`);
    } else {
      throw new Error(`Filtro no soportado: ${clave}=${valor}`);
    }
  }
  return partes.length ? ` where ${partes.join(" and ")}` : "";
}
const columnas = (p: URLSearchParams) => {
  const sel = p.get("select") ?? "*";
  return sel === "*" ? "*" : sel.split(",").map((c) => ident(c.trim())).join(", ");
};
const orden = (p: URLSearchParams) => {
  const o = p.get("order");
  if (!o) return "";
  return " order by " + o.split(",").map((x) => {
    const [c, dir] = x.split(".");
    return `${ident(c)} ${dir === "desc" ? "desc" : "asc"}`;
  }).join(", ");
};
const comoJson = (sql: string) => `select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) as j from (${sql}) x`;

// Ejecuta con el rol authenticated y el usuario de la sesión, como PostgREST.
async function comoUsuario<T>(h: Headers, trabajo: (tx: Transaction) => Promise<T>): Promise<T> {
  const db = await baseDemo();
  return db.transaction(async (tx) => {
    await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(usuarioDe(h) ?? {})]);
    await tx.exec("set local role authenticated");
    return trabajo(tx);
  });
}

// ---------------------------------------------------------------- rutas
async function rest(req: Request, url: URL): Promise<Response> {
  const ruta = url.pathname.split("/rest/v1/")[1];
  const cuerpo = req.method === "GET" || req.method === "HEAD" ? "" : await req.text();
  const objeto = (req.headers.get("accept") ?? "").includes("vnd.pgrst.object");
  const representar = (req.headers.get("prefer") ?? "").includes("return=representation");
  try {
    const salida = await comoUsuario(req.headers, async (tx) => {
      const valores: unknown[] = [];
      let sql: string;
      if (ruta.startsWith("rpc/")) {
        const args = JSON.parse(cuerpo || "{}") as Record<string, unknown>;
        const lista = Object.keys(args).map((k) => {
          const v = args[k];
          valores.push(v !== null && typeof v === "object" ? JSON.stringify(v) : v);
          return `${ident(k)} => $${valores.length}`;
        });
        sql = `select to_jsonb(r) as j from ${ident(ruta.slice(4))}(${lista.join(", ")}) r`;
        const r = await tx.query<{ j: unknown }>(sql, valores);
        return { filas: r.rows.map((x) => x.j), rpc: true };
      }
      const t = ident(ruta);
      if (req.method === "GET") {
        sql = `select ${columnas(url.searchParams)} from ${t}${filtros(url.searchParams, valores)}${orden(url.searchParams)}`;
      } else if (req.method === "POST") {
        const datos = JSON.parse(cuerpo);
        const filas = Array.isArray(datos) ? datos : [datos];
        const cols = Object.keys(filas[0]).map(ident).join(", ");
        valores.push(JSON.stringify(filas));
        sql = `insert into ${t} (${cols}) select ${cols} from json_populate_recordset(null::${t}, $1) returning ${columnas(url.searchParams)}`;
      } else if (req.method === "PATCH") {
        const cols = Object.keys(JSON.parse(cuerpo)).map(ident).join(", ");
        valores.push(cuerpo);
        sql = `update ${t} set (${cols}) = (select ${cols} from json_populate_record(null::${t}, $1))`;
        sql += filtros(url.searchParams, valores) + ` returning ${columnas(url.searchParams)}`;
      } else if (req.method === "DELETE") {
        sql = `delete from ${t}${filtros(url.searchParams, valores)} returning *`;
      } else {
        throw new Error(`Método no soportado: ${req.method}`);
      }
      const r = await tx.query<{ j: unknown[] }>(comoJsonCte(sql), valores);
      return { filas: r.rows[0]?.j ?? [], rpc: false };
    });
    if (req.method !== "GET" && !salida.rpc && !representar) return new Response(null, { status: 201 });
    return json(200, salida.rpc || objeto ? (salida.filas[0] ?? null) : salida.filas);
  } catch (e) {
    const err = e as { message?: string; code?: string };
    return json(400, { message: err.message ?? String(e), code: err.code ?? "PGRST", details: null, hint: null });
  }
}
// insert/update/delete con returning no van en una subconsulta: se usan como CTE.
const comoJsonCte = (sql: string) =>
  /^\s*select/i.test(sql) ? comoJson(sql) : `with x as (${sql}) select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) as j from x`;

async function autenticar(req: Request, url: URL): Promise<Response> {
  const ruta = url.pathname.split("/auth/v1/")[1];
  const datos = req.method === "GET" ? {} : JSON.parse((await req.text()) || "{}");
  const db = await baseDemo();
  const buscar = async (campo: "email" | "id", valor: string) =>
    (await db.query<{ id: string; email: string; raw_user_meta_data: Record<string, unknown> }>(
      `select id::text, email, raw_user_meta_data from auth.users where ${campo === "email" ? "lower(email) = lower($1)" : "id::text = $1"}`,
      [valor]
    )).rows[0];
  const sesion = (u: { id: string; email: string; raw_user_meta_data?: Record<string, unknown> }) => {
    const exp = Math.floor(Date.now() / 1000) + 8 * 3600;
    const b64 = (o: unknown) => btoa(unescape(encodeURIComponent(JSON.stringify(o)))).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const usuario = { id: u.id, email: u.email, aud: "authenticated", role: "authenticated", app_metadata: {},
      user_metadata: u.raw_user_meta_data ?? {}, created_at: new Date().toISOString() };
    return { access_token: `${b64({ alg: "HS256", typ: "JWT" })}.${b64({ sub: u.id, role: "authenticated", email: u.email, exp })}.demo`,
      token_type: "bearer", expires_in: 8 * 3600, expires_at: exp, refresh_token: u.id, user: usuario };
  };
  if (ruta === "token" && url.searchParams.get("grant_type") === "password") {
    const u = await buscar("email", datos.email ?? "");
    if (!u || datos.password !== CLAVE_DEMO)
      return json(400, { error: "invalid_grant", error_description: "Invalid login credentials", msg: "Invalid login credentials" });
    return json(200, sesion(u));
  }
  if (ruta === "token" && url.searchParams.get("grant_type") === "refresh_token") {
    const u = await buscar("id", datos.refresh_token ?? "");
    return u ? json(200, sesion(u)) : json(400, { error: "invalid_grant", error_description: "Invalid Refresh Token" });
  }
  if (ruta === "user") {
    const quien = usuarioDe(req.headers);
    const u = quien?.sub ? await buscar("id", quien.sub) : undefined;
    if (!u) return json(401, { msg: "Sesión no válida" });
    if (req.method === "PUT") return json(400, { msg: "En la demo todas las contraseñas son «prueba»" });
    return json(200, sesion(u).user);
  }
  if (ruta === "logout") return new Response(null, { status: 204 });
  return json(200, {});
}

async function almacenamiento(req: Request, url: URL): Promise<Response> {
  const ruta = decodeURIComponent(url.pathname.split("/storage/v1/")[1]);
  try {
    if (req.method === "POST" && ruta.startsWith("object/sign/")) {
      const bucket = ruta.slice("object/sign/".length);
      const { paths } = (await req.json()) as { paths: string[] };
      const visibles = await comoUsuario(req.headers, (tx) =>
        tx.query<{ name: string }>("select name from storage.objects where bucket_id = $1 and name in (select jsonb_array_elements_text($2::jsonb))", [bucket, JSON.stringify(paths)]));
      const ok = new Set(visibles.rows.map((v) => v.name));
      return json(200, paths.map((p) => ({ path: p, signedURL: ok.has(p) ? `/object/sign/${bucket}/${p}?token=demo` : null, error: ok.has(p) ? null : "Sin permiso" })));
    }
    if (req.method === "GET" && ruta.startsWith("object/sign/")) {
      const a = archivos.get(ruta.slice("object/sign/".length));
      return a ? new Response(a, { status: 200, headers: { "content-type": a.type || "image/jpeg" } }) : json(404, { message: "La foto se borró al recargar la demo" });
    }
    if (req.method === "POST" && ruta.startsWith("object/")) {
      const clave = ruta.slice("object/".length);
      const [bucket, ...resto] = clave.split("/");
      const nombre = resto.join("/");
      await comoUsuario(req.headers, (tx) => tx.query("insert into storage.objects (bucket_id, name) values ($1, $2)", [bucket, nombre]));
      const form = (req.headers.get("content-type") ?? "").includes("multipart") ? await req.formData() : null;
      const archivo = form ? ([...form.values()].find((v) => v instanceof Blob) as Blob | undefined) : await req.blob();
      if (archivo) archivos.set(clave, archivo);
      return json(200, { Key: clave, Id: nombre });
    }
    if (req.method === "DELETE" && ruta.startsWith("object/")) {
      const bucket = ruta.slice("object/".length);
      const { prefixes } = (await req.json()) as { prefixes: string[] };
      const r = await comoUsuario(req.headers, (tx) =>
        tx.query<{ name: string }>("delete from storage.objects where bucket_id = $1 and name in (select jsonb_array_elements_text($2::jsonb)) returning name", [bucket, JSON.stringify(prefixes)]));
      for (const b of r.rows) archivos.delete(`${bucket}/${b.name}`);
      return json(200, r.rows.map((b) => ({ name: b.name })));
    }
    return json(404, { message: "Ruta de storage no soportada en la demo" });
  } catch (e) {
    return json(400, { statusCode: "403", error: "Unauthorized", message: (e as Error).message });
  }
}

// Imitación de la función admin-usuarios: crear usuarios (entran con «prueba»).
async function funciones(req: Request): Promise<Response> {
  const db = await baseDemo();
  const quien = usuarioDe(req.headers);
  const { rows } = await db.query<{ rol: string; activo: boolean }>("select rol, activo from perfiles where user_id::text = $1", [quien?.sub ?? ""]);
  if (!rows[0] || rows[0].rol !== "admin" || !rows[0].activo) return json(403, { error: "Solo un administrador activo puede gestionar usuarios" });
  const d = (await req.json()) as Record<string, unknown>;
  if (d.accion === "restablecer") return json(200, { ok: true });
  if (d.accion !== "crear") return json(400, { error: "Acción no disponible en la demo" });
  const lista = Array.isArray(d.unidades) ? (d.unidades as string[]) : d.unidad_id ? [String(d.unidad_id)] : [];
  if (d.rol !== "admin" && lista.length === 0) return json(400, { error: "Marque al menos una unidad para el usuario" });
  try {
    const r = await db.query<{ id: string }>(
      "insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), lower($1), jsonb_build_object('nombre', $2::text)) returning id::text",
      [String(d.correo), String(d.nombre)]);
    const id = r.rows[0].id;
    await db.query("update perfiles set nombre = $1, rol = $2, activo = true, unidades = (select coalesce(array_agg(x::uuid), '{}') from jsonb_array_elements_text($3::jsonb) x) where user_id::text = $4",
      [String(d.nombre), String(d.rol), JSON.stringify(d.rol === "admin" ? [] : lista), id]);
    return json(200, { ok: true, user_id: id });
  } catch (e) {
    return json(400, { error: (e as Error).message });
  }
}

export async function fetchDemo(entrada: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const req = new Request(entrada, init);
  const url = new URL(req.url);
  if (url.pathname.includes("/rest/v1/")) return rest(req, url);
  if (url.pathname.includes("/auth/v1/")) return autenticar(req, url);
  if (url.pathname.includes("/storage/v1/")) return almacenamiento(req, url);
  if (url.pathname.includes("/functions/v1/")) return funciones(req);
  return json(404, { message: "Ruta no disponible en la demo" });
}
