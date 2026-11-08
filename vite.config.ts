import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const version = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")).version;

// --mode web: sitio para celular (GitHub Pages) en dist-web/, sin pisar dist/ de Electron.
export default defineConfig(({ mode }) => ({
  plugins: [react()],
  define: { __APP_VERSION__: JSON.stringify(version) },
  base: "./",
  server: { port: 5183, strictPort: true },
  // demo: sitio de pruebas con la base en el navegador (PGlite), en dist-demo/.
  build: mode === "web" ? { outDir: "dist-web" } : mode === "demo" ? { outDir: "dist-demo" } : undefined,
  optimizeDeps: { exclude: ["@electric-sql/pglite"] },
  // Fuera de la demo, el servidor en el navegador se cambia por un módulo vacío.
  resolve: mode === "demo" ? undefined : { alias: [{ find: /^\.\.?\/(demo\/)?servidor$/, replacement: fileURLToPath(new URL("./src/demo/sin_demo.ts", import.meta.url)) }] },
}));
