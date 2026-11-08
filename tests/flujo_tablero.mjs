// Prueba de extremo a extremo del tablero de programación: arrastrar PM y backlogs, agrupar,
// mover con motivo, anular y carga del taller.
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
const sumar = (iso, n) => {
  const d = new Date(iso + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const hoyIso = (await consulta("select current_date::text as d"))[0].d;
const dow = (new Date(hoyIso + "T12:00:00Z").getUTCDay() + 6) % 7;
const lunesSig = sumar(hoyIso, 7 - dow); // lunes de la semana siguiente: todos sus días son futuros
const celda = (p, cod, dia, turno) => p.getByLabel(`Celda ${cod} ${dia} ${turno}`, { exact: true });
async function motivo(p, texto) {
  const d = p.getByRole("dialog").filter({ has: p.getByLabel("Motivo") });
  await d.getByLabel("Motivo").fill(texto);
  await d.getByRole("button", { name: "Aceptar" }).click();
}
const folio = async (id) => (await consulta("select folio from backlogs where id = $1", [id]))[0].folio;
const B_LUMINARIA = "30000000-0000-0000-0000-000000000003";
const B_CENTRALIZADOR = "30000000-0000-0000-0000-000000000004";

try {
  // 1. El tablero junta PM sugeridos, backlogs listos y el programado sin OT de la semana siguiente.
  const cap = await abrir("cap", 1500, 900);
  await cap.goto(base + "#/programacion");
  await cap.getByRole("heading", { name: "Tablero de programación" }).waitFor();
  await cap.getByRole("button", { name: "Semana siguiente" }).click();
  await cap.getByLabel("Sugerido Preventiva PS011 Motor Diésel").waitFor();
  await cap.getByLabel("Sugerido Rutina 40 h JU005 Perforadora B1").waitFor();
  const fLum = await folio(B_LUMINARIA);
  const fCen = await folio(B_CENTRALIZADOR);
  await cap.getByLabel(`Backlog ${fLum} JU005`).waitFor();
  await cap.getByLabel(`Programado sin OT ${fCen}`).waitFor();
  if (await cap.getByLabel(/^Backlog .* PS090$/).count()) throw new Error("El capturador de HEMCO ve backlogs de Veta Nueva");
  ok("el tablero muestra PM sugeridos, backlogs listos y el backlog programado sin OT, solo de HEMCO");

  // 2. Arrastrar el PM de PS011 a su fila crea la OT preventiva con las HH de la pauta.
  await cap.getByLabel("Sugerido Preventiva PS011 Motor Diésel").dragTo(celda(cap, "PS011", lunesSig, "Día"));
  await aviso(cap, "Preventiva de PS011 programado");
  const otPm = celda(cap, "PS011", lunesSig, "Día").locator(".tarjeta-ot");
  await otPm.waitFor();
  await cap.getByLabel("Carga Mecánico").getByText("14 / 40 HH").waitFor(); // 6 del PM + 8 del backlog programado sin OT
  if (await cap.getByLabel("Sugerido Preventiva PS011 Motor Diésel").count()) throw new Error("El PM programado sigue sugerido");
  ok("arrastrar el PM de PS011 crea su OT; la carga de Mecánico suma sus 6 HH a las 8 del backlog sin OT (14 de 40) y sale de los sugeridos");

  // 3. Soltar en la fila de otro equipo no hace nada.
  const antes = (await consulta("select count(*)::int as n from ordenes_trabajo"))[0].n;
  await cap.getByLabel(`Backlog ${fLum} JU005`).dragTo(celda(cap, "PS011", sumar(lunesSig, 1), "Día"));
  await cap.waitForTimeout(800);
  if ((await consulta("select count(*)::int as n from ordenes_trabajo"))[0].n !== antes) throw new Error("Se programó en la fila de otro equipo");
  ok("un backlog de JU005 soltado en la fila de PS011 no se programa");

  // 4. Backlog listo -> OT correctiva en JU005; la rutina 40 h se programa y absorbe el backlog sin OT.
  await cap.getByLabel(`Backlog ${fLum} JU005`).dragTo(celda(cap, "JU005", sumar(lunesSig, 1), "Noche"));
  await aviso(cap, `${fLum} programado en una OT`);
  await cap.getByLabel("Sugerido Rutina 40 h JU005 Perforadora B1").dragTo(celda(cap, "JU005", sumar(lunesSig, 2), "Día"));
  await aviso(cap, "Rutina 40 h de JU005 programado");
  const rutina = celda(cap, "JU005", sumar(lunesSig, 2), "Día").locator(".tarjeta-ot").first();
  await cap.getByLabel(`Programado sin OT ${fCen}`).dragTo(rutina);
  await motivo(cap, "Se hace con la rutina de percusión");
  await aviso(cap, `${fCen} agregado a`);
  await rutina.getByText("+1 backlog").waitFor();
  const [b4] = await consulta("select fecha_programada::text as f from backlogs where id = $1", [B_CENTRALIZADOR]);
  if (b4.f !== sumar(lunesSig, 2)) throw new Error(`El backlog agrupado quedó el ${b4.f}`);
  ok("backlog listo crea una correctiva; el programado sin OT se suelta sobre la rutina 40 h y toma su fecha");

  // 5. Mover la OT de PS011 a otro día pide motivo; la carga se mantiene.
  await otPm.dragTo(celda(cap, "PS011", sumar(lunesSig, 3), "Noche"));
  await motivo(cap, "Equipo en producción el lunes");
  await aviso(cap, "movida al");
  await celda(cap, "PS011", sumar(lunesSig, 3), "Noche").locator(".tarjeta-ot").waitFor();
  await cap.screenshot({ path: join(SALIDA, "tablero.png"), fullPage: true });
  ok("la OT de PS011 se mueve al jueves de noche con motivo");

  // 6. Detalle de la OT: bitácora y anulación; el PM vuelve a sugerirse.
  await celda(cap, "PS011", sumar(lunesSig, 3), "Noche").locator(".tarjeta-ot").click();
  const det = cap.getByRole("dialog");
  await det.getByText("Equipo en producción el lunes").waitFor();
  await det.getByRole("button", { name: "Anular OT" }).click();
  await motivo(cap, "Se adelanta a la parada general");
  await aviso(cap, "anulada");
  await cap.getByLabel("Sugerido Preventiva PS011 Motor Diésel").waitFor();
  ok("el detalle muestra la bitácora; al anular la OT el PM vuelve a los sugeridos");

  // 7. El capturador de Veta Nueva no ve las OT de HEMCO.
  const vtn = await abrir("capVtn", 1500, 900);
  await vtn.goto(base + "#/programacion");
  await vtn.getByRole("button", { name: "Semana siguiente" }).click();
  await vtn.getByRole("heading", { name: "Tablero de programación" }).waitFor();
  await vtn.waitForTimeout(800);
  if (await vtn.getByLabel(/^OT OT-HEM/).count()) throw new Error("Veta Nueva ve OT de HEMCO");
  ok("el capturador de Veta Nueva no ve las OT de HEMCO");

  if (errores.length) throw new Error("Errores de página:\n" + errores.join("\n"));
  console.log(`\nPRUEBA OK: ${paso} pasos`);
} catch (e) {
  console.error(`\nFALLA después del paso ${paso}: ${e.message}`);
  for (const [i, [quien, p]] of paginas.entries()) {
    await p.screenshot({ path: join(SALIDA, `falla-tablero-${i}-${quien}.png`), fullPage: true }).catch(() => {});
  }
  if (errores.length) console.error(errores.join("\n"));
  process.exitCode = 1;
} finally {
  await navegador.close();
  estatico.close();
  await rest.cerrar();
  await db.end();
}
