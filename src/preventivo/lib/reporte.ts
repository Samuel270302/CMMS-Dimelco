// Reporte semanal imprimible: se abre en una ventana aparte y se manda a
// imprimir (en Windows, "Microsoft Print to PDF" lo guarda como PDF).
import type { ControlFila } from "./types";
import { fFecha, fNum, gamaTexto, hoyISO } from "../../lib/fmt";

const ORDEN_ESTADOS = [
  "🔴 Vencido",
  "📅 Programar",
  "🔧 Verificar repuestos",
  "🟢 Normal",
];

function cuenta(filas: ControlFila[], estado: string) {
  return filas.filter((f) => f.estado === estado).length;
}

function tabla(filas: ControlFila[]) {
  const visibles = filas.filter((f) => !f.estado.startsWith("⚪"));
  const orden = (f: ControlFila) => {
    const i = ORDEN_ESTADOS.indexOf(f.estado);
    return i === -1 ? 99 : i;
  };
  visibles.sort((a, b) => orden(a) - orden(b) || (a.dias_restantes ?? 999) - (b.dias_restantes ?? 999));
  const filasHtml = visibles
    .map(
      (f) => `<tr>
        <td>${f.cod_interno}</td><td>${f.nombre}</td>
        <td class="n">${gamaTexto(f.proxima_gama)}</td>
        <td class="n">${fNum(f.meta_acum)}</td>
        <td class="n">${fNum(f.ultima_lectura_acum)}</td>
        <td class="n">${fNum(f.hrs_faltantes)}</td>
        <td class="n">${f.dias_restantes ?? ""}</td>
        <td>${fFecha(f.fecha_estimada)}</td>
        <td>${f.estado}</td>
        <td class="obs">${f.observacion ?? ""}</td>
      </tr>`
    )
    .join("");
  return `<table>
    <thead><tr><th>Equipo</th><th>Componente</th><th class="n">Próx. gama</th><th class="n">Meta (acum.)</th>
    <th class="n">Últ. lectura</th><th class="n">Hrs falt.</th><th class="n">Días</th><th>Fecha est.</th><th>Estado</th><th>Observación</th></tr></thead>
    <tbody>${filasHtml}</tbody></table>`;
}

export async function reporteSemanal(pm: ControlFila[], r40: ControlFila[], unidad: string | null): Promise<string | null> {
  const resumen = (filas: ControlFila[]) =>
    ORDEN_ESTADOS.map((e) => `<span class="chip">${e}: <b>${cuenta(filas, e)}</b></span>`).join(" ");
  const html = `<!doctype html><html lang="es"><head><meta charset="utf-8">
  <title>Reporte semanal de preventivos</title>
  <style>
    body { font-family: "Segoe UI", sans-serif; font-size: 11px; color: #1c1c1c; margin: 24px; }
    h1 { font-size: 17px; margin: 0 0 2px; }
    h2 { font-size: 13px; margin: 18px 0 6px; }
    .sub { color: #555; margin: 0 0 10px; }
    .chip { border: 1px solid #ccc; border-radius: 10px; padding: 2px 8px; margin-right: 6px; }
    table { border-collapse: collapse; width: 100%; margin-top: 6px; }
    th, td { border: 1px solid #d5d5d5; padding: 3px 6px; text-align: left; }
    th { background: #efefef; }
    td.n, th.n { text-align: right; }
    td.obs { max-width: 230px; }
    @media print { @page { size: A4 landscape; margin: 12mm; } }
  </style></head><body>
  <h1>Reporte semanal de mantenimiento preventivo</h1>
  <p class="sub">${unidad ? `Unidad ${unidad}` : "Todas las unidades"} · generado el ${fFecha(hoyISO())}</p>
  <h2>PM mayor (diésel · compresor · perforadoras y empernadoras)</h2>
  <p>${resumen(pm)}</p>
  ${tabla(pm)}
  <h2>Rutina de percusión 40 h</h2>
  <p>${resumen(r40)}</p>
  ${tabla(r40)}
  </body></html>`;
  const nombre = `Reporte semanal preventivos ${unidad ?? "todas las unidades"} ${hoyISO()}.pdf`;
  const escritorio = (window as unknown as { appInfo?: AppInfo }).appInfo;
  if (escritorio?.guardarPdf) {
    // App de escritorio: Electron genera el PDF y pregunta dónde guardarlo.
    return escritorio.guardarPdf(html, nombre);
  }
  // Navegador (desarrollo): ventana nueva con el diálogo de impresión.
  const v = window.open("", "_blank");
  if (!v) return null;
  v.document.write(html.replace("</body>", "<script>window.onload = () => setTimeout(() => window.print(), 300);</script></body>"));
  v.document.close();
  return null;
}

interface AppInfo {
  guardarPdf?: (html: string, nombre: string) => Promise<string | null>;
}
