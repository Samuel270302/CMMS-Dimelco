import { useEffect, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import type { Componente, Equipo, PlanMp } from "../lib/types";
import { useAvisos } from "../../components/Avisos";
import { useUnidades } from "../../lib/unidad";

export const SISTEMAS_COMPONENTE = ["Motor Diésel", "Compresor", "Perforadora", "Empernadora"];
export const SECCIONES = [
  { valor: 1, texto: "1 Diésel" },
  { valor: 2, texto: "2 Compresor" },
  { valor: 3, texto: "3 Perf/Emp" },
];

// Edición del maestro (solo admin): datos del equipo y de cada componente.
// El tipo de horómetro no se edita: cambiarlo movería el historial de lecturas.
export default function EditorEquipo({
  equipo,
  componentes,
  planes,
  onCerrar,
}: {
  equipo: Equipo;
  componentes: Componente[];
  planes: PlanMp[];
  onCerrar: () => void;
}) {
  const qc = useQueryClient();
  const { avisar } = useAvisos();
  const [eq, setEq] = useState(equipo);
  const { data: unidades } = useUnidades();
  const [comps, setComps] = useState(componentes);
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);

  const cambiarComp = (id: string, cambio: Partial<Componente>) =>
    setComps((cs) => cs.map((c) => (c.id === id ? { ...c, ...cambio } : c)));

  const guardar = useMutation({
    mutationFn: async () => {
      if (!eq.cod_interno.trim() || !eq.modelo.trim())
        throw new Error("Código de equipo y modelo son obligatorios");
      if (comps.some((c) => !c.nombre.trim()))
        throw new Error("Cada componente necesita un nombre");
      const { error } = await supabase()
        .from("equipos")
        .update({
          cod_interno: eq.cod_interno.trim(),
          cod_sap: eq.cod_sap?.trim() || null,
          modelo: eq.modelo.trim(),
          fecha_inicio_operacion: eq.fecha_inicio_operacion || null,
          unidad_id: eq.unidad_id,
        })
        .eq("id", eq.id);
      if (error) throw error;
      const originales = new Map(componentes.map((c) => [c.id, c]));
      const cambiados = comps.filter((c) => JSON.stringify(c) !== JSON.stringify(originales.get(c.id)));
      for (const c of cambiados) {
        const { error: e } = await supabase()
          .from("componentes")
          .update({
            nombre: c.nombre.trim(),
            sistema: c.sistema,
            seccion: c.seccion,
            cod_sap: c.cod_sap?.trim() || null,
            plan_clave: c.plan_clave,
            aplica_rutina40: c.aplica_rutina40,
            activo: c.activo,
          })
          .eq("id", c.id);
        if (e) throw new Error(`${c.tipo_horometro}: ${e.message}`);
      }
      return cambiados.length;
    },
    onSuccess: (n) => {
      avisar(`Equipo ${eq.cod_interno} guardado${n ? ` · ${n} componente(s) actualizado(s)` : ""}`);
      qc.invalidateQueries();
      onCerrar();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  return (
    <dialog
      ref={ref}
      className="dialogo-ancho"
      onCancel={(e) => {
        e.preventDefault();
        onCerrar();
      }}
    >
      <h1 style={{ fontSize: 16 }}>Editar {equipo.cod_interno}</h1>
      <div className="fila-campos">
        <label className="campo">
          <span>Unidad</span>
          <select value={eq.unidad_id} onChange={(e) => setEq({ ...eq, unidad_id: e.target.value })}>
            {(unidades ?? []).map((u) => (
              <option key={u.id} value={u.id}>{u.nombre}</option>
            ))}
          </select>
        </label>
        <label className="campo">
          <span>Cód. equipo</span>
          <input value={eq.cod_interno} onChange={(e) => setEq({ ...eq, cod_interno: e.target.value })} />
        </label>
        <label className="campo">
          <span>Modelo</span>
          <input value={eq.modelo} onChange={(e) => setEq({ ...eq, modelo: e.target.value })} />
        </label>
        <label className="campo">
          <span>Cód. interno</span>
          <input value={eq.cod_sap ?? ""} onChange={(e) => setEq({ ...eq, cod_sap: e.target.value })} />
        </label>
        <label className="campo">
          <span>Inicio de operación</span>
          <input
            type="date"
            value={eq.fecha_inicio_operacion ?? ""}
            onChange={(e) => setEq({ ...eq, fecha_inicio_operacion: e.target.value || null })}
          />
        </label>
      </div>

      <div className="titulo-tabla" style={{ marginTop: 6 }}>Componentes</div>
      <div className="tabla-marco">
        <table className="tabla-edicion">
          <thead>
            <tr>
              <th>Horómetro</th>
              <th>Nombre en el control</th>
              <th>Sistema</th>
              <th>Sección</th>
              <th>Plan MP</th>
              <th>Cód. interno</th>
              <th>Rutina 40 h</th>
              <th>Activo</th>
            </tr>
          </thead>
          <tbody>
            {comps.map((c) => (
              <tr key={c.id}>
                <td>{c.tipo_horometro}</td>
                <td>
                  <input
                    aria-label={`Nombre ${c.tipo_horometro}`}
                    value={c.nombre}
                    onChange={(e) => cambiarComp(c.id, { nombre: e.target.value })}
                  />
                </td>
                <td>
                  <select value={c.sistema} onChange={(e) => cambiarComp(c.id, { sistema: e.target.value })}>
                    {SISTEMAS_COMPONENTE.map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>
                </td>
                <td>
                  <select
                    value={c.seccion}
                    onChange={(e) => cambiarComp(c.id, { seccion: Number(e.target.value) })}
                  >
                    {SECCIONES.map((s) => (
                      <option key={s.valor} value={s.valor}>
                        {s.texto}
                      </option>
                    ))}
                  </select>
                </td>
                <td>
                  <select
                    value={c.plan_clave ?? ""}
                    onChange={(e) => cambiarComp(c.id, { plan_clave: e.target.value || null })}
                  >
                    <option value="">Sin plan</option>
                    {planes
                      .filter((p) => p.clave !== "RUTINA-40")
                      .map((p) => (
                        <option key={p.clave}>{p.clave}</option>
                      ))}
                  </select>
                </td>
                <td>
                  <input
                    style={{ width: 110 }}
                    value={c.cod_sap ?? ""}
                    onChange={(e) => cambiarComp(c.id, { cod_sap: e.target.value })}
                  />
                </td>
                <td className="centro">
                  <input
                    type="checkbox"
                    checked={c.aplica_rutina40}
                    onChange={(e) => cambiarComp(c.id, { aplica_rutina40: e.target.checked })}
                  />
                </td>
                <td className="centro">
                  <input
                    type="checkbox"
                    checked={c.activo}
                    onChange={(e) => cambiarComp(c.id, { activo: e.target.checked })}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {comps.length === 0 && <p className="nota">Este equipo no tiene componentes.</p>}

      <div className="barra-acciones" style={{ marginBottom: 0, marginTop: 14 }}>
        <span className="nota">Un componente inactivo sale de los controles y de la captura.</span>
        <div className="espacio" />
        <button className="boton-plano" onClick={onCerrar}>
          Cancelar
        </button>
        <button onClick={() => guardar.mutate()} disabled={guardar.isPending}>
          {guardar.isPending ? "Guardando…" : "Guardar"}
        </button>
      </div>
    </dialog>
  );
}
