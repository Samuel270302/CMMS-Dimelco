import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../auth";
import { useBacklogs, useCapacidadVigente, useEquipos, useEspecialidades, useFamilias } from "../lib/queries";
import { useDetalleBacklogs } from "../lib/backlog";
import { useDialogoMotivo } from "../components/DialogoMotivo";
import { EtiquetaPrioridad } from "../components/Etiquetas";
import { fFecha, fNum, hoyISO, lunesDe, sumarDiasISO } from "../lib/fmt";
import { useComponentes, useControl40, useControlPm } from "../preventivo/lib/queries";
import type { BacklogFila } from "../lib/types";
import {
  hhDePauta,
  useAccionesOt,
  useBacklogsEnOt,
  useEventosOt,
  useOtHh,
  useOtsSemana,
  usePautas,
  usePmConOt,
  type Ot,
  type TipoOt,
  type Turno,
} from "./datos";

// Tablero de programación: equipos por día y turno, con los PM sugeridos por Control PM
// y los backlogs listos para programar en la columna lateral. Se programa arrastrando;
// cada movimiento llama a una función de la base, que valida y deja la bitácora.
const DIAS = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];
const TURNOS: Turno[] = ["Dia", "Noche"];
const NOMBRE_TURNO: Record<Turno, string> = { Dia: "Día", Noche: "Noche" };
const CLASE_TIPO: Record<TipoOt, string> = {
  Preventiva: "t-preventiva",
  "Rutina 40 h": "t-rutina",
  Correctiva: "t-correctiva",
  Emergencia: "t-emergencia",
};
// PM que se sugieren: los que Control PM marca para actuar o vencen hasta 14 días
// después de la semana que se mira.
const HORIZONTE_DIAS = 14;

interface Sugerido {
  clave: string;
  componente_id: string;
  equipo_id: string;
  cod_interno: string;
  nombre: string;
  tipo: "Preventiva" | "Rutina 40 h";
  gama: string;
  fecha_estimada: string | null;
  estado: string;
  hh: number;
}

type Item = { k: "pm"; s: Sugerido } | { k: "bl"; b: BacklogFila } | { k: "ot"; o: Ot };
const equipoDe = (i: Item) => (i.k === "pm" ? i.s.equipo_id : i.k === "bl" ? i.b.equipo_id : i.o.equipo_id);

function nivel(uso: number) {
  if (uso > 1) return "excedida";
  if (uso > 0.85) return "alta";
  return "normal";
}

