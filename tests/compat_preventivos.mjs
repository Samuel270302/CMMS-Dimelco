// Compatibilidad: la app actual Control de Preventivos (0.6.0) contra la base del CMMS.
// Comprueba que, al apuntarla a la base fusionada, sigue mostrando el control y grabando
// lecturas sin cambios de código. APP_DIST = carpeta dist/ ya compilada de esa app.
// Uso: SIN_BUILD=1 APP_DIST=../Control-de-preventivos-Dimelco/dist tests/e2e.sh compat_preventivos.mjs
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
  const archivo = join(process.env.APP_DIST ?? join(RAIZ, "dist"), ruta);
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
      localStorage.setItem("preventivos.conexion", JSON.stringify({ url, anonKey: "llave-anon-de-prueba-0123456789" }));
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
  // 1. Control PM de la app actual con los datos de la base del CMMS.
  const adm = await abrir("admin");
  await adm.goto(base + "#/control");
  await adm.getByRole("heading", { name: "Control y proyección de mantenimientos preventivos" }).waitFor();
  await fila(adm, "PS011").first().waitFor();
  await fila(adm, "PS090").first().waitFor();
  const [ps011] = await consulta("select estado from v_control_pm where cod_interno = 'PS011'");
  await fila(adm, "PS011").first().locator("td", { hasText: ps011.estado.replace(/^\S+\s/, "") }).first().waitFor();
  await adm.screenshot({ path: join(SALIDA, "compat-preventivos-control.png") });
  ok("Control de Preventivos 0.6.0 abre Control PM sobre la base del CMMS con los mismos estados");

  // 2. Ficha, equipos y usuarios de la app actual cargan.
  await fila(adm, "JU005").first().getByRole("link", { name: "JU005" }).click();
  await adm.getByText("Perforadora B1").first().waitFor();
  await adm.goto(base + "#/equipos");
  await adm.getByRole("link", { name: "PS011" }).first().waitFor();
  await adm.goto(base + "#/usuarios");
  await adm.getByText("cap@prueba").first().waitFor();
  ok("ficha de equipo, Equipos y Usuarios de la app actual cargan con los datos del CMMS");

  // 3. El capturador graba una lectura desde la app actual.
  const cap = await abrir("cap");
  await cap.goto(base + "#/lecturas");
  const casilla = cap.getByLabel("Nueva lectura PS011 Diesel");
  await casilla.waitFor();
  const [{ ultima }] = await consulta(`select max(l.lectura)::float as ultima from lecturas l
    join componentes c on c.id = l.componente_id join equipos e on e.id = c.equipo_id
    where e.cod_interno = 'PS011' and c.tipo_horometro = 'Diesel'`);
  await casilla.fill(String(ultima + 4));
  await fila(cap, "PS011").locator(".control-ok, .control-aviso").waitFor();
  await cap.getByRole("button", { name: "Grabar lecturas" }).click();
  await aviso(cap, "1 lectura(s) grabada(s)");
  const [{ n }] = await consulta(`select count(*)::int as n from lecturas l join componentes c on c.id = l.componente_id
    join equipos e on e.id = c.equipo_id where e.cod_interno = 'PS011' and l.lectura = $1`, [ultima + 4]);
  if (n !== 1) throw new Error("La lectura de la app actual no quedó en la base del CMMS");
  ok("el capturador graba una lectura desde la app actual y queda en la base del CMMS");

  // 4. Seguridad por unidad igual que hoy.
  const vtn = await abrir("capVtn");
  await vtn.goto(base + "#/control");
  await fila(vtn, "PS090").first().waitFor();
  if (await fila(vtn, "PS011").count()) throw new Error("Veta Nueva ve PS011 de HEMCO en la app actual");
  ok("en la app actual el capturador de Veta Nueva sigue viendo solo su unidad");

  if (errores.length) throw new Error("Errores de página:\n" + errores.join("\n"));
  console.log(`\nPRUEBA OK: ${paso} pasos`);
} catch (e) {
  console.error(`\nFALLA después del paso ${paso}: ${e.message}`);
  for (const [i, [quien, p]] of paginas.entries()) {
    await p.screenshot({ path: join(SALIDA, `falla-compat-${i}-${quien}.png`), fullPage: true }).catch(() => {});
  }
  if (errores.length) console.error(errores.join("\n"));
  process.exitCode = 1;
} finally {
  await navegador.close();
  estatico.close();
  await rest.cerrar();
  await db.end();
}
