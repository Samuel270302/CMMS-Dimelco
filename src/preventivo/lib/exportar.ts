import ExcelJS from "exceljs";
import type { ControlFila, LecturaCalc, RegistroPm } from "./types";
import { fFecha } from "../../lib/fmt";

interface AppEscritorio {
  guardarArchivo?: (datos: Uint8Array, nombre: string) => Promise<string | null>;
}

async function descargar(buf: ArrayBuffer, nombre: string) {
  const escritorio = (window as unknown as { appInfo?: AppEscritorio }).appInfo;
  if (escritorio?.guardarArchivo) {
    await escritorio.guardarArchivo(new Uint8Array(buf), nombre);
    return;
  }
  const blob = new Blob([buf], {
    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  });
  // Navegador: el enlace va dentro de la página y el nombre sin acentos; con acentos
  // Chrome puede descartar el nombre y guardar el archivo como "download".
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = nombre.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  a.style.display = "none";
  document.body.appendChild(a);
  a.click();
  setTimeout(() => {
    URL.revokeObjectURL(a.href);
    a.remove();
  }, 1000);
}

const COLOR_ESTADO: Record<string, string> = {
  "🔴 Vencido": "FFFFC7CE",
  "📅 Programar": "FFBDD7EE",
  "🔧 Verificar repuestos": "FFFFE699",
  "🟢 Normal": "FFC6EFCE",
};

export interface ColumnaExcel {
  etiqueta: string;
  valor: (f: ControlFila) => string | number | null;
  ancho: number;
  esEstado?: boolean;
}

// Las columnas llegan ya filtradas y ordenadas como las definió el administrador.
export async function exportarControl(
  filas: ControlFila[],
  titulo: string,
  nombreArchivo: string,
  columnas: ColumnaExcel[]
) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet(titulo.replace(/[\\/?*[\]:]/g, " ").slice(0, 31));
  ws.columns = columnas.map((c) => ({ header: c.etiqueta, width: c.ancho }));
  ws.getRow(1).font = { bold: true };
  const colEstado = columnas.findIndex((c) => c.esEstado) + 1;
  for (const f of filas) {
    const fila = ws.addRow(columnas.map((c) => c.valor(f)));
    const color = COLOR_ESTADO[f.estado];
    if (colEstado > 0 && color) {
      fila.getCell(colEstado).fill = { type: "pattern", pattern: "solid", fgColor: { argb: color } };
      fila.getCell(colEstado).font = { color: { argb: "FF1F1F1F" } };
    }
  }
  await descargar(await wb.xlsx.writeBuffer(), nombreArchivo);
}

// Datos de auditoría que el Historial agrega a cada fila exportada.
export interface Auditoria {
  capturado: string;
  anuladoPor?: string;
  anuladoEn?: string;
  motivo?: string | null;
}

const COLUMNAS_ANULACION = [
  { header: "Anulado por", width: 22 },
  { header: "Anulado el", width: 17 },
  { header: "Motivo", width: 40 },
];

export async function exportarLecturas(
  filas: (Partial<LecturaCalc> & Pick<LecturaCalc, "fecha" | "turno" | "lectura"> &
    Auditoria & { equipo: string; tipo: string })[],
  nombreArchivo: string,
  anuladas = false
) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet(anuladas ? "Lecturas anuladas" : "Lecturas");
  ws.columns = [
    { header: "Fecha", width: 12 },
    { header: "Equipo", width: 16 },
    { header: "Turno", width: 8 },
    { header: "Tipo de Horómetro", width: 16 },
    { header: "Lectura", width: 11 },
    ...(anuladas
      ? []
      : [
          { header: "Acumulado", width: 11 },
          { header: "Horas del Intervalo", width: 11 },
          { header: "Control", width: 26 },
        ]),
    { header: "Capturado por", width: 22 },
    ...(anuladas ? COLUMNAS_ANULACION : []),
  ];
  ws.getRow(1).font = { bold: true };
  for (const f of filas)
    ws.addRow([
      fFecha(f.fecha),
      f.equipo,
      f.turno,
      f.tipo,
      f.lectura,
      ...(anuladas ? [] : [f.lectura_acum, f.horas_intervalo, f.control]),
      f.capturado,
      ...(anuladas ? [f.anuladoPor, f.anuladoEn, f.motivo] : []),
    ]);
  await descargar(await wb.xlsx.writeBuffer(), nombreArchivo);
}

export async function exportarRegistrosPm(
  filas: (RegistroPm & Auditoria & { equipo: string; tipo: string; clase: string })[],
  nombreArchivo: string,
  anulados = false
) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet(anulados ? "Registro PM anulados" : "Registro PM");
  ws.columns = [
    { header: "Fecha", width: 12 },
    { header: "Equipo", width: 16 },
    { header: "Tipo de Horómetro", width: 16 },
    { header: "Gama", width: 8 },
    { header: "Lectura", width: 11 },
    { header: "Clase", width: 12 },
    { header: "Responsable", width: 22 },
    { header: "Capturado por", width: 22 },
    ...(anulados ? COLUMNAS_ANULACION : []),
  ];
  ws.getRow(1).font = { bold: true };
  for (const f of filas)
    ws.addRow([
      fFecha(f.fecha),
      f.equipo,
      f.tipo,
      f.gama,
      f.lectura,
      f.clase,
      f.responsable,
      f.capturado,
      ...(anulados ? [f.anuladoPor, f.anuladoEn, f.motivo] : []),
    ]);
  await descargar(await wb.xlsx.writeBuffer(), nombreArchivo);
}

export interface FilaPrograma {
  grupo: string;
  fecha: string | null;
  equipo: string;
  componente: string;
  tipo: string;
  gama: string;
  meta: number | null;
  faltantes: number | null;
  estado: string;
}

export async function exportarPrograma(filas: FilaPrograma[], nombreArchivo: string) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet("Programa 4 semanas");
  ws.columns = [
    { header: "Semana", width: 26 },
    { header: "Fecha estimada", width: 14 },
    { header: "Equipo", width: 16 },
    { header: "Componente", width: 34 },
    { header: "Tipo", width: 12 },
    { header: "Gama", width: 9 },
    { header: "Meta (acum.)", width: 12 },
    { header: "Hrs faltantes", width: 12 },
    { header: "Estado", width: 20 },
  ];
  ws.getRow(1).font = { bold: true };
  for (const f of filas) {
    const fila = ws.addRow([f.grupo, fFecha(f.fecha), f.equipo, f.componente, f.tipo, f.gama, f.meta, f.faltantes, f.estado]);
    const color = COLOR_ESTADO[f.estado];
    if (color) fila.getCell(9).fill = { type: "pattern", pattern: "solid", fgColor: { argb: color } };
  }
  await descargar(await wb.xlsx.writeBuffer(), nombreArchivo);
}