export default function Tablero() {
  const { puedeCapturar } = useAuth();
  const hoy = hoyISO();
  const [lunes, setLunes] = useState(() => lunesDe(hoy));
  const dias = useMemo(() => Array.from({ length: 7 }, (_, i) => sumarDiasISO(lunes, i)), [lunes]);
  const domingo = dias[6];
  const [todos, setTodos] = useState(false);
  const [arrastre, setArrastre] = useState<Item | null>(null);
  const [sobre, setSobre] = useState<string | null>(null);
  const [abierta, setAbierta] = useState<string | null>(null);
  const { pedirMotivo, dialogo } = useDialogoMotivo();
  const acciones = useAccionesOt();

  const { data: ots, isLoading } = useOtsSemana(lunes, domingo);
  const { data: otHh } = useOtHh((ots ?? []).map((o) => o.id));
  const { data: equipos } = useEquipos();
  const { data: familias } = useFamilias();
  const { data: componentes } = useComponentes();
  const { data: controlPm } = useControlPm();
  const { data: control40 } = useControl40();
  const { data: pmConOt } = usePmConOt();
  const { data: enOt } = useBacklogsEnOt();
  const { data: pautas } = usePautas();
  const { data: backlogs } = useBacklogs();
  const { data: especialidades } = useEspecialidades();
  const { data: capacidad } = useCapacidadVigente();

  const backlogEnOt = useMemo(() => new Set((enOt ?? []).map((x) => x.backlog_id)), [enOt]);
  const listos = useMemo(
    () =>
      (backlogs ?? [])
        .filter((b) => b.estado === "Listo para programar")
        .sort((a, b) => a.prioridad.localeCompare(b.prioridad) || (a.dias_para_limite ?? 9999) - (b.dias_para_limite ?? 9999)),
    [backlogs]
  );
  // Programados desde el Calendario de backlog (o la app de backlog) que aún no tienen OT.
  const sinOt = useMemo(
    () =>
      (backlogs ?? []).filter(
        (b) => b.estado === "Programado" && !backlogEnOt.has(b.id) && b.fecha_programada && b.fecha_programada >= lunes && b.fecha_programada <= domingo
      ),
    [backlogs, backlogEnOt, lunes, domingo]
  );
  const { data: detalleSinOt } = useDetalleBacklogs(sinOt.map((b) => b.id));

  const sugeridos = useMemo(() => {
    const equipoDeComp = new Map((componentes ?? []).map((c) => [c.id, c.equipo_id]));
    const conOt = new Set((pmConOt ?? []).map((p) => `${p.componente_id}|${p.tipo}`));
    const limite = sumarDiasISO(domingo, HORIZONTE_DIAS);
    const lista: Sugerido[] = [];
    const agregar = (f: NonNullable<typeof controlPm>[number], tipo: Sugerido["tipo"], plan: string | null) => {
      const equipo = equipoDeComp.get(f.componente_id);
      if (!equipo || conOt.has(`${f.componente_id}|${tipo}`)) return;
      const actuar = /Vencido|Programar|Verificar/.test(f.estado);
      if (!actuar && !(f.fecha_estimada && f.fecha_estimada <= limite)) return;
      const gama = f.proxima_gama === null ? "" : String(f.proxima_gama);
      const hh = [...hhDePauta(pautas, plan, Number(gama) || null).values()].reduce((s, x) => s + x, 0);
      lista.push({
        clave: `${f.componente_id}|${tipo}`, componente_id: f.componente_id, equipo_id: equipo, cod_interno: f.cod_interno,
        nombre: f.nombre, tipo, gama, fecha_estimada: f.fecha_estimada, estado: f.estado, hh,
      });
    };
    for (const f of controlPm ?? []) agregar(f, "Preventiva", (f as { plan_clave?: string | null }).plan_clave ?? null);
    for (const f of control40 ?? []) agregar(f, "Rutina 40 h", "RUTINA-40");
    return lista.sort((a, b) => (a.fecha_estimada ?? "9999").localeCompare(b.fecha_estimada ?? "9999"));
  }, [componentes, pmConOt, controlPm, control40, pautas, domingo]);

  // Filas: equipos con algo que programar o programado en la semana (o todos).
  const filas = useMemo(() => {
    const con = new Set<string>([
      ...(ots ?? []).map((o) => o.equipo_id),
      ...sinOt.map((b) => b.equipo_id),
      ...sugeridos.map((s) => s.equipo_id),
      ...listos.map((b) => b.equipo_id),
    ]);
    const nombreFamilia = new Map((familias ?? []).map((f) => [f.id, f.nombre]));
    const grupos = new Map<string, NonNullable<typeof equipos>>();
    for (const e of equipos ?? []) {
      if (!e.activo || (!todos && !con.has(e.id))) continue;
      const g = (e.familia_id && nombreFamilia.get(e.familia_id)) || e.flota || "Sin familia";
      grupos.set(g, [...(grupos.get(g) ?? []), e]);
    }
    return [...grupos.entries()]
      .sort((a, b) => a[0].localeCompare(b[0], "es"))
      .map(([g, lista]) => [g, lista.sort((a, b) => a.cod_interno.localeCompare(b.cod_interno, "es", { numeric: true }))] as const);
  }, [equipos, familias, ots, sinOt, sugeridos, listos, todos]);

  // Carga de la semana por especialidad: OT (PM + backlogs) y programados sin OT.
  const carga = useMemo(() => {
    const prog = new Map<string, number>();
    const sumar = (esp: string, hh: number) => prog.set(esp, (prog.get(esp) ?? 0) + Number(hh));
    for (const h of otHh ?? []) sumar(h.especialidad_id, h.hh);
    for (const b of sinOt) for (const h of detalleSinOt?.hh.get(b.id) ?? []) if (h.tipo === "estimada") sumar(h.especialidad_id, h.hh);
    const cap = new Map<string, number>();
    for (const c of capacidad ?? []) cap.set(c.especialidad_id, (cap.get(c.especialidad_id) ?? 0) + Number(c.hh_semana));
    return (especialidades ?? [])
      .filter((e) => e.activo || prog.has(e.id))
      .map((e) => ({ id: e.id, nombre: e.nombre, hh: prog.get(e.id) ?? 0, capacidad: cap.get(e.id) ?? 0 }))
      .filter((x) => x.hh > 0 || x.capacidad > 0);
  }, [otHh, sinOt, detalleSinOt, capacidad, especialidades]);

  // ---------------------------------------------------------------- arrastrar y soltar
  const admiteCelda = (i: Item | null, equipo: string, dia: string, turno: Turno) =>
    !!i && puedeCapturar && equipoDe(i) === equipo && dia >= hoy && !(i.k === "ot" && i.o.fecha === dia && i.o.turno === turno);
  const admiteOt = (i: Item | null, o: Ot) =>
    !!i && puedeCapturar && i.k === "bl" && i.b.equipo_id === o.equipo_id && o.estado === "Programada";

  async function soltarEnCelda(i: Item, dia: string, turno: Turno) {
    if (i.k === "pm") {
      acciones.mutate({
        fn: "programar_pm",
        args: { p_componente: i.s.componente_id, p_tipo: i.s.tipo, p_fecha: dia, p_turno: turno },
        aviso: `${i.s.tipo} de ${i.s.cod_interno} programado el ${fFecha(dia)} (${NOMBRE_TURNO[turno]})`,
      });
    } else if (i.k === "bl") {
      let motivo: string | null = null;
      if (i.b.estado === "Programado" && i.b.fecha_programada !== dia) {
        motivo = await pedirMotivo(`Reprogramar ${i.b.folio}`, `Del ${fFecha(i.b.fecha_programada)} al ${fFecha(dia)}`);
        if (motivo === null) return;
      }
      acciones.mutate({
        fn: "programar_backlog",
        args: { p_backlog: i.b.id, p_fecha: dia, p_turno: turno, p_motivo: motivo },
        aviso: `${i.b.folio} programado en una OT el ${fFecha(dia)}`,
      });
    } else {
      let motivo: string | null = null;
      if (i.o.fecha !== dia) {
        motivo = await pedirMotivo(`Reprogramar ${i.o.folio}`, `Del ${fFecha(i.o.fecha)} al ${fFecha(dia)} (${NOMBRE_TURNO[turno]})`);
        if (motivo === null) return;
      }
      acciones.mutate({
        fn: "mover_ot",
        args: { p_ot: i.o.id, p_fecha: dia, p_turno: turno, p_motivo: motivo },
        aviso: `${i.o.folio} movida al ${fFecha(dia)} (${NOMBRE_TURNO[turno]})`,
      });
    }
  }

  async function soltarEnOt(i: Item, o: Ot) {
    if (i.k !== "bl") return;
    let motivo: string | null = null;
    if (i.b.estado === "Programado" && i.b.fecha_programada !== o.fecha) {
      motivo = await pedirMotivo(`Agrupar ${i.b.folio} en ${o.folio}`, `Pasa del ${fFecha(i.b.fecha_programada)} al ${fFecha(o.fecha)}`);
      if (motivo === null) return;
    }
    acciones.mutate({
      fn: "programar_backlog",
      args: { p_backlog: i.b.id, p_fecha: null, p_turno: null, p_ot: o.id, p_motivo: motivo },
      aviso: `${i.b.folio} agregado a ${o.folio}`,
    });
  }

  const fuente = (i: Item) =>
    puedeCapturar && (i.k !== "ot" || i.o.estado === "Programada")
      ? {
          draggable: true,
          onDragStart: (e: React.DragEvent) => {
            e.dataTransfer.setData("text/plain", i.k);
            e.dataTransfer.effectAllowed = "move";
            e.stopPropagation();
            setArrastre(i);
          },
          onDragEnd: () => {
            setArrastre(null);
            setSobre(null);
          },
        }
      : {};

  const zonaCelda = (equipo: string, dia: string, turno: Turno) => {
    const clave = `${equipo}|${dia}|${turno}`;
    return {
      onDragOver: (e: React.DragEvent) => {
        if (!admiteCelda(arrastre, equipo, dia, turno)) return;
        e.preventDefault();
        setSobre(clave);
      },
      onDragLeave: () => setSobre((s) => (s === clave ? null : s)),
      onDrop: (e: React.DragEvent) => {
        e.preventDefault();
        const i = arrastre;
        setArrastre(null);
        setSobre(null);
        if (i && admiteCelda(i, equipo, dia, turno)) void soltarEnCelda(i, dia, turno);
      },
    };
  };
  const zonaOt = (o: Ot) => ({
    onDragOver: (e: React.DragEvent) => {
      if (!admiteOt(arrastre, o)) return;
      e.preventDefault();
      e.stopPropagation();
      setSobre(`ot|${o.id}`);
    },
    onDrop: (e: React.DragEvent) => {
      if (!admiteOt(arrastre, o)) return;
      e.preventDefault();
      e.stopPropagation();
      const i = arrastre!;
      setArrastre(null);
      setSobre(null);
      void soltarEnOt(i, o);
    },
  });

  const otsDe = (equipo: string, dia: string, turno: Turno) =>
    (ots ?? []).filter((o) => o.equipo_id === equipo && o.fecha === dia && o.turno === turno);
  const sinOtDe = (equipo: string, dia: string, turno: Turno) =>
    turno === "Dia" ? sinOt.filter((b) => b.equipo_id === equipo && b.fecha_programada === dia) : [];
  const otAbierta = (ots ?? []).find((o) => o.id === abierta) ?? null;

  return (
    <div className="pagina-tablero">
      {dialogo}
      <div className="barra-acciones">
        <h1 style={{ margin: 0 }}>Tablero de programación</h1>
        <span className="semana-titulo">
          Semana del {fFecha(lunes)} al {fFecha(domingo)}
        </span>
        <div className="espacio" />
        <label className="casilla-linea">
          <input type="checkbox" checked={todos} onChange={(e) => setTodos(e.target.checked)} /> Todos los equipos
        </label>
        <button className="boton-plano" onClick={() => setLunes(sumarDiasISO(lunes, -7))} aria-label="Semana anterior">
          ‹ Anterior
        </button>
        <button className="boton-plano" onClick={() => setLunes(lunesDe(hoy))} disabled={lunes === lunesDe(hoy)}>
          Hoy
        </button>
        <button className="boton-plano" onClick={() => setLunes(sumarDiasISO(lunes, 7))} aria-label="Semana siguiente">
          Siguiente ›
        </button>
      </div>

      <section className="carga-semana" aria-label="Carga de la semana">
        {carga.length === 0 && <p className="nota">Sin HH programadas ni capacidad cargada para esta semana.</p>}
        {carga.map((c) => {
          const uso = c.capacidad > 0 ? c.hh / c.capacidad : 0;
          return (
            <div key={c.id} className="barra-carga" aria-label={`Carga ${c.nombre}`}>
              <div className="bc-texto">
                <span>{c.nombre}</span>
                <span>
                  {fNum(c.hh)} / {c.capacidad > 0 ? `${fNum(c.capacidad)} HH` : "sin capacidad"}
                  {c.capacidad > 0 && ` · ${Math.round(uso * 100)} %`}
                </span>
              </div>
              <div className="bc-fondo">
                <div
                  className={`bc-relleno ${c.capacidad > 0 ? nivel(uso) : "sin-capacidad"}`}
                  style={{ width: `${Math.min(100, c.capacidad > 0 ? uso * 100 : c.hh > 0 ? 100 : 0)}%` }}
                />
              </div>
            </div>
          );
        })}
      </section>

      <div className="leyenda-tablero">
        <span className="ley t-preventiva">PM mayor</span>
        <span className="ley t-rutina">Rutina 40 h</span>
        <span className="ley t-correctiva">Correctiva</span>
        <span className="ley t-emergencia">Emergencia (P1)</span>
        <span className="ley t-sin-ot">Backlog programado sin OT</span>
      </div>

      <div className="tablero">
        <aside className="panel-listos" aria-label="Por programar">
          {puedeCapturar && <p className="nota">Arrastre a la fila del equipo, en el día y turno. Un backlog soltado sobre una OT del mismo equipo se agrega a esa OT.</p>}
          <h2>
            PM sugeridos <span className="nota">{sugeridos.length}</span>
          </h2>
          {sugeridos.length === 0 && <p className="nota">Sin PM por programar.</p>}
          {sugeridos.map((s) => (
            <div
              key={s.clave}
              className={`tarjeta-cal tarjeta-ot ${s.tipo === "Preventiva" ? "t-preventiva" : "t-rutina"}${/Vencido/.test(s.estado) ? " vencida" : ""}`}
              aria-label={`Sugerido ${s.tipo} ${s.cod_interno} ${s.nombre}`}
              {...fuente({ k: "pm", s })}
            >
              <div className="tc-linea1">
                <span className="tc-folio">{s.tipo === "Preventiva" ? `PM ${s.gama} h` : "Rutina 40 h"}</span>
                <span className="tc-estado">{s.estado.replace(/^\S+\s/, "")}</span>
              </div>
              <div className="tc-equipo">{s.cod_interno}</div>
              <div className="tc-trabajo">{s.nombre}</div>
              <div className="tc-datos">
                <span>{s.hh > 0 ? `${fNum(s.hh)} HH` : "sin HH estándar"}</span>
                {s.fecha_estimada && <span>estimado {fFecha(s.fecha_estimada)}</span>}
              </div>
            </div>
          ))}
          <h2>
            Backlogs listos <span className="nota">{listos.length}</span>
          </h2>
          {listos.length === 0 && <p className="nota">No hay backlogs listos para programar.</p>}
          {listos.map((b) => (
            <div key={b.id} className={`tarjeta-cal listo${b.vencido ? " vencida" : ""}`} aria-label={`Backlog ${b.folio} ${b.cod_interno}`} {...fuente({ k: "bl", b })}>
              <div className="tc-linea1">
                <Link to={`/backlog/${b.id}`} className="tc-folio" draggable={false}>
                  {b.folio}
                </Link>
                <EtiquetaPrioridad prioridad={b.prioridad} />
              </div>
              <div className="tc-equipo">{b.cod_interno}</div>
              <div className="tc-trabajo">{b.descripcion}</div>
              <div className="tc-datos">
                <span>{fNum(b.hh_estimadas)} HH</span>
                <span className={b.vencido ? "texto-vencido" : undefined}>límite {fFecha(b.fecha_limite)}</span>
              </div>
            </div>
          ))}
        </aside>

        <div className="tabla-marco grilla-tablero">
          {isLoading ? (
            <p className="nota" style={{ padding: 12 }}>Cargando…</p>
          ) : (
            <table>
              <thead>
                <tr>
                  <th className="col-equipo" rowSpan={2}>
                    Equipo
                  </th>
                  {dias.map((d, i) => (
                    <th key={d} colSpan={2} className={d === hoy ? "hoy" : d < hoy ? "pasado" : ""}>
                      {DIAS[i]} {d.slice(8, 10)}/{d.slice(5, 7)}
                    </th>
                  ))}
                </tr>
                <tr>
                  {dias.map((d) =>
                    TURNOS.map((t) => (
                      <th key={d + t} className={`th-turno${d === hoy ? " hoy" : d < hoy ? " pasado" : ""}`}>
                        {NOMBRE_TURNO[t]}
                      </th>
                    ))
                  )}
                </tr>
              </thead>
              <tbody>
                {filas.length === 0 && (
                  <tr>
                    <td colSpan={15} className="nota" style={{ height: "auto", padding: 12 }}>
                      Sin equipos con trabajos por programar esta semana. Marque «Todos los equipos» para verlos todos.
                    </td>
                  </tr>
                )}
                {filas.map(([grupo, lista]) => (
                  <GrupoFilas key={grupo} grupo={grupo}>
                    {lista.map((e) => (
                      <tr key={e.id}>
                        <td className="col-equipo">
                          <Link to={`/equipo/${e.id}`}>{e.cod_interno}</Link>
                          <div className="nota">{e.modelo}</div>
                        </td>
                        {dias.map((d) =>
                          TURNOS.map((t) => {
                            const enCelda = otsDe(e.id, d, t);
                            const clave = `${e.id}|${d}|${t}`;
                            const clase = [
                              d === hoy ? "hoy" : "",
                              d < hoy ? "pasado" : "",
                              t === "Noche" ? "noche" : "",
                              admiteCelda(arrastre, e.id, d, t) ? "admite" : "",
                              sobre === clave ? "sobre" : "",
                              enCelda.length > 1 ? "choque" : "",
                            ]
                              .filter(Boolean)
                              .join(" ");
                            return (
                              <td
                                key={clave}
                                className={clase}
                                aria-label={`Celda ${e.cod_interno} ${d} ${NOMBRE_TURNO[t]}`}
                                title={enCelda.length > 1 ? "Dos OT del mismo equipo en el mismo turno" : undefined}
                                {...zonaCelda(e.id, d, t)}
                              >
                                {enCelda.map((o) => (
                                  <div
                                    key={o.id}
                                    className={`tarjeta-cal tarjeta-ot ${CLASE_TIPO[o.tipo]}${admiteOt(arrastre, o) ? " admite" : ""}${sobre === `ot|${o.id}` ? " sobre" : ""}${o.estado !== "Programada" ? " hecha" : ""}`}
                                    aria-label={`OT ${o.folio}`}
                                    onClick={() => setAbierta(o.id)}
                                    {...fuente({ k: "ot", o })}
                                    {...zonaOt(o)}
                                  >
                                    <div className="tc-linea1">
                                      <span className="tc-folio">{o.folio}</span>
                                      {o.avisos && (
                                        <span className="tc-aviso" title={o.avisos} aria-label={`Aviso: ${o.avisos}`}>
                                          !
                                        </span>
                                      )}
                                    </div>
                                    <div className="tc-trabajo">{o.titulo}</div>
                                    <div className="tc-datos">
                                      <span>{fNum(o.hh_total)} HH</span>
                                      {o.backlogs.length > 0 && o.tipo !== "Correctiva" && o.tipo !== "Emergencia" && (
                                        <span className="tc-pm">+{o.backlogs.length} backlog</span>
                                      )}
                                      {o.backlogs.length > 1 && (o.tipo === "Correctiva" || o.tipo === "Emergencia") && (
                                        <span>{o.backlogs.length} backlogs</span>
                                      )}
                                    </div>
                                  </div>
                                ))}
                                {sinOtDe(e.id, d, t).map((b) => (
                                  <div
                                    key={b.id}
                                    className="tarjeta-cal tarjeta-ot t-sin-ot"
                                    aria-label={`Programado sin OT ${b.folio}`}
                                    title="Programado desde el Calendario de backlog. Arrástrelo a un turno o a una OT para darle OT."
                                    {...fuente({ k: "bl", b })}
                                  >
                                    <div className="tc-linea1">
                                      <Link to={`/backlog/${b.id}`} className="tc-folio" draggable={false}>
                                        {b.folio}
                                      </Link>
                                    </div>
                                    <div className="tc-trabajo">{b.descripcion}</div>
                                    <div className="tc-datos">
                                      <span>{fNum(b.hh_estimadas)} HH</span>
                                      <span>sin OT</span>
                                    </div>
                                  </div>
                                ))}
                              </td>
                            );
                          })
                        )}
                      </tr>
                    ))}
                  </GrupoFilas>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {otAbierta && (
        <DetalleOt
          ot={otAbierta}
          puedeCapturar={puedeCapturar}
          hh={(otHh ?? []).filter((h) => h.ot_id === otAbierta.id)}
          especialidades={especialidades ?? []}
          pedirMotivo={pedirMotivo}
          onAccion={(fn, args, aviso) => acciones.mutate({ fn, args, aviso })}
          onCerrar={() => setAbierta(null)}
        />
      )}
    </div>
  );
}

function GrupoFilas({ grupo, children }: { grupo: string; children: React.ReactNode }) {
  return (
    <>
      <tr className="fila-grupo">
        <td colSpan={15}>{grupo}</td>
      </tr>
      {children}
    </>
  );
}

function DetalleOt({
  ot,
  puedeCapturar,
  hh,
  especialidades,
  pedirMotivo,
  onAccion,
  onCerrar,
}: {
  ot: Ot;
  puedeCapturar: boolean;
  hh: { especialidad_id: string; hh: number }[];
  especialidades: { id: string; nombre: string }[];
  pedirMotivo: (titulo: string, detalle?: string) => Promise<string | null>;
  onAccion: (fn: string, args: Record<string, unknown>, aviso: string) => void;
  onCerrar: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);
  const { data: eventos } = useEventosOt(ot.id);
  const [fecha, setFecha] = useState(ot.fecha);
  const [turno, setTurno] = useState<Turno>(ot.turno);
  const nombreEsp = new Map(especialidades.map((e) => [e.id, e.nombre]));
  const editable = puedeCapturar && ot.estado === "Programada";

  async function mover() {
    let motivo: string | null = null;
    if (fecha !== ot.fecha) {
      motivo = await pedirMotivo(`Reprogramar ${ot.folio}`, `Del ${fFecha(ot.fecha)} al ${fFecha(fecha)}`);
      if (motivo === null) return;
    }
    onAccion("mover_ot", { p_ot: ot.id, p_fecha: fecha, p_turno: turno, p_motivo: motivo }, `${ot.folio} movida al ${fFecha(fecha)}`);
    onCerrar();
  }
  async function quitar(b: { id: string; folio: string }) {
    const motivo = await pedirMotivo(`Quitar ${b.folio} de ${ot.folio}`, "El backlog vuelve a Listo para programar.");
    if (motivo === null) return;
    onAccion("quitar_backlog_ot", { p_backlog: b.id, p_motivo: motivo }, `${b.folio} sale de ${ot.folio}`);
    onCerrar();
  }
  async function anular() {
    const motivo = await pedirMotivo(`Anular ${ot.folio}`, "Sus backlogs vuelven a Listo para programar.");
    if (motivo === null) return;
    onAccion("anular_ot", { p_ot: ot.id, p_motivo: motivo }, `${ot.folio} anulada`);
    onCerrar();
  }

  return (
    <dialog
      ref={ref}
      className="dialogo-ot"
      aria-label={`Detalle ${ot.folio}`}
      onCancel={(e) => {
        e.preventDefault();
        onCerrar();
      }}
    >
      <h1 style={{ fontSize: 17, marginBottom: 2 }}>
        {ot.folio} · {ot.tipo}
      </h1>
      <p className="nota" style={{ marginTop: 0 }}>
        <Link to={`/equipo/${ot.equipo_id}`}>{ot.cod_interno}</Link> · {ot.titulo} · {fFecha(ot.fecha)} {NOMBRE_TURNO[ot.turno]} · {ot.estado}
        {ot.reprogramaciones > 0 && ` · ${ot.reprogramaciones} reprogramación(es)`}
      </p>
      {ot.avisos && <p className="aviso-ot">{ot.avisos}</p>}

      <h2 className="dot-subtitulo">HH por especialidad</h2>
      {hh.length === 0 ? (
        <p className="nota">Sin HH. {ot.tipo === "Preventiva" || ot.tipo === "Rutina 40 h" ? "Cargue la pauta de esta gama." : ""}</p>
      ) : (
        <p>{hh.map((h) => `${nombreEsp.get(h.especialidad_id) ?? "?"} ${fNum(h.hh)}`).join(" · ")}</p>
      )}

      <h2 className="dot-subtitulo">Backlogs en la OT</h2>
      {ot.backlogs.length === 0 && <p className="nota">Ninguno. Arrastre un backlog del mismo equipo sobre la tarjeta para agregarlo.</p>}
      {ot.backlogs.map((b) => (
        <div key={b.id} className="dot-backlog">
          <Link to={`/backlog/${b.id}`}>{b.folio}</Link>
          <EtiquetaPrioridad prioridad={b.prioridad} />
          <span className="dot-desc">{b.descripcion}</span>
          {editable && (
            <button className="boton-plano boton-chico" onClick={() => quitar(b)}>
              Quitar
            </button>
          )}
        </div>
      ))}

      {editable && (
        <>
          <h2 className="dot-subtitulo">Cambiar día o turno</h2>
          <div className="fila-campos">
            <label className="campo" style={{ maxWidth: 170 }}>
              <span>Fecha</span>
              <input type="date" value={fecha} min={hoyISO()} onChange={(e) => setFecha(e.target.value)} />
            </label>
            <label className="campo" style={{ maxWidth: 130 }}>
              <span>Turno</span>
              <select value={turno} onChange={(e) => setTurno(e.target.value as Turno)}>
                <option value="Dia">Día</option>
                <option value="Noche">Noche</option>
              </select>
            </label>
            <div style={{ alignSelf: "flex-end" }}>
              <button onClick={mover} disabled={fecha === ot.fecha && turno === ot.turno}>
                Mover
              </button>
            </div>
          </div>
        </>
      )}

      <h2 className="dot-subtitulo">Bitácora</h2>
      <ul className="dot-eventos">
        {(eventos ?? []).map((ev) => (
          <li key={ev.id}>
            <span className="nota">{new Date(ev.creado_en).toLocaleString("es")}</span> {ev.tipo}
            {ev.texto ? ` · ${ev.texto}` : ""}
          </li>
        ))}
      </ul>

      <div className="barra-acciones" style={{ marginBottom: 0 }}>
        {editable && (
          <button className="boton-plano boton-peligro-plano" onClick={anular}>
            Anular OT
          </button>
        )}
        <div className="espacio" />
        <button className="boton-plano" autoFocus onClick={onCerrar}>
          Cerrar
        </button>
      </div>
    </dialog>
  );
}
