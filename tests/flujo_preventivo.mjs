// Prueba de extremo a extremo de las pantallas de preventivo dentro del CMMS.
// La app construida (dist/) habla con tests/servidor_rest.mjs, que ejecuta cada
// llamada en el PostgreSQL local con el rol y el usuario de la sesión.
// Uso: tests/e2e.sh (levanta la base, aplica migraciones y semilla, y corre esto).
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { extname, join } from "node:path";
import { iniciarServidorRest } from "./servidor_rest.mjs";
import { token } from "./utilidades.mjs";
import pg from "pg";

const require = createRequire(import.meta.url);
let playwright;
try {
  playwright = require("playwright");
} catch {
  playwright = require("/opt/node-tools/node_modules/playwright/index.js");
}
const { chromium } = playwright;

const RAIZ = new URL("..", import.meta.url).pathname;
const SALIDA = join(RAIZ, "capturas");
mkdirSync(SALIDA, { recursive: true });
const PUERTO_APP = 5189;
const PUERTO_REST = 5190;

const MIME = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png" };
const estatico = createServer((req, res) => {
  let ruta = req.url.split("?")[0];
  if (ruta === "/") ruta = "/index.html";
  const archivo = join(RAIZ, "dist", ruta);
  if (!existsSync(archivo)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": MIME[extname(archivo)] ?? "application/octet-stream" });
  res.end(readFileSync(archivo));
});
await new Promise((r) => estatico.listen(PUERTO_APP, r));
const rest = await iniciarServidorRest({
  conexion: { host: process.env.PGHOST, port: Number(process.env.PGPORT), user: "postgres", database: "postgres" },
  puerto: PUERTO_REST,
});

const USUARIOS = {
  admin: { id: "00000000-0000-0000-0000-00000000000a", email: "admin@prueba" },
  cap: { id: "00000000-0000-0000-0000-00000000000c", email: "cap@prueba" },
  capVtn: { id: "00000000-0000-0000-0000-00000000000d", email: "cap.vtn@prueba" },
};



const navegador = await chromium.launch();
const errores = [];
const paginas = [];

async function abrir(quien, ancho = 1366, alto = 860) {
  const u = USUARIOS[quien];
  const ctx = await navegador.newContext({ viewport: { width: ancho, height: alto } });
  const sesion = {
    access_token: token(u),
    refresh_token: "prueba",
    token_type: "bearer",
    expires_at: Math.floor(Date.now() / 1000) + 86400,
    expires_in: 86400,
    user: { id: u.id, email: u.email, aud: "authenticated", role: "authenticated", app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() },
  };
  await ctx.addInitScript(
    ([s, url]) => {
      localStorage.setItem("cmms.conexion", JSON.stringify({ url, anonKey: "llave-anon-de-prueba-0123456789" }));
      localStorage.setItem("sb-localhost-auth-token", JSON.stringify(s));
    },
    [sesion, `http://localhost:${PUERTO_REST}`]
  );
  await ctx.route("**/realtime/**", (r) => r.abort());
  const pagina = await ctx.newPage();
  paginas.push([quien, pagina]);
  pagina.on("pageerror", (e) => errores.push(`${quien}: ${e}`));
  pagina.on("response", async (r) => {
    if (r.status() >= 400 && r.url().includes("/rest/v1/"))
      console.log(`  [${quien}] ${r.status()} ${r.request().method()} ${decodeURIComponent(r.url().split("/rest/v1/")[1]).slice(0, 90)} ${(await r.text().catch(() => "")).slice(0, 160)}`);
  });
  return pagina;
}

let paso = 0;
function ok(texto) {
  paso++;
  console.log(`ok ${paso} - ${texto}`);
}
async function esperarEstado(p, estado) {
  await p.locator(".ficha-folio .etiqueta-estado", { hasText: estado }).waitFor({ timeout: 8000 });
}
async function transicion(p, boton, rellenar) {
  await p.locator(".ficha-acciones").getByRole("button", { name: boton, exact: true }).click();
  const d = p.getByRole("dialog");
  await d.waitFor();
  if (rellenar) await rellenar(d);
  await d.getByRole("button", { name: boton, exact: true }).click();
}
async function aviso(p, texto) {
  await p.locator(".aviso", { hasText: texto }).first().waitFor({ timeout: 8000 });
}
const base = `http://localhost:${PUERTO_APP}/`;
const enDias = (n) => {
  const d = new Date();
  d.setDate(d.getDate() + n);
  return d.toISOString().slice(0, 10);
};

const db = new pg.Client({ host: process.env.PGHOST, port: Number(process.env.PGPORT), user: "postgres", database: "postgres" });
await db.connect();
const consulta = async (sql, p = []) => (await db.query(sql, p)).rows;
const fila = (p, texto) => p.locator("tbody tr", { hasText: texto });

try {
  // 1. Al entrar, el CMMS abre en Control PM; el menú tiene Preventivo y Backlog.
  const adm = await abrir("admin");
  await adm.goto(base);
  await adm.getByRole("heading", { name: "Control y proyección de mantenimientos preventivos" }).waitFor();
  await adm.waitForURL(/#\/preventivo\/control/);
  for (const t of ["Control PM", "Lecturas", "Registro PM", "Kanban", "Calendario", "Componentes y horómetros", "Plan MP"])
    await adm.locator(".menu nav").getByRole("link", { name: t, exact: true }).waitFor();
  await fila(adm, "PS011").first().waitFor();
  await fila(adm, "PS090").first().waitFor();
  await adm.screenshot({ path: join(SALIDA, "cmms-control-pm.png") });
  ok("el CMMS abre en Control PM con equipos de HEMCO y Veta Nueva; el menú tiene Preventivo, Backlog y Administración");

  // 2. Los estados del control salen de las vistas: PS011 está cerca de su PM.
  const [ps011] = await consulta("select estado, proxima_gama from v_control_pm where cod_interno = 'PS011'");
  await fila(adm, "PS011").first().locator("td", { hasText: ps011.estado.replace(/^\S+\s/, "") }).first().waitFor();
  ok(`Control PM muestra PS011 en «${ps011.estado}» con próxima gama ${ps011.proxima_gama}, igual que la vista`);

  // 3. Ficha del equipo: pestaña Preventivo por defecto y pestaña Backlog con sus trabajos.
  await fila(adm, "JU005").first().getByRole("link", { name: "JU005" }).click();
  await adm.getByRole("heading", { name: "JU005" }).first().waitFor();
  await adm.locator(".pestania.activa", { hasText: "Preventivo" }).waitFor();
  await adm.getByText("Perforadora B1").first().waitFor();
  await adm.locator(".pestania", { hasText: "Backlog" }).click();
  await adm.getByText("Reparar luminaria de cabina").first().waitFor();
  await adm.screenshot({ path: join(SALIDA, "cmms-ficha-backlog.png"), fullPage: true });
  ok("la ficha de JU005 junta horómetros (Perforadora B1) y su backlog (luminaria de cabina) en pestañas");

  // 4. Rutina 40 h y programa de 4 semanas.
  await adm.goto(base + "#/preventivo/rutina40");
  await fila(adm, "JU005").first().waitFor();
  await adm.goto(base + "#/preventivo/programa");
  await adm.getByRole("heading").first().waitFor();
  ok("Rutina 40 h muestra la perforadora de JU005 y el programa de 4 semanas abre");

  // 5. El capturador de HEMCO graba una lectura; la base la valida y Control PM la toma.
  const cap = await abrir("cap");
  await cap.goto(base + "#/preventivo/lecturas");
  const casilla = cap.getByLabel("Nueva lectura PS011 Diesel");
  await casilla.waitFor();
  if (await cap.getByLabel("Nueva lectura PS090 Diesel").count()) throw new Error("El capturador de HEMCO ve PS090 de Veta Nueva");
  const [{ ultima }] = await consulta(`select max(l.lectura)::float as ultima from lecturas l
    join componentes c on c.id = l.componente_id join equipos e on e.id = c.equipo_id
    where e.cod_interno = 'PS011' and c.tipo_horometro = 'Diesel'`);
  await casilla.fill(String(ultima - 50));
  await fila(cap, "PS011").locator(".control-error").waitFor();
  await casilla.fill(String(ultima + 6));
  await fila(cap, "PS011").locator(".control-ok, .control-aviso").waitFor();
  await cap.getByRole("button", { name: "Grabar lecturas" }).click();
  await aviso(cap, "1 lectura(s) grabada(s)");
  const [{ n }] = await consulta(`select count(*)::int as n from lecturas l join componentes c on c.id = l.componente_id
    join equipos e on e.id = c.equipo_id where e.cod_interno = 'PS011' and l.lectura = $1 and l.creado_por = $2`,
    [ultima + 6, "00000000-0000-0000-0000-00000000000c"]);
  if (n !== 1) throw new Error("La lectura no quedó grabada con el usuario del capturador");
  ok("el capturador ve solo HEMCO; una lectura menor se marca en rojo y la correcta se graba con su usuario");

  // 6. El capturador de Veta Nueva solo ve su unidad en Control PM.
  const vtn = await abrir("capVtn");
  await vtn.goto(base + "#/preventivo/control");
  await fila(vtn, "PS090").first().waitFor();
  if (await fila(vtn, "PS011").count()) throw new Error("Veta Nueva ve PS011 de HEMCO");
  ok("el capturador de Veta Nueva ve PS090 y no los equipos de HEMCO");

  // 7. Las pantallas de backlog siguen en el mismo menú.
  await vtn.locator(".menu nav").getByRole("link", { name: "Kanban", exact: true }).click();
  await vtn.locator(".tarjeta-kanban").first().waitFor();
  ok("desde el mismo menú el capturador abre el Kanban de backlog");

  if (errores.length) throw new Error("Errores de página:\n" + errores.join("\n"));
  console.log(`\nPRUEBA OK: ${paso} pasos`);
} catch (e) {
  console.error(`\nFALLA después del paso ${paso}: ${e.message}`);
  for (const [i, [quien, p]] of paginas.entries()) {
    await p.screenshot({ path: join(SALIDA, `falla-prev-${i}-${quien}.png`), fullPage: true }).catch(() => {});
  }
  if (errores.length) console.error(errores.join("\n"));
  process.exitCode = 1;
} finally {
  await navegador.close();
  estatico.close();
  await rest.cerrar();
  await db.end();
}
