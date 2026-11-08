#!/usr/bin/env node
// Servidor del entorno de pruebas: la app web compilada (dist-web/) y, en el mismo
// puerto, la imitación de Supabase de tests/servidor_rest.mjs sobre el PostgreSQL local
// (/rest/v1, /auth/v1, /storage/v1, /functions/v1). Lo arranca tools/entorno_pruebas.sh.
// Todos los usuarios de prueba entran con la contraseña CLAVE_PRUEBAS.
import { createServer, request } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { extname, join } from "node:path";
import { iniciarServidorRest } from "../tests/servidor_rest.mjs";

const RAIZ = new URL("..", import.meta.url).pathname;
const PUERTO = Number(process.env.PUERTO_APP ?? 5180);
const PUERTO_REST = PUERTO + 1;
const CARPETA = join(RAIZ, "dist-web");

await iniciarServidorRest({
  conexion: { host: process.env.PGHOST, port: Number(process.env.PGPORT), user: "postgres", database: "cmms" },
  puerto: PUERTO_REST,
  claveAcceso: process.env.CLAVE_PRUEBAS ?? "prueba",
});

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml",
  ".png": "image/png", ".webmanifest": "application/manifest+json", ".ico": "image/x-icon", ".woff2": "font/woff2",
};
const API = ["/rest/v1/", "/auth/v1/", "/storage/v1/", "/functions/v1/"];

createServer((req, res) => {
  const ruta = req.url.split("?")[0];
  if (API.some((p) => ruta.startsWith(p))) {
    const reenvio = request({ host: "127.0.0.1", port: PUERTO_REST, path: req.url, method: req.method, headers: req.headers }, (r) => {
      res.writeHead(r.statusCode ?? 502, r.headers);
      r.pipe(res);
    });
    reenvio.on("error", (e) => res.writeHead(502).end(String(e)));
    return req.pipe(reenvio);
  }
  if (ruta.startsWith("/realtime/")) return res.writeHead(404).end(); // sin tiempo real en pruebas
  const archivo = join(CARPETA, ruta === "/" ? "index.html" : ruta);
  if (!archivo.startsWith(CARPETA) || !existsSync(archivo)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": MIME[extname(archivo)] ?? "application/octet-stream", "cache-control": "no-store" });
  res.end(readFileSync(archivo));
}).listen(PUERTO, "0.0.0.0", () => console.log(`Entorno de pruebas del CMMS en http://localhost:${PUERTO}`));
