import { useMemo, useState } from "react";
import { useControl40, useControlPm } from "../lib/queries";
import { fFecha, fNum, gamaTexto, hoyISO, sumarDiasISO } from "../../lib/fmt";
import { exportarPrograma, type FilaPrograma } from "../lib/exportar";
import { SISTEMAS } from "../lib/sistemas";
import EstadoBadge from "../components/EstadoBadge";
import EnlaceEquipo from "../components/EnlaceEquipo";
import { EsqueletoTabla } from "../../components/Esqueleto";
import { useNombreUnidad } from "../../lib/unidad";
import type { ControlFila } from "../lib/types";

const SEMANAS = 4;
const DIAS = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];

interface Item {
  fila: ControlFila;
  tipo: "PM mayor" | "Rutina 40 h";
  gama: string;
}

function lunesDe(iso: string) {
  const d = new Date(iso + "T00:00:00");
  return sumarDiasISO(iso, -((d.getDay() + 6) % 7));
}

const esVencido = (f: ControlFila) => f.estado.includes("Vencido");
const porFecha = (a: Item, b: Item) =>
  (a.fila.fecha_estimada ?? "").localeCompare(b.fila.fecha_estimada ?? "") ||
  a.fila.cod_interno.localeCompare(b.fila.cod_interno, "es", { numeric: true });

export default function Programa() {
  const hoy = hoyISO();
  const unidad = useNombreUnidad();
  const inicio = lunesDe(hoy);
  const fin = sumarDiasISO(inicio, SEMANAS * 7 - 1);
  const { data: control, isLoading: c1 } = useControlPm();
  const { data: control40, isLoading: c2 } = useControl40();
  const [vista, setVista] = useState<"lista" | "calendario">("lista");
  const [seccion, setSeccion] = useState(0);

  const { vencidos, semanas } = useMemo(() => {
    const items: Item[] = [
      ...(control ?? []).map((fila) => ({ fila, tipo: "PM mayor" as const, gama: gamaTexto(fila.proxima_gama) })),
      ...(control40 ?? []).map((fila) => ({ fila, tipo: "Rutina 40 h" as const, gama: "40 h" })),
    ].filter((i) => seccion === 0 || i.fila.seccion === seccion);
    const vencidos = items
      .filter((i) => esVencido(i.fila))
      .sort((a, b) => (a.fila.hrs_faltantes ?? 0) - (b.fila.hrs_faltantes ?? 0));
    const semanas = Array.from({ length: SEMANAS }, (_, n) => {
      const desde = sumarDiasISO(inicio, n * 7);
      const hasta = sumarDiasISO(desde, 6);
      return {
        n: n + 1,
        desde,
        hasta,
        items: items
          .filter((i) => !esVencido(i.fila) && i.fila.fecha_estimada && i.fila.fecha_estimada >= desde && i.fila.fecha_estimada <= hasta)
          .sort(porFecha),
      };
    });
    return { vencidos, semanas };
  }, [control, control40, seccion, inicio]);

  const total = semanas.reduce((s, w) => s + w.items.length, 0);

  function exportar() {
    const fila = (grupo: string, i: Item): FilaPrograma => ({
      grupo,
      fecha: i.fila.fecha_estimada,
      equipo: i.fila.cod_interno,
      componente: i.fila.nombre,
      tipo: i.tipo,
      gama: i.gama,
      meta: i.fila.meta_acum,
      faltantes: i.fila.hrs_faltantes,
      estado: i.fila.estado,
    });
    exportarPrograma(
      [
        ...vencidos.map((i) => fila("Vencidos", i)),
        ...semanas.flatMap((w) => w.items.map((i) => fila(`Semana ${w.n} (${fFecha(w.desde)} al ${fFecha(w.hasta)})`, i))),
      ],
      `Programa 4 semanas ${unidad ? unidad + " " : ""}${hoy}.xlsx`
    );
  }

  if (c1 || c2) return <EsqueletoTabla />;

  return (
    <>
      <h1>Programa de mantenimiento · 4 semanas</h1>
      <p className="subtitulo">
        {unidad ?? "Todas las unidades"} · del {fFecha(inicio)} al {fFecha(fin)} según la fecha estimada del Control PM y la rutina de 40 h ·{" "}
        {vencidos.length} vencido(s) y {total} programado(s)
      </p>
      <div className="barra-acciones">
        <div className="selector-vista">
          <button className={vista === "lista" ? "activo" : ""} onClick={() => setVista("lista")}>
            Lista
          </button>
          <button className={vista === "calendario" ? "activo" : ""} onClick={() => setVista("calendario")}>
            Calendario
          </button>
        </div>
        <select style={{ width: 230 }} value={seccion} onChange={(e) => setSeccion(Number(e.target.value))}>
          <option value={0}>Todos los sistemas</option>
          {SISTEMAS.map((s) => (
            <option key={s.seccion} value={s.seccion}>
              {s.pestania}
            </option>
          ))}
        </select>
        <div className="espacio" />
        <button className="boton-secundario" onClick={exportar}>
          Exportar a Excel
        </button>
      </div>

      {vista === "lista" ? (
        <>
          <TablaGrupo titulo={`Vencidos · ${vencidos.length}`} items={vencidos} clase="titulo-vencidos" />
          {semanas.map((w) => (
            <TablaGrupo
              key={w.n}
              titulo={`Semana ${w.n} · ${fFecha(w.desde)} al ${fFecha(w.hasta)} · ${w.items.length}`}
              items={w.items}
            />
          ))}
        </>
      ) : (
        <Calendario inicio={inicio} hoy={hoy} vencidos={vencidos} semanas={semanas} />
      )}
    </>
  );
}

