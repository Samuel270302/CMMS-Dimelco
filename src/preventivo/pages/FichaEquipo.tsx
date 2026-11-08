import { useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../auth";
import {
  useComponentes,
  useControl40,
  useControlPm,
  useEquipos,
  useLecturasDesde,
  usePlanes,
  usePmDesde,
} from "../lib/queries";
import { fFecha, fNum, gamaTexto, hoyISO, sumarDiasISO } from "../../lib/fmt";
import EstadoBadge from "../components/EstadoBadge";
import GraficaHorometro, { type PuntoHorometro } from "../components/GraficaHorometro";
import EditorEquipo from "../components/EditorEquipo";
import { EsqueletoTabla } from "../../components/Esqueleto";
import type { ControlFila, LecturaCalc } from "../lib/types";

const VENTANA_DIAS = 30;

interface PmFicha {
  id: string;
  componente_id: string;
  fecha: string;
  gama: number | null;
  lectura: number | null;
  lectura_acum: number | null;
  responsable: string | null;
}

export default function FichaEquipo() {
  const { id = "" } = useParams();
  const { esAdmin } = useAuth();
  const hasta = hoyISO();
  const desde = sumarDiasISO(hasta, -VENTANA_DIAS);
  const { data: equipos, isLoading } = useEquipos();
  const { data: componentes } = useComponentes();
  const { data: planes } = usePlanes();
  const { data: control } = useControlPm();
  const { data: control40 } = useControl40();
  const { data: lecturas30 } = useLecturasDesde(desde);
  const { data: pms30 } = usePmDesde(desde);
  const [editando, setEditando] = useState(false);

  const equipo = (equipos ?? []).find((e) => e.id === id);
  const comps = useMemo(
    () =>
      (componentes ?? [])
        .filter((c) => c.equipo_id === id)
        .sort((a, b) => a.seccion - b.seccion || a.tipo_horometro.localeCompare(b.tipo_horometro)),
    [componentes, id]
  );
  const ids = comps.map((c) => c.id);
  const nombreComp = new Map(comps.map((c) => [c.id, c.nombre]));

  const historialPm = useQuery({
    queryKey: ["prev:ficha-pm", id, ids.join()],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase()
        .from("v_registros_pm")
        .select("id,componente_id,fecha,gama,lectura,lectura_acum,responsable")
        .in("componente_id", ids)
        .order("fecha", { ascending: false })
        .limit(15);
      if (error) throw error;
      return data as PmFicha[];
    },
  });

  const ultimasLecturas = useQuery({
    queryKey: ["prev:ficha-lecturas", id, ids.join()],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase()
        .from("v_lecturas")
        .select("*")
        .in("componente_id", ids)
        .order("num_turno", { ascending: false })
        .limit(20);
      if (error) throw error;
      return data as LecturaCalc[];
    },
  });

  if (isLoading) return <EsqueletoTabla />;
  if (!equipo)
    return (
      <>
        <h1>Equipo no encontrado</h1>
        <p className="subtitulo">
          <Link to="/preventivo/control">Volver al Control PM</Link>
        </p>
      </>
    );

  const puntosDe = (compId: string): PuntoHorometro[] =>
    (lecturas30 ?? [])
      .filter((l) => l.componente_id === compId)
      .sort((a, b) => a.num_turno - b.num_turno)
      .map((l) => ({ fecha: l.fecha, turno: l.turno, acumulado: Number(l.lectura_acum), contador: Number(l.lectura) }));

  return (
    <>
      {editando && (
        <EditorEquipo
          equipo={equipo}
          componentes={comps}
          planes={planes ?? []}
          onCerrar={() => setEditando(false)}
        />
      )}
      <div className="barra-acciones" style={{ marginBottom: 4 }}>
        <h1 style={{ margin: 0 }}>{equipo.cod_interno}</h1>
        {!equipo.activo && <span className="estado sindatos">Inactivo</span>}
        <div className="espacio" />
        {esAdmin && (
          <button className="boton-secundario" onClick={() => setEditando(true)}>
            Editar equipo
          </button>
        )}
      </div>
      <p className="subtitulo">
        {equipo.modelo} · Cód. interno {equipo.cod_sap ?? "sin código"}
        {equipo.fecha_inicio_operacion && ` · en operación desde ${fFecha(equipo.fecha_inicio_operacion)}`} ·{" "}
        {comps.length} componente(s)
      </p>

      <div className="rejilla-ficha">
        {comps.map((c) => {
          const f = (control ?? []).find((x) => x.componente_id === c.id);
          const r40 = (control40 ?? []).find((x) => x.componente_id === c.id);
          const puntos = puntosDe(c.id);
          return (
            <section className="tarjeta-ficha" key={c.id}>
              <div className="tg-cabecera">
                <div>
                  <div className="tg-equipo">{c.nombre}</div>
                  <div className="tg-componente">
                    {c.tipo_horometro} · plan {c.plan_clave ?? "sin plan"}
                    {!c.activo && " · inactivo"}
                  </div>
                </div>
                {f && <EstadoBadge estado={f.estado} />}
              </div>
              {f ? <DatosControl f={f} /> : <p className="nota">Sin fila en el Control PM.</p>}
              {r40 && (
                <div className="ficha-40">
                  <span>Rutina 40 h</span>
                  <EstadoBadge estado={r40.estado} />
                  <span className="nota">
                    {r40.hrs_faltantes !== null ? `${fNum(r40.hrs_faltantes)} h faltantes` : "Sin dato"}
                  </span>
                </div>
              )}
              {puntos.length >= 2 ? (
                <GraficaHorometro
                  puntos={puntos}
                  desde={desde}
                  hasta={hasta}
                  meta={f?.meta_acum ?? null}
                  pms={(pms30 ?? []).filter((p) => p.componente_id === c.id)}
                />
              ) : (
                <div className="tg-vacia">
                  {puntos.length === 1 ? "Solo 1 lectura en los últimos 30 días" : "Sin lecturas en los últimos 30 días"}
                </div>
              )}
            </section>
          );
        })}
      </div>

      <div className="fila-tablas-ficha">
        <div>
          <div className="titulo-tabla">Últimos mantenimientos</div>
          <div className="tabla-marco">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Componente</th>
                  <th className="num">Gama</th>
                  <th className="num">Acumulado</th>
                  <th>Responsable</th>
                </tr>
              </thead>
              <tbody>
                {(historialPm.data ?? []).map((p) => (
                  <tr key={p.id}>
                    <td>{fFecha(p.fecha)}</td>
                    <td>{nombreComp.get(p.componente_id)}</td>
                    <td className="num">{p.gama === null ? "Sin gama" : p.gama === 40 ? "40 h" : gamaTexto(p.gama)}</td>
                    <td className="num">{fNum(p.lectura_acum)}</td>
                    <td>{p.responsable}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {historialPm.data?.length === 0 && <p className="nota">Sin mantenimientos registrados.</p>}
          </div>
        </div>
        <div>
          <div className="titulo-tabla">Últimas lecturas</div>
          <div className="tabla-marco">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Turno</th>
                  <th>Componente</th>
                  <th className="num">Lectura</th>
                  <th className="num">Horas</th>
                  <th>Control</th>
                </tr>
              </thead>
              <tbody>
                {(ultimasLecturas.data ?? []).map((l) => (
                  <tr key={l.id}>
                    <td>{fFecha(l.fecha)}</td>
                    <td>{l.turno}</td>
                    <td>{nombreComp.get(l.componente_id)}</td>
                    <td className="num">{fNum(l.lectura)}</td>
                    <td className="num">{fNum(l.horas_intervalo)}</td>
                    <td>
                      <span className={l.control === "OK" ? "control-ok" : "control-aviso"}>{l.control}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {ultimasLecturas.data?.length === 0 && <p className="nota">Sin lecturas registradas.</p>}
          </div>
        </div>
      </div>
    </>
  );
}

function DatosControl({ f }: { f: ControlFila }) {
  const datos: [string, string][] = [
    ["Horómetro actual", f.ultima_lectura_acum !== null ? `${fNum(f.ultima_lectura_acum)} h` : "Sin dato"],
    ["Contador", f.ultima_lectura_contador !== null ? `${fNum(f.ultima_lectura_contador)} h` : "Sin dato"],
    ["Última lectura", f.fecha_ultima_lectura ? fFecha(f.fecha_ultima_lectura) : "Sin dato"],
    [
      "Último PM",
      f.fecha_ultimo_pm
        ? `${fFecha(f.fecha_ultimo_pm)} · gama ${gamaTexto(f.gama_ultimo_pm)} · ${fNum(f.horometro_ultimo_pm)} h`
        : "Sin dato",
    ],
    ["Próxima gama", f.proxima_gama !== null ? `${gamaTexto(f.proxima_gama)} a ${fNum(f.meta_acum, 0)} h` : "Sin dato"],
    ["Horas faltantes", f.hrs_faltantes !== null ? `${fNum(f.hrs_faltantes)} h` : "Sin dato"],
    ["Tendencia", f.tendencia !== null ? `${fNum(f.tendencia, 1)} h/día` : "Sin dato"],
    ["Fecha estimada", f.fecha_estimada ? fFecha(f.fecha_estimada) : "Sin dato"],
  ];
  return (
    <dl className="datos-ficha">
      {datos.map(([k, v]) => (
        <div key={k}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
      {f.observacion && (
        <div className="datos-ficha-obs">
          <dt>Observación</dt>
          <dd>{f.observacion}</dd>
        </div>
      )}
    </dl>
  );
}
