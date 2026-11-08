import { useEffect, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { useParametros, usePlanes } from "../lib/queries";
import type { PlanMp } from "../lib/types";
import { useAvisos } from "../../components/Avisos";

export default function PlanMpPage() {
  const qc = useQueryClient();
  const { data: planes } = usePlanes();
  const { data: parametros } = useParametros();
  const [editando, setEditando] = useState<PlanMp | null>(null);
  // Plan nuevo: vacío o copiado de otro, con la clave por escribir.
  const [esNuevo, setEsNuevo] = useState(false);
  const { avisar } = useAvisos();

  const abrirNuevo = (base?: PlanMp) => {
    const orden = Math.max(0, ...(planes ?? []).map((p) => p.orden)) + 1;
    setEsNuevo(true);
    setEditando(
      base
        ? { ...base, clave: "", componente_desc: base.componente_desc, orden }
        : { clave: "", sistema: "Motor Diésel", componente_desc: null, aplica_a: null, tipo_horometro_desc: null,
            intervalo_h: 250, ciclo_gamas: [], dias_programar: 10, dias_verificar: 28, base_sin_pm: null,
            kits_sap: null, observaciones: null, orden },
    );
  };
  const cerrar = () => {
    setEditando(null);
    setEsNuevo(false);
  };

  const crear = useMutation({
    mutationFn: async (p: PlanMp) => {
      const clave = p.clave.trim().toUpperCase();
      if (!clave) throw new Error("Escriba la clave del plan");
      if ((planes ?? []).some((x) => x.clave.toUpperCase() === clave)) throw new Error(`Ya existe el plan ${clave}`);
      if (!p.sistema.trim()) throw new Error("Escriba el sistema del plan");
      if (!(p.intervalo_h > 0)) throw new Error("El intervalo debe ser mayor que 0");
      const { error } = await supabase().from("planes_mp").insert({
        clave,
        sistema: p.sistema.trim(),
        componente_desc: p.componente_desc?.trim() || null,
        aplica_a: p.aplica_a,
        tipo_horometro_desc: p.tipo_horometro_desc,
        intervalo_h: p.intervalo_h,
        ciclo_gamas: p.ciclo_gamas,
        dias_programar: p.dias_programar,
        dias_verificar: p.dias_verificar,
        base_sin_pm: p.base_sin_pm,
        kits_sap: p.kits_sap,
        observaciones: p.observaciones,
        orden: p.orden,
      });
      if (error) throw error;
      return clave;
    },
    onSuccess: (clave) => {
      cerrar();
      avisar(`Plan ${clave} creado: asígnelo a los componentes en Equipos`);
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  const guardar = useMutation({
    mutationFn: async (p: PlanMp) => {
      const { error } = await supabase()
        .from("planes_mp")
        .update({
          sistema: p.sistema,
          componente_desc: p.componente_desc,
          intervalo_h: p.intervalo_h,
          ciclo_gamas: p.ciclo_gamas,
          dias_programar: p.dias_programar,
          dias_verificar: p.dias_verificar,
          base_sin_pm: p.base_sin_pm,
          kits_sap: p.kits_sap,
          observaciones: p.observaciones,
        })
        .eq("clave", p.clave);
      if (error) throw error;
    },
    onSuccess: () => {
      cerrar();
      avisar("Plan actualizado: el control se recalcula al instante");
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  const guardarParam = useMutation({
    mutationFn: async ({ clave, valor }: { clave: string; valor: number }) => {
      const { error } = await supabase().from("parametros").update({ valor }).eq("clave", clave);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries(),
  });

  return (
    <>
      <div className="cabecera-pagina">
        <div style={{ flex: 1 }}>
          <h1>Plan de mantenimiento preventivo</h1>
          <p className="subtitulo">
            El ciclo de gamas se lee de izquierda a derecha y vuelve a empezar al final. La clave del
            plan no se cambia: los componentes la referencian.
          </p>
        </div>
        <button className="boton-secundario" onClick={() => abrirNuevo()}>
          Nuevo plan
        </button>
      </div>
      <div className="tabla-marco" style={{ marginBottom: 18 }}>
        <table>
          <thead>
            <tr>
              <th>Clave</th>
              <th>Sistema</th>
              <th>Componente / modelo</th>
              <th className="num">Intervalo (h)</th>
              <th>Ciclo de gamas</th>
              <th className="num">Programar ≤ (días)</th>
              <th className="num">Verificar repuestos ≤ (días)</th>
              <th className="num">Base sin PM (h)</th>
              <th>Kit de mantenimiento</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {(planes ?? []).map((p) => (
              <tr key={p.clave}>
                <td>{p.clave}</td>
                <td>{p.sistema}</td>
                <td style={{ whiteSpace: "normal", maxWidth: 220 }}>{p.componente_desc}</td>
                <td className="num">{p.intervalo_h}</td>
                <td>{p.ciclo_gamas.join(" - ")}</td>
                <td className="num">{p.dias_programar}</td>
                <td className="num">{p.dias_verificar}</td>
                <td className="num">{p.base_sin_pm ?? ""}</td>
                <td style={{ whiteSpace: "normal", maxWidth: 220 }}>{p.kits_sap}</td>
                <td style={{ whiteSpace: "nowrap" }}>
                  <button className="boton-plano" onClick={() => setEditando({ ...p })}>
                    Editar
                  </button>{" "}
                  <button className="boton-plano" title="Crear un plan nuevo a partir de este" onClick={() => abrirNuevo(p)}>
                    Copiar
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2 style={{ fontSize: 15 }}>Parámetros generales</h2>
      <div className="tabla-marco" style={{ maxWidth: 720 }}>
        <table>
          <tbody>
            {(parametros ?? [])
              .filter((p) => p.clave !== "fecha_referencia")
              .map((p) => (
                <tr key={p.clave}>
                  <td style={{ whiteSpace: "normal" }}>{p.descripcion ?? p.clave}</td>
                  <td className="num" style={{ width: 120 }}>
                    <input
                      style={{ width: 90, textAlign: "right" }}
                      defaultValue={p.valor ?? ""}
                      onBlur={(e) => {
                        const v = Number(e.target.value);
                        if (!isNaN(v) && v !== Number(p.valor))
                          guardarParam.mutate({ clave: p.clave, valor: v });
                      }}
                    />
                  </td>
                </tr>
              ))}
          </tbody>
        </table>
      </div>

      {editando && (
        <EditorPlan
          plan={editando}
          nuevo={esNuevo}
          sistemas={[...new Set((planes ?? []).map((p) => p.sistema))]}
          ocupado={crear.isPending || guardar.isPending}
          onCambio={setEditando}
          onGuardar={() => (esNuevo ? crear.mutate(editando) : guardar.mutate(editando))}
          onCerrar={cerrar}
        />
      )}
    </>
  );
}

function EditorPlan({
  plan,
  nuevo,
  sistemas,
  ocupado,
  onCambio,
  onGuardar,
  onCerrar,
}: {
  plan: PlanMp;
  nuevo: boolean;
  sistemas: string[];
  ocupado: boolean;
  onCambio: (p: PlanMp) => void;
  onGuardar: () => void;
  onCerrar: () => void;
}) {
  const [gamasTexto, setGamasTexto] = useState(plan.ciclo_gamas.join(", "));
  // Abierto como modal: con el atributo open el diálogo queda en el flujo de la
  // página, debajo de las tablas y fuera de la vista.
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      onCancel={(e) => {
        e.preventDefault();
        onCerrar();
      }}
    >
      <h1 style={{ fontSize: 16 }}>{nuevo ? "Nuevo plan de MP" : `Editar plan ${plan.clave}`}</h1>
      {nuevo && (
        <label className="campo">
          <span>Clave (por ejemplo DIESEL-LI; no se puede cambiar después)</span>
          <input
            autoFocus
            value={plan.clave}
            onChange={(e) => onCambio({ ...plan, clave: e.target.value.toUpperCase().replace(/\s+/g, "-") })}
          />
        </label>
      )}
      <div className="fila-campos">
        <label className="campo">
          <span>Sistema</span>
          <input list="sistemas-plan" value={plan.sistema} onChange={(e) => onCambio({ ...plan, sistema: e.target.value })} />
          <datalist id="sistemas-plan">
            {sistemas.map((s) => (
              <option key={s} value={s} />
            ))}
          </datalist>
        </label>
        <label className="campo">
          <span>Componente / modelo</span>
          <input
            value={plan.componente_desc ?? ""}
            onChange={(e) => onCambio({ ...plan, componente_desc: e.target.value })}
          />
        </label>
      </div>
      <label className="campo">
        <span>Intervalo (h)</span>
        <input
          value={plan.intervalo_h}
          onChange={(e) => onCambio({ ...plan, intervalo_h: Number(e.target.value) || 0 })}
        />
      </label>
      <label className="campo">
        <span>Ciclo de gamas (separadas por coma, en orden)</span>
        <input
          value={gamasTexto}
          onChange={(e) => {
            setGamasTexto(e.target.value);
            const gamas = e.target.value
              .split(",")
              .map((s) => Number(s.trim()))
              .filter((n) => !isNaN(n) && n > 0);
            onCambio({ ...plan, ciclo_gamas: gamas });
          }}
        />
      </label>
      <div className="fila-campos">
        <label className="campo">
          <span>Programar ≤ (días)</span>
          <input
            value={plan.dias_programar}
            onChange={(e) => onCambio({ ...plan, dias_programar: Number(e.target.value) || 0 })}
          />
        </label>
        <label className="campo">
          <span>Verificar repuestos ≤ (días)</span>
          <input
            value={plan.dias_verificar}
            onChange={(e) => onCambio({ ...plan, dias_verificar: Number(e.target.value) || 0 })}
          />
        </label>
        <label className="campo">
          <span>Base sin PM (h)</span>
          <input
            value={plan.base_sin_pm ?? ""}
            onChange={(e) =>
              onCambio({ ...plan, base_sin_pm: e.target.value === "" ? null : Number(e.target.value) })
            }
          />
        </label>
      </div>
      <label className="campo">
        <span>Kit de mantenimiento</span>
        <input
          value={plan.kits_sap ?? ""}
          onChange={(e) => onCambio({ ...plan, kits_sap: e.target.value })}
        />
      </label>
      <label className="campo">
        <span>Observaciones</span>
        <textarea
          rows={2}
          value={plan.observaciones ?? ""}
          onChange={(e) => onCambio({ ...plan, observaciones: e.target.value })}
        />
      </label>
      <div className="barra-acciones" style={{ marginBottom: 0 }}>
        <div className="espacio" />
        <button className="boton-plano" onClick={onCerrar}>
          Cancelar
        </button>
        <button onClick={onGuardar} disabled={ocupado || plan.ciclo_gamas.length === 0 || (nuevo && !plan.clave.trim())}>
          {nuevo ? "Crear plan" : "Guardar"}
        </button>
      </div>
    </dialog>
  );
}
