import { useMemo, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../auth";
import { useCambios, useComponentes, useEquipos } from "../lib/queries";
import { fFecha, fNum, hoyISO } from "../../lib/fmt";
import { useAvisos } from "../../components/Avisos";

export default function Cambios() {
  const { session, esAdmin } = useAuth();
  const qc = useQueryClient();
  const { data: cambios } = useCambios();
  const { data: componentes } = useComponentes();
  const { data: equipos } = useEquipos();

  const [componenteId, setComponenteId] = useState("");
  const [vigenteDesde, setVigenteDesde] = useState(hoyISO());
  const [lecturaVieja, setLecturaVieja] = useState("");
  const [lecturaNueva, setLecturaNueva] = useState("0");
  const [fuente, setFuente] = useState("");
  const { avisar } = useAvisos();

  const nombreEq = useMemo(
    () => new Map((equipos ?? []).map((e) => [e.id, e.cod_interno])),
    [equipos]
  );
  const compPorId = useMemo(
    () => new Map((componentes ?? []).map((c) => [c.id, c])),
    [componentes]
  );

  // Offset propuesto: última lectura del contador viejo + offset que ya tenía
  // − lectura inicial del contador nuevo (si no arrancó en 0).
  const offsetPrevio = useMemo(() => {
    if (!componenteId || !cambios) return 0;
    const previos = cambios
      .filter((c) => c.componente_id === componenteId && c.vigente_desde < vigenteDesde)
      .sort((a, b) => a.vigente_desde.localeCompare(b.vigente_desde));
    if (previos.length === 0) return 0;
    const ultimaFecha = previos[previos.length - 1].vigente_desde;
    return previos
      .filter((c) => c.vigente_desde === ultimaFecha)
      .reduce((s, c) => s + Number(c.offset_h), 0);
  }, [componenteId, cambios, vigenteDesde]);

  const vieja = parseFloat(lecturaVieja);
  const nueva = parseFloat(lecturaNueva);
  const offsetPropuesto =
    !isNaN(vieja) && !isNaN(nueva) ? vieja + offsetPrevio - nueva : null;

  const grabar = useMutation({
    mutationFn: async () => {
      if (!componenteId || offsetPropuesto === null)
        throw new Error("Complete componente y lecturas");
      const { error } = await supabase().from("cambios_horometro").insert({
        componente_id: componenteId,
        vigente_desde: vigenteDesde,
        offset_h: offsetPropuesto,
        ultima_lectura_vieja: `${lecturaVieja}`,
        primera_lectura_nueva: `${lecturaNueva}`,
        metodo: `Continuidad: ${lecturaVieja} + ${offsetPrevio} − ${lecturaNueva}`,
        fuente: fuente.trim() || null,
        estado: "Por validar",
        creado_por: session?.user.id,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      avisar("Cambio registrado, queda por validar");
      setLecturaVieja("");
      setLecturaNueva("0");
      setFuente("");
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  const validar = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase()
        .from("cambios_horometro")
        .update({ estado: "Validado" })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries(),
  });

  return (
    <>
      <h1>Cambios y reinicios de horómetro</h1>
      <p className="subtitulo">
        Cuando un contador vuelve a cero se registra el offset: las horas que se suman al contador
        nuevo para obtener el acumulado real. El offset es el total, no la diferencia con el
        anterior, y rige por fecha.
      </p>
      <div className="panel-formulario">
        <div className="fila-campos">
          <label className="campo" style={{ maxWidth: 280 }}>
            <span>Componente</span>
            <select value={componenteId} onChange={(e) => setComponenteId(e.target.value)}>
              <option value="">Seleccione</option>
              {(componentes ?? [])
                .filter((c) => c.activo)
                .sort((a, b) =>
                  (nombreEq.get(a.equipo_id) ?? "").localeCompare(
                    nombreEq.get(b.equipo_id) ?? "",
                    "es",
                    { numeric: true }
                  )
                )
                .map((c) => (
                  <option key={c.id} value={c.id}>
                    {nombreEq.get(c.equipo_id)} · {c.tipo_horometro}
                  </option>
                ))}
            </select>
          </label>
          <label className="campo" style={{ maxWidth: 170 }}>
            <span>Vigente desde (1ª lectura del contador nuevo)</span>
            <input
              type="date"
              value={vigenteDesde}
              onChange={(e) => setVigenteDesde(e.target.value)}
            />
          </label>
          <label className="campo" style={{ maxWidth: 160 }}>
            <span>Última lectura contador viejo</span>
            <input value={lecturaVieja} onChange={(e) => setLecturaVieja(e.target.value)} />
          </label>
          <label className="campo" style={{ maxWidth: 160 }}>
            <span>Lectura inicial contador nuevo</span>
            <input value={lecturaNueva} onChange={(e) => setLecturaNueva(e.target.value)} />
          </label>
          <label className="campo">
            <span>Fuente / verificación</span>
            <input value={fuente} onChange={(e) => setFuente(e.target.value)} />
          </label>
        </div>
        <div className="barra-acciones" style={{ marginTop: 10, marginBottom: 0 }}>
          <span className="nota">
            Offset previo: {fNum(offsetPrevio)} h
            {offsetPropuesto !== null && (
              <>
                {" "}
                · <b style={{ color: "var(--aviso)" }}>Offset propuesto: {fNum(offsetPropuesto)} h</b>
              </>
            )}
          </span>
          <div className="espacio" />
          <button onClick={() => grabar.mutate()} disabled={grabar.isPending}>
            Registrar cambio
          </button>
        </div>
      </div>

      <div className="tabla-marco">
        <table>
          <thead>
            <tr>
              <th>Equipo</th>
              <th>Horómetro</th>
              <th>Vigente desde</th>
              <th className="num">Offset (h)</th>
              <th>Última vieja</th>
              <th>Primera nueva</th>
              <th>Método</th>
              <th>Fuente</th>
              <th>Estado</th>
              {esAdmin && <th></th>}
            </tr>
          </thead>
          <tbody>
            {(cambios ?? []).map((c) => {
              const comp = compPorId.get(c.componente_id);
              return (
                <tr key={c.id}>
                  <td>{comp ? nombreEq.get(comp.equipo_id) : ""}</td>
                  <td>{comp?.tipo_horometro}</td>
                  <td>{fFecha(c.vigente_desde)}</td>
                  <td className="num">{fNum(c.offset_h)}</td>
                  <td>{c.ultima_lectura_vieja}</td>
                  <td>{c.primera_lectura_nueva}</td>
                  <td style={{ whiteSpace: "normal", maxWidth: 240 }}>{c.metodo}</td>
                  <td style={{ whiteSpace: "normal", maxWidth: 200 }}>{c.fuente}</td>
                  <td>
                    {c.estado === "Por validar" ? (
                      <span className="control-aviso">⚠ Por validar</span>
                    ) : (
                      <span className="control-ok">Validado</span>
                    )}
                  </td>
                  {esAdmin && (
                    <td>
                      {c.estado === "Por validar" && (
                        <button className="boton-plano" onClick={() => validar.mutate(c.id)}>
                          Validar
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