function TablaGrupo({ titulo, items, clase = "" }: { titulo: string; items: Item[]; clase?: string }) {
  return (
    <div className="grupo-programa">
      <div className={`titulo-tabla ${clase}`}>{titulo}</div>
      {items.length === 0 ? (
        <p className="nota grupo-vacio">Sin mantenimientos en este periodo.</p>
      ) : (
        <div className="tabla-marco">
          <table>
            <thead>
              <tr>
                <th style={{ width: 110 }}>Fecha estimada</th>
                <th style={{ width: 130 }}>Equipo</th>
                <th>Componente</th>
                <th style={{ width: 100 }}>Tipo</th>
                <th className="num" style={{ width: 70 }}>Gama</th>
                <th className="num" style={{ width: 110 }}>Meta (acum.)</th>
                <th className="num" style={{ width: 110 }}>Hrs faltantes</th>
                <th style={{ width: 150 }}>Estado</th>
              </tr>
            </thead>
            <tbody>
              {items.map((i) => (
                <tr key={`${i.tipo}-${i.fila.componente_id}`}>
                  <td>{fFecha(i.fila.fecha_estimada)}</td>
                  <td>
                    <EnlaceEquipo componenteId={i.fila.componente_id} texto={i.fila.cod_interno} />
                  </td>
                  <td>{i.fila.nombre}</td>
                  <td>{i.tipo}</td>
                  <td className="num">{i.gama}</td>
                  <td className="num">{fNum(i.fila.meta_acum, 0)}</td>
                  <td className="num">{fNum(i.fila.hrs_faltantes)}</td>
                  <td>
                    <EstadoBadge estado={i.fila.estado} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function Calendario({
  inicio,
  hoy,
  vencidos,
  semanas,
}: {
  inicio: string;
  hoy: string;
  vencidos: Item[];
  semanas: { n: number; items: Item[] }[];
}) {
  const todos = semanas.flatMap((w) => w.items);
  return (
    <>
      {vencidos.length > 0 && (
        <div className="cal-vencidos">
          <span className="cal-vencidos-titulo">Vencidos · {vencidos.length}</span>
          {vencidos.map((i) => (
            <Ficha key={`${i.tipo}-${i.fila.componente_id}`} i={i} />
          ))}
        </div>
      )}
      <div className="calendario">
        {DIAS.map((d) => (
          <div key={d} className="cal-dia-nombre">
            {d}
          </div>
        ))}
        {Array.from({ length: SEMANAS * 7 }, (_, k) => {
          const dia = sumarDiasISO(inicio, k);
          const delDia = todos.filter((i) => i.fila.fecha_estimada === dia);
          return (
            <div key={dia} className={`cal-celda ${dia === hoy ? "hoy" : ""} ${dia < hoy ? "pasado" : ""}`}>
              <div className="cal-fecha">{fFecha(dia).slice(0, 5)}</div>
              {delDia.map((i) => (
                <Ficha key={`${i.tipo}-${i.fila.componente_id}`} i={i} />
              ))}
            </div>
          );
        })}
      </div>
      <p className="nota" style={{ marginTop: 8 }}>
        Cada tarjeta es un PM: equipo y gama. Las de borde punteado son rutina de 40 h. Pase el mouse para ver el
        componente y las horas faltantes.
      </p>
    </>
  );
}

function Ficha({ i }: { i: Item }) {
  const f = i.fila;
  const clase = f.estado.includes("Vencido")
    ? "vencido"
    : f.estado.includes("Programar")
      ? "programar"
      : f.estado.includes("repuestos")
        ? "repuestos"
        : "normal";
  return (
    <div
      className={`cal-pm ${clase} ${i.tipo === "Rutina 40 h" ? "r40" : ""}`}
      title={`${f.cod_interno} · ${f.nombre}\n${i.tipo} gama ${i.gama} · meta ${fNum(f.meta_acum, 0)} h · faltan ${fNum(f.hrs_faltantes)} h`}
    >
      <EnlaceEquipo componenteId={f.componente_id} texto={f.cod_interno} />
      <span className="cal-gama">{i.gama === "Validar gama" ? "Validar" : i.gama}</span>
    </div>
  );
}
