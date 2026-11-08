import EnlaceEquipo from "./EnlaceEquipo";
import { useMemo, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import type { ColumnaControl, ControlFila } from "../lib/types";
import { fFecha, fNum, gamaTexto } from "../../lib/fmt";
import EstadoBadge from "./EstadoBadge";
import { exportarControl, type ColumnaExcel } from "../lib/exportar";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../auth";
import { useColumnas } from "../lib/queries";
import { useAvisos } from "../../components/Avisos";

const GRUPOS: [string, string[], string][] = [
  ["vencido", ["🔴 Vencido"], "Vencidos"],
  ["programar", ["📅 Programar"], "Programar"],
  ["repuestos", ["🔧 Verificar repuestos"], "Verificar repuestos"],
  ["normal", ["🟢 Normal"], "Normal"],
  ["sindatos", ["⚪ Sin PM registrado", "⚪ Sin lecturas", "⚪ Sin tendencia"], "Sin datos"],
];

const CLASE_ESTADO: Record<string, string> = {
  "🔴 Vencido": "fila-vencido",
  "📅 Programar": "fila-programar",
  "🔧 Verificar repuestos": "fila-repuestos",
  "🟢 Normal": "fila-normal",
};

// Orden de severidad para ordenar por la columna Estado.
const RANGO_ESTADO: Record<string, number> = {
  "🔴 Vencido": 0,
  "📅 Programar": 1,
  "🔧 Verificar repuestos": 2,
  "🟢 Normal": 3,
};

type Valor = string | number | null;

export interface DefColumna {
  num: boolean;
  render: (f: ControlFila) => React.ReactNode;
  valor: (f: ControlFila) => Valor; // para ordenar y exportar
  fecha?: boolean;
  ancho?: number;
}

const numero = (v: number | string | null | undefined): number | null =>
  v === null || v === undefined || v === "" || isNaN(Number(v)) ? null : Number(v);

export const COLUMNAS: Record<string, DefColumna> = {
  nombre: { num: false, render: (f) => f.nombre, valor: (f) => f.nombre },
  cod_sap: { num: false, render: (f) => f.cod_sap ?? "Sin cód. interno", valor: (f) => f.cod_sap ?? "Sin cód. interno" },
  modelo: { num: false, render: (f) => f.modelo, valor: (f) => f.modelo },
  fecha_ultimo_pm: { num: false, fecha: true, render: (f) => fFecha(f.fecha_ultimo_pm), valor: (f) => f.fecha_ultimo_pm },
  gama_ultimo_pm: {
    num: true,
    render: (f) => f.gama_ultimo_pm ?? (f.fecha_ultimo_pm ? "Sin gama" : ""),
    valor: (f) => f.gama_ultimo_pm ?? (f.fecha_ultimo_pm ? "Sin gama" : null),
  },
  horometro_ultimo_pm: { num: true, render: (f) => fNum(f.horometro_ultimo_pm), valor: (f) => numero(f.horometro_ultimo_pm) },
  proxima_gama: {
    num: true,
    render: (f) => gamaTexto(f.proxima_gama),
    valor: (f) => numero(f.proxima_gama) ?? (f.proxima_gama as string | null),
  },
  meta_acum: { num: true, render: (f) => fNum(f.meta_acum), valor: (f) => numero(f.meta_acum) },
  meta_contador: { num: true, render: (f) => fNum(f.meta_contador), valor: (f) => numero(f.meta_contador) },
  ultima_lectura_acum: { num: true, render: (f) => fNum(f.ultima_lectura_acum), valor: (f) => numero(f.ultima_lectura_acum) },
  ultima_lectura_contador: {
    num: true,
    render: (f) => fNum(f.ultima_lectura_contador),
    valor: (f) => numero(f.ultima_lectura_contador),
  },
  fecha_ultima_lectura: {
    num: false, fecha: true,
    render: (f) =>
      `${fFecha(f.fecha_ultima_lectura)}${
        f.antiguedad_dias != null && f.antiguedad_dias > 2 ? ` (${f.antiguedad_dias} d)` : ""
      }`,
    valor: (f) => f.fecha_ultima_lectura,
  },
  hrs_faltantes: { num: true, render: (f) => fNum(f.hrs_faltantes), valor: (f) => numero(f.hrs_faltantes) },
  tendencia: { num: true, render: (f) => fNum(f.tendencia, 2), valor: (f) => numero(f.tendencia) },
  dias_restantes: { num: true, render: (f) => f.dias_restantes ?? "", valor: (f) => numero(f.dias_restantes) },
  fecha_estimada: { num: false, fecha: true, render: (f) => fFecha(f.fecha_estimada), valor: (f) => f.fecha_estimada },
  estado: {
    num: false,
    render: (f) => <EstadoBadge estado={f.estado} />,
    valor: (f) => f.estado,
  },
  observacion: {
    num: false,
    render: (f) =>
      f.observacion ? (
        <span className="aviso-obs" title={f.observacion}>
          {f.observacion}
        </span>
      ) : null,
    valor: (f) => f.observacion || null,
  },
};

function comparar(a: Valor, b: Valor, columna: string): number {
  if (columna === "estado") return (RANGO_ESTADO[a as string] ?? 9) - (RANGO_ESTADO[b as string] ?? 9);
  if (a === null && b === null) return 0;
  if (a === null) return 1; // vacíos siempre al final
  if (b === null) return -1;
  if (typeof a === "number" && typeof b === "number") return a - b;
  return String(a).localeCompare(String(b), "es", { numeric: true });
}

export default function ControlTabla({
  filas,
  titulo,
  archivo,
}: {
  filas: ControlFila[];
  titulo: string;
  archivo: string;
}) {
  const { esAdmin } = useAuth();
  const { data: columnas } = useColumnas();
  const [filtro, setFiltro] = useState<string | null>(null);
  const [buscar, setBuscar] = useState("");
  const [orden, setOrden] = useState<{ columna: string; asc: boolean } | null>(null);
  const dialogo = useRef<HTMLDialogElement>(null);

  const colsActivas = useMemo(
    () =>
      (columnas ?? [])
        .filter((c) => c.visible && COLUMNAS[c.columna])
        .sort((a, b) => a.orden - b.orden),
    [columnas]
  );

  const visibles = useMemo(() => {
    let v = filas;
    if (filtro) {
      const grupo = GRUPOS.find(([k]) => k === filtro);
      if (grupo) v = v.filter((f) => grupo[1].includes(f.estado));
    }
    if (buscar.trim()) {
      const b = buscar.trim().toLowerCase();
      v = v.filter(
        (f) =>
          f.cod_interno.toLowerCase().includes(b) ||
          f.nombre.toLowerCase().includes(b) ||
          f.modelo.toLowerCase().includes(b)
      );
    }
    if (orden) {
      const valor =
        orden.columna === "equipo" ? (f: ControlFila) => f.cod_interno : COLUMNAS[orden.columna].valor;
      v = v.slice().sort((a, b) => {
        const va = valor(a);
        const vb = valor(b);
        if (va === null || vb === null) return comparar(va, vb, orden.columna);
        return (orden.asc ? 1 : -1) * comparar(va, vb, orden.columna);
      });
    }
    return v;
  }, [filas, filtro, buscar, orden]);

  function ordenarPor(columna: string) {
    setOrden((o) =>
      o?.columna !== columna ? { columna, asc: true } : o.asc ? { columna, asc: false } : null
    );
  }

  const columnasExcel: ColumnaExcel[] = [
    { etiqueta: "Equipo", valor: (f) => f.cod_interno, ancho: 16 },
    ...colsActivas.map((c) => {
      const def = COLUMNAS[c.columna];
      return {
        etiqueta: c.etiqueta,
        valor: def.fecha ? (f: ControlFila) => fFecha(def.valor(f) as string | null) : def.valor,
        ancho: c.columna === "observacion" ? 42 : c.columna === "nombre" ? 30 : Math.max(11, c.etiqueta.length + 2),
        esEstado: c.columna === "estado",
      };
    }),
  ];

  const hayFiltros = filtro !== null || buscar.trim() !== "" || orden !== null;

  function encabezado(columna: string, etiqueta: string, num: boolean) {
    const activa = orden?.columna === columna;
    return (
      <th
        key={columna}
        className={`ordenable ${num ? "num" : ""} ${columna === "equipo" ? "col-fija" : ""}`}
        onClick={() => ordenarPor(columna)}
        title="Clic para ordenar"
      >
        {etiqueta}
        <span className={`flecha-orden ${activa ? "activa" : ""}`}>
          {activa ? (orden!.asc ? "▲" : "▼") : "↕"}
        </span>
      </th>
    );
  }

  return (
    <>
      <div className="resumen">
        {GRUPOS.map(([clase, estados, texto]) => {
          const n = filas.filter((f) => estados.includes(f.estado)).length;
          return (
            <div
              key={clase}
              className={`chip ${clase} ${filtro === clase ? "activo" : ""}`}
              onClick={() => setFiltro(filtro === clase ? null : clase)}
            >
              <span className="n">{n}</span>
              <span className="t">{texto}</span>
            </div>
          );
        })}
      </div>
      <div className="barra-acciones">
        <input
          style={{ width: 260 }}
          placeholder="Buscar equipo, componente o modelo…"
          value={buscar}
          onChange={(e) => setBuscar(e.target.value)}
        />
        {hayFiltros && (
          <button
            className="boton-plano"
            onClick={() => {
              setFiltro(null);
              setBuscar("");
              setOrden(null);
            }}
          >
            Quitar filtros
          </button>
        )}
        <div className="espacio" />
        {esAdmin && (
          <button className="boton-plano" onClick={() => dialogo.current?.showModal()}>
            Columnas
          </button>
        )}
        <button
          className="boton-secundario"
          onClick={() => exportarControl(visibles, titulo, archivo, columnasExcel)}
        >
          Exportar a Excel
        </button>
      </div>
      <div className="titulo-tabla">{titulo}</div>
      <div className="tabla-marco">
        <table className="tabla-control">
          <thead>
            <tr>
              {encabezado("equipo", "Equipo", false)}
              {colsActivas.map((c) => encabezado(c.columna, c.etiqueta, COLUMNAS[c.columna].num))}
            </tr>
          </thead>
          <tbody>
            {visibles.map((f) => (
              <tr key={f.componente_id} className={CLASE_ESTADO[f.estado] ?? "fila-sindatos"}>
                <td className="col-fija">
                  <EnlaceEquipo componenteId={f.componente_id} texto={f.cod_interno} />
                </td>
                {colsActivas.map((c) => (
                  <td key={c.columna} className={COLUMNAS[c.columna].num ? "num" : ""}>
                    {COLUMNAS[c.columna].render(f)}
                  </td>
                ))}
              </tr>
            ))}
            {visibles.length === 0 && (
              <tr>
                <td
                  colSpan={colsActivas.length + 1}
                  style={{ textAlign: "center", color: "var(--texto-suave)" }}
                >
                  Sin filas para el filtro actual
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {esAdmin && <ColumnasDialog dialogoRef={dialogo} columnas={columnas ?? []} />}
    </>
  );
}

function ColumnasDialog({
  dialogoRef,
  columnas,
}: {
  dialogoRef: React.RefObject<HTMLDialogElement>;
  columnas: ColumnaControl[];
}) {
  const qc = useQueryClient();
  const { avisar } = useAvisos();
  const lista = columnas.slice().sort((a, b) => a.orden - b.orden);

  const guardar = useMutation({
    mutationFn: async (cambios: { columna: string; visible?: boolean; orden?: number }[]) => {
      for (const { columna, ...valores } of cambios) {
        const { error } = await supabase().from("columnas_control").update(valores).eq("columna", columna);
        if (error) throw error;
      }
    },
    onMutate: (cambios) => {
      qc.setQueryData<ColumnaControl[]>(["columnas_control"], (viejas) =>
        (viejas ?? []).map((c) => {
          const cambio = cambios.find((x) => x.columna === c.columna);
          return cambio ? { ...c, ...cambio } : c;
        })
      );
    },
    onError: (e: Error) => avisar(`No se pudo guardar la configuración: ${e.message}`, "error"),
    onSettled: () => qc.invalidateQueries({ queryKey: ["prev:columnas_control"] }),
  });

  function mover(i: number, delta: number) {
    const j = i + delta;
    if (j < 0 || j >= lista.length) return;
    guardar.mutate([
      { columna: lista[i].columna, orden: lista[j].orden },
      { columna: lista[j].columna, orden: lista[i].orden },
    ]);
  }

  return (
    <dialog ref={dialogoRef}>
      <h1 style={{ fontSize: 16 }}>Columnas del control</h1>
      <p className="nota">
        Marca las columnas visibles y ordénalas con las flechas. Aplica a todos los usuarios, en
        Control PM, Rutina 40 h y en la exportación a Excel. Equipo siempre va primero y fija.
      </p>
      <div className="lista-orden">
        {lista.map((c, i) => (
          <div className="fila-orden" key={c.columna}>
            <label>
              <input
                type="checkbox"
                checked={c.visible}
                onChange={(e) => guardar.mutate([{ columna: c.columna, visible: e.target.checked }])}
              />
              {c.etiqueta}
            </label>
            <div className="flechas">
              <button className="boton-plano" disabled={i === 0} onClick={() => mover(i, -1)} title="Subir">
                ▲
              </button>
              <button
                className="boton-plano"
                disabled={i === lista.length - 1}
                onClick={() => mover(i, 1)}
                title="Bajar"
              >
                ▼
              </button>
            </div>
          </div>
        ))}
      </div>
      <div className="barra-acciones" style={{ marginBottom: 0, marginTop: 12 }}>
        <div className="espacio" />
        <button onClick={() => dialogoRef.current?.close()}>Cerrar</button>
      </div>
    </dialog>
  );
}
