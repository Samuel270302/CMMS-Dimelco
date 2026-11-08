import { useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../auth";
import { useComponentes, useComponentesUnidad, useEquipos, usePerfiles } from "../lib/queries";
import { useUnidad } from "../../lib/unidad";
import { exportarLecturas, exportarRegistrosPm } from "../lib/exportar";
import { fFecha, fFechaHora, fNum, hoyISO } from "../../lib/fmt";
import type { Anulacion, LecturaCalc, RegistroPm } from "../lib/types";
import { useDialogoMotivo } from "../../components/DialogoMotivo";
import { useAvisos } from "../../components/Avisos";

export default function Historial() {
  const { esAdmin } = useAuth();
  const qc = useQueryClient();
  const { data: equipos } = useEquipos();
  const { data: componentes } = useComponentes();
  const { data: perfiles } = usePerfiles();

  const [pestania, setPestania] = useState<"lecturas" | "pm">("lecturas");
  const [equipoId, setEquipoId] = useState("");
  const [desde, setDesde] = useState(() => {
    const d = new Date();
    d.setMonth(d.getMonth() - 1);
    return d.toISOString().slice(0, 10);
  });
  const [hasta, setHasta] = useState(hoyISO());
  const [verAnulados, setVerAnulados] = useState(false);

  const compPorId = useMemo(
    () => new Map((componentes ?? []).map((c) => [c.id, c])),
    [componentes]
  );
  const nombreEq = useMemo(
    () => new Map((equipos ?? []).map((e) => [e.id, e.cod_interno])),
    [equipos]
  );
  const nombreUsuario = useMemo(
    () => new Map((perfiles ?? []).map((p) => [p.user_id, p.nombre])),
    [perfiles]
  );
  // Lo importado del Excel no tiene usuario; un usuario borrado deja el id sin perfil.
  const quien = (id: string | null | undefined, importado = false) =>
    importado ? "Importado del Excel" : !id ? "Sin dato" : (nombreUsuario.get(id) ?? "Usuario dado de baja");
  const compsUnidad = useComponentesUnidad();
  const { unidadId } = useUnidad();
  const compsEquipo = useMemo(
    () =>
      equipoId
        ? (componentes ?? []).filter((c) => c.equipo_id === equipoId).map((c) => c.id)
        : compsUnidad
          ? [...compsUnidad]
          : null,
    [componentes, equipoId, compsUnidad]
  );

  const lecturas = useQuery({
    queryKey: ["prev:hist-lecturas", unidadId, equipoId, desde, hasta, verAnulados],
    queryFn: async () => {
      // Las anuladas no están en v_lecturas: se leen de la tabla, sin horas calculadas.
      let q = verAnulados
        ? supabase()
            .from("lecturas")
            .select("*")
            .eq("anulada", true)
            .gte("fecha", desde)
            .lte("fecha", hasta)
            .order("fecha", { ascending: false })
            .order("turno", { ascending: false })
        : supabase()
            .from("v_lecturas")
            .select("*")
            .gte("fecha", desde)
            .lte("fecha", hasta)
            .order("fecha", { ascending: false })
            .order("num_turno", { ascending: false });
      q = q.limit(3000);
      if (compsEquipo) q = q.in("componente_id", compsEquipo);
      const { data, error } = await q;
      if (error) throw error;
      return data as (LecturaCalc & Partial<Anulacion>)[];
    },
  });

  const registros = useQuery({
    queryKey: ["prev:hist-pm", unidadId, equipoId, desde, hasta, verAnulados],
    queryFn: async () => {
      let q = supabase()
        .from("registros_pm")
        .select("*")
        .eq("anulado", verAnulados)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .order("fecha", { ascending: false })
        .limit(2000);
      if (compsEquipo) q = q.in("componente_id", compsEquipo);
      const { data, error } = await q;
      if (error) throw error;
      return data as (RegistroPm & Anulacion)[];
    },
  });

  const { pedirMotivo, dialogo } = useDialogoMotivo();
  const { avisar } = useAvisos();

  const anularLectura = useMutation({
    mutationFn: async ({ id, motivo }: { id: string; motivo: string }) => {
      const { error } = await supabase()
        .from("lecturas")
        .update({ anulada: true, motivo_anulacion: motivo })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      avisar("Registro anulado");
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(`No se pudo anular: ${e.message}`, "error"),
  });

  const anularPm = useMutation({
    mutationFn: async ({ id, motivo }: { id: string; motivo: string }) => {
      const { error } = await supabase()
        .from("registros_pm")
        .update({ anulado: true, motivo_anulacion: motivo })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      avisar("Registro anulado");
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(`No se pudo anular: ${e.message}`, "error"),
  });

  function auditoria(r: { creado_por: string | null } & Partial<Anulacion>, importado?: boolean) {
    return {
      capturado: quien(r.creado_por, importado),
      anuladoPor: quien(r.anulado_por),
      anuladoEn: fFechaHora(r.anulado_en),
      motivo: r.motivo_anulacion ?? null,
    };
  }

  function decorarLectura(l: LecturaCalc & Partial<Anulacion>) {
    const c = compPorId.get(l.componente_id);
    return {
      ...l,
      ...auditoria(l, l.origen === "import"),
      equipo: c ? (nombreEq.get(c.equipo_id) ?? "") : "",
      tipo: c?.tipo_horometro ?? "",
    };
  }

  function decorarPm(r: RegistroPm & Anulacion) {
    const c = compPorId.get(r.componente_id);
    return {
      ...r,
      ...auditoria(r, !r.creado_por),
      equipo: c ? (nombreEq.get(c.equipo_id) ?? "") : "",
      tipo: c?.tipo_horometro ?? "",
      clase: r.gama === null ? "Sin gama" : r.gama === 40 ? "Rutina 40 h" : "Mayor",
    };
  }

  return (
    <>
      {dialogo}
      <h1>Historial</h1>
      <p className="subtitulo">Lecturas de horómetro y mantenimientos ejecutados.</p>
      <div className="barra-acciones">
        <button
          className={pestania === "lecturas" ? "" : "boton-secundario"}
          onClick={() => setPestania("lecturas")}
        >
          Lecturas
        </button>
        <button
          className={pestania === "pm" ? "" : "boton-secundario"}
          onClick={() => setPestania("pm")}
        >
          Registros PM
        </button>
        <select style={{ width: 200 }} value={equipoId} onChange={(e) => setEquipoId(e.target.value)}>
          <option value="">Todos los equipos</option>
          {(equipos ?? []).map((e) => (
            <option key={e.id} value={e.id}>
              {e.cod_interno}
            </option>
          ))}
        </select>
        <input type="date" style={{ width: 150 }} value={desde} onChange={(e) => setDesde(e.target.value)} />
        <input type="date" style={{ width: 150 }} value={hasta} onChange={(e) => setHasta(e.target.value)} />
        <label className="casilla-linea">
          <input type="checkbox" checked={verAnulados} onChange={(e) => setVerAnulados(e.target.checked)} />
          Ver anulados
        </label>
        <div className="espacio" />
        <button
          className="boton-secundario"
          onClick={() =>
            pestania === "lecturas"
              ? exportarLecturas(
                  (lecturas.data ?? []).map(decorarLectura),
                  `Lecturas${verAnulados ? " anuladas" : ""} ${desde} a ${hasta}.xlsx`,
                  verAnulados
                )
              : exportarRegistrosPm(
                  (registros.data ?? []).map(decorarPm),
                  `Registros PM${verAnulados ? " anulados" : ""} ${desde} a ${hasta}.xlsx`,
                  verAnulados
                )
          }
        >
          Exportar a Excel
        </button>
      </div>

      {pestania === "lecturas" ? (
        <div className="tabla-marco">
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Turno</th>
                <th>Equipo</th>
                <th>Horómetro</th>
                <th className="num">Lectura</th>
                {!verAnulados && (
                  <>
                    <th className="num">Acumulado</th>
                    <th className="num">Horas interv.</th>
                    <th>Control</th>
                  </>
                )}
                <th>Capturado por</th>
                {verAnulados ? <ColumnasAnulacion /> : esAdmin && <th></th>}
              </tr>
            </thead>
            <tbody>
              {(lecturas.data ?? []).map((l) => {
                const d = decorarLectura(l);
                return (
                  <tr key={l.id}>
                    <td>{fFecha(l.fecha)}</td>
                    <td>{l.turno}</td>
                    <td>{d.equipo}</td>
                    <td>{d.tipo}</td>
                    <td className="num">{fNum(l.lectura)}</td>
                    {!verAnulados && (
                      <>
                        <td className="num">{fNum(l.lectura_acum)}</td>
                        <td className="num">{fNum(l.horas_intervalo)}</td>
                        <td>
                          <span
                            className={
                              l.control === "OK"
                                ? "control-ok"
                                : l.control.startsWith("Horas imposibles")
                                  ? "control-error"
                                  : "control-aviso"
                            }
                          >
                            {l.control}
                          </span>
                        </td>
                      </>
                    )}
                    <td title={`Grabado el ${fFechaHora(l.creado_en)}`}>{d.capturado}</td>
                    {verAnulados ? (
                      <CeldasAnulacion {...d} />
                    ) : (
                      esAdmin && (
                        <td>
                          <button
                            className="boton-plano"
                            onClick={async () => {
                              const motivo = await pedirMotivo(
                                "Anular lectura de horómetro",
                                `${d.equipo} · ${d.tipo} · ${fFecha(l.fecha)} ${l.turno} · lectura ${fNum(l.lectura)} h`
                              );
                              if (motivo) anularLectura.mutate({ id: l.id, motivo });
                            }}
                          >
                            Anular
                          </button>
                        </td>
                      )
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
          {lecturas.data?.length === 0 && (
            <p className="nota">{verAnulados ? "No hay lecturas anuladas en el rango." : "No hay lecturas en el rango."}</p>
          )}
        </div>
      ) : (
        <div className="tabla-marco">
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Equipo</th>
                <th>Horómetro</th>
                <th className="num">Gama</th>
                <th className="num">Lectura</th>
                <th>Clase</th>
                <th>Responsable</th>
                <th>Capturado por</th>
                {verAnulados ? <ColumnasAnulacion /> : esAdmin && <th></th>}
              </tr>
            </thead>
            <tbody>
              {(registros.data ?? []).map((r) => {
                const d = decorarPm(r);
                return (
                  <tr key={r.id}>
                    <td>{fFecha(r.fecha)}</td>
                    <td>{d.equipo}</td>
                    <td>{d.tipo}</td>
                    <td className="num">{r.gama ?? "Sin gama"}</td>
                    <td className="num">{fNum(r.lectura)}</td>
                    <td>{d.clase}</td>
                    <td>{r.responsable}</td>
                    <td title={`Grabado el ${fFechaHora(r.creado_en)}`}>{d.capturado}</td>
                    {verAnulados ? (
                      <CeldasAnulacion {...d} />
                    ) : (
                      esAdmin && (
                        <td>
                          <button
                            className="boton-plano"
                            onClick={async () => {
                              const motivo = await pedirMotivo(
                                "Anular registro PM",
                                `${d.equipo} · ${d.tipo} · ${fFecha(r.fecha)} · gama ${r.gama ?? "sin gama"} · lectura ${fNum(r.lectura)} h`
                              );
                              if (motivo) anularPm.mutate({ id: r.id, motivo });
                            }}
                          >
                            Anular
                          </button>
                        </td>
                      )
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
          {registros.data?.length === 0 && (
            <p className="nota">{verAnulados ? "No hay registros PM anulados en el rango." : "No hay registros PM en el rango."}</p>
          )}
        </div>
      )}
    </>
  );
}

function ColumnasAnulacion() {
  return (
    <>
      <th>Anulado por</th>
      <th>Anulado el</th>
      <th>Motivo</th>
    </>
  );
}

function CeldasAnulacion({ anuladoPor, anuladoEn, motivo }: { anuladoPor: string; anuladoEn: string; motivo: string | null }) {
  return (
    <>
      <td>{anuladoPor}</td>
      <td>{anuladoEn}</td>
      <td className="celda-motivo" title={motivo ?? ""}>{motivo}</td>
    </>
  );
}
