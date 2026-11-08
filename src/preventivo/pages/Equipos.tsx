import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { useComponentes, useEquipos, usePlanes } from "../lib/queries";
import { fFecha } from "../../lib/fmt";
import type { TipoHorometro } from "../lib/types";
import { useAvisos } from "../../components/Avisos";
import EditorEquipo from "../components/EditorEquipo";
import { useUnidad, useUnidades } from "../../lib/unidad";
import type { Equipo } from "../lib/types";

const TIPOS: TipoHorometro[] = [
  "Diesel",
  "Motor Eléctrico",
  "Percusión #1",
  "Percusión #2",
  "Empernado",
];

export default function Equipos() {
  const qc = useQueryClient();
  const { data: equipos } = useEquipos();
  const { data: componentes } = useComponentes();
  const { data: planes } = usePlanes();
  const { avisar } = useAvisos();
  const [editando, setEditando] = useState<Equipo | null>(null);
  const { unidadId } = useUnidad();
  const { data: unidades } = useUnidades();
  const nombreUnidad = new Map((unidades ?? []).map((u) => [u.id, u.nombre]));
  const [unidadNueva, setUnidadNueva] = useState("");
  const unidadEquipo = unidadId ?? unidadNueva;

  const [nuevoEq, setNuevoEq] = useState({ cod: "", sap: "", modelo: "", fecha: "" });
  const [nuevoComp, setNuevoComp] = useState({
    equipoId: "",
    tipo: "Diesel" as TipoHorometro,
    nombre: "",
    sistema: "Motor Diésel",
    seccion: "1",
    sap: "",
    plan: "",
    rutina40: false,
  });

  const compPorEquipo = useMemo(() => {
    const m = new Map<string, typeof componentes>();
    for (const c of componentes ?? []) {
      if (!m.has(c.equipo_id)) m.set(c.equipo_id, []);
      m.get(c.equipo_id)!.push(c);
    }
    return m;
  }, [componentes]);

  const crearEquipo = useMutation({
    mutationFn: async () => {
      if (!nuevoEq.cod.trim() || !nuevoEq.modelo.trim())
        throw new Error("Código de equipo y modelo son obligatorios");
      if (!unidadEquipo) throw new Error("Elija la unidad del equipo");
      const { error } = await supabase().from("equipos").insert({
        unidad_id: unidadEquipo,
        cod_interno: nuevoEq.cod.trim(),
        cod_sap: nuevoEq.sap.trim() || null,
        modelo: nuevoEq.modelo.trim(),
        fecha_inicio_operacion: nuevoEq.fecha || null,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setNuevoEq({ cod: "", sap: "", modelo: "", fecha: "" });
      avisar("Equipo creado. Agregue sus componentes abajo.");
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  const crearComponente = useMutation({
    mutationFn: async () => {
      if (!nuevoComp.equipoId || !nuevoComp.nombre.trim() || !nuevoComp.plan)
        throw new Error("Equipo, nombre y plan son obligatorios");
      const { error } = await supabase().from("componentes").insert({
        equipo_id: nuevoComp.equipoId,
        tipo_horometro: nuevoComp.tipo,
        nombre: nuevoComp.nombre.trim(),
        sistema: nuevoComp.sistema,
        seccion: Number(nuevoComp.seccion),
        cod_sap: nuevoComp.sap.trim() || null,
        plan_clave: nuevoComp.plan,
        aplica_rutina40: nuevoComp.rutina40,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      avisar("Componente creado: ya aparece en el control");
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  const alternarComp = useMutation({
    mutationFn: async ({ id, activo }: { id: string; activo: boolean }) => {
      const { error } = await supabase().from("componentes").update({ activo }).eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries(),
  });

  const alternarEq = useMutation({
    mutationFn: async ({ id, activo }: { id: string; activo: boolean }) => {
      const { error } = await supabase().from("equipos").update({ activo }).eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries(),
  });

  return (
    <>
      {editando && (
        <EditorEquipo
          equipo={editando}
          componentes={compPorEquipo.get(editando.id) ?? []}
          planes={planes ?? []}
          onCerrar={() => setEditando(null)}
        />
      )}
      <h1>Maestro de equipos y componentes</h1>
      <p className="subtitulo">
        Cada componente (equipo + tipo de horómetro) es una fila del control. Un componente
        inactivo no aparece en controles ni captura.
      </p>

      <div className="panel-formulario">
        <div className="fila-campos">
          {!unidadId && (
            <label className="campo" style={{ maxWidth: 190 }}>
              <span>Unidad</span>
              <select value={unidadNueva} onChange={(e) => setUnidadNueva(e.target.value)}>
                <option value="">Seleccione</option>
                {(unidades ?? []).map((u) => (
                  <option key={u.id} value={u.id}>{u.nombre}</option>
                ))}
              </select>
            </label>
          )}
          <label className="campo" style={{ maxWidth: 220 }}>
            <span>Nuevo equipo: código de equipo</span>
            <input value={nuevoEq.cod} onChange={(e) => setNuevoEq({ ...nuevoEq, cod: e.target.value })} placeholder="Scooptram #7" />
          </label>
          <label className="campo" style={{ maxWidth: 200 }}>
            <span>Modelo</span>
            <input value={nuevoEq.modelo} onChange={(e) => setNuevoEq({ ...nuevoEq, modelo: e.target.value })} />
          </label>
          <label className="campo" style={{ maxWidth: 140 }}>
            <span>Cód. interno</span>
            <input value={nuevoEq.sap} onChange={(e) => setNuevoEq({ ...nuevoEq, sap: e.target.value })} />
          </label>
          <label className="campo" style={{ maxWidth: 170 }}>
            <span>Inicio de operación</span>
            <input type="date" value={nuevoEq.fecha} onChange={(e) => setNuevoEq({ ...nuevoEq, fecha: e.target.value })} />
          </label>
          <div style={{ alignSelf: "flex-end" }}>
            <button onClick={() => crearEquipo.mutate()}>Crear equipo</button>
          </div>
        </div>
      </div>

      <div className="panel-formulario">
        <div className="fila-campos">
          <label className="campo" style={{ maxWidth: 190 }}>
            <span>Nuevo componente: equipo</span>
            <select value={nuevoComp.equipoId} onChange={(e) => setNuevoComp({ ...nuevoComp, equipoId: e.target.value })}>
              <option value="">Seleccione</option>
              {(equipos ?? []).map((e) => (
                <option key={e.id} value={e.id}>{e.cod_interno}</option>
              ))}
            </select>
          </label>
          <label className="campo" style={{ maxWidth: 150 }}>
            <span>Tipo de horómetro</span>
            <select value={nuevoComp.tipo} onChange={(e) => setNuevoComp({ ...nuevoComp, tipo: e.target.value as TipoHorometro })}>
              {TIPOS.map((t) => (
                <option key={t}>{t}</option>
              ))}
            </select>
          </label>
          <label className="campo" style={{ maxWidth: 240 }}>
            <span>Nombre (como se ve en el control)</span>
            <input value={nuevoComp.nombre} onChange={(e) => setNuevoComp({ ...nuevoComp, nombre: e.target.value })} placeholder="Motor Diésel" />
          </label>
          <label className="campo" style={{ maxWidth: 150 }}>
            <span>Sistema</span>
            <select value={nuevoComp.sistema} onChange={(e) => setNuevoComp({ ...nuevoComp, sistema: e.target.value })}>
              <option>Motor Diésel</option>
              <option>Compresor</option>
              <option>Perforadora</option>
              <option>Empernadora</option>
            </select>
          </label>
          <label className="campo" style={{ maxWidth: 110 }}>
            <span>Sección</span>
            <select value={nuevoComp.seccion} onChange={(e) => setNuevoComp({ ...nuevoComp, seccion: e.target.value })}>
              <option value="1">1 Diésel</option>
              <option value="2">2 Compresor</option>
              <option value="3">3 Perf/Emp</option>
            </select>
          </label>
          <label className="campo" style={{ maxWidth: 170 }}>
            <span>Plan MP</span>
            <select value={nuevoComp.plan} onChange={(e) => setNuevoComp({ ...nuevoComp, plan: e.target.value })}>
              <option value="">Seleccione</option>
              {(planes ?? []).filter((p) => p.clave !== "RUTINA-40").map((p) => (
                <option key={p.clave}>{p.clave}</option>
              ))}
            </select>
          </label>
          <label className="campo" style={{ maxWidth: 130 }}>
            <span>Cód. interno componente</span>
            <input value={nuevoComp.sap} onChange={(e) => setNuevoComp({ ...nuevoComp, sap: e.target.value })} />
          </label>
          <label className="campo" style={{ maxWidth: 120, alignSelf: "flex-end" }}>
            <span>Rutina 40 h</span>
            <select
              value={nuevoComp.rutina40 ? "si" : "no"}
              onChange={(e) => setNuevoComp({ ...nuevoComp, rutina40: e.target.value === "si" })}
            >
              <option value="no">No</option>
              <option value="si">Sí</option>
            </select>
          </label>
          <div style={{ alignSelf: "flex-end" }}>
            <button onClick={() => crearComponente.mutate()}>Crear componente</button>
          </div>
        </div>
      </div>

      <div className="tabla-marco">
        <table>
          <thead>
            <tr>
              {!unidadId && <th>Unidad</th>}
              <th>Cód. equipo</th>
              <th>Cód. interno</th>
              <th>Modelo</th>
              <th>Inicio operación</th>
              <th>Componentes</th>
              <th>Activo</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {(equipos ?? []).map((e) => (
              <tr key={e.id}>
                {!unidadId && <td>{nombreUnidad.get(e.unidad_id)}</td>}
                <td>
                  <Link to={`/equipo/${e.id}`} className="enlace-equipo">{e.cod_interno}</Link>
                </td>
                <td>{e.cod_sap ?? "Sin cód. interno"}</td>
                <td>{e.modelo}</td>
                <td>{fFecha(e.fecha_inicio_operacion)}</td>
                <td style={{ whiteSpace: "normal" }}>
                  {(compPorEquipo.get(e.id) ?? []).map((c) => (
                    <span
                      key={c.id}
                      className="estado sindatos"
                      style={{ marginRight: 6, opacity: c.activo ? 1 : 0.45, cursor: "pointer" }}
                      title={`${c.nombre} · plan ${c.plan_clave}${c.activo ? "" : " · INACTIVO"} (clic para activar/desactivar)`}
                      onClick={() => alternarComp.mutate({ id: c.id, activo: !c.activo })}
                    >
                      {c.tipo_horometro}
                    </span>
                  ))}
                </td>
                <td>
                  <button
                    className="boton-plano"
                    onClick={() => alternarEq.mutate({ id: e.id, activo: !e.activo })}
                  >
                    {e.activo ? "Sí · desactivar" : "No · activar"}
                  </button>
                </td>
                <td>
                  <button className="boton-plano" onClick={() => setEditando(e)}>
                    Editar
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
