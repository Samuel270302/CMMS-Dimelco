import { useEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../auth";
import {
  useComponentes,
  useEquipos,
  useUltimasLecturas,
} from "../lib/queries";
import { fFecha, fNum, hoyISO } from "../../lib/fmt";
import type { Componente, Turno, UltimaLectura } from "../lib/types";
import { useAvisos } from "../../components/Avisos";
import { marcarPendientes } from "../../lib/pendientes";

interface Validacion {
  clave: string;
  nivel: "ok" | "aviso" | "error";
  mensaje: string;
}

export default function Lecturas() {
  const { session } = useAuth();
  const qc = useQueryClient();
  const { data: equipos } = useEquipos();
  const { data: componentes } = useComponentes();
  const { data: ultimas } = useUltimasLecturas();

  const [fecha, setFecha] = useState(hoyISO());
  const [turno, setTurno] = useState<Turno>("Dia");
  const [capturas, setCapturas] = useState<Record<string, string>>({});
  const nPendientes = Object.values(capturas).filter((v) => v.trim() !== "").length;
  useEffect(() => {
    marcarPendientes(nPendientes);
  }, [nPendientes]);
  useEffect(() => () => marcarPendientes(0), []);

  // Enter pasa a la casilla siguiente, como en una planilla.
  function siguienteCasilla(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key !== "Enter") return;
    e.preventDefault();
    const casillas = Array.from(document.querySelectorAll<HTMLInputElement>("input.casilla-lectura"));
    const i = casillas.indexOf(e.currentTarget);
    casillas[i + 1]?.focus();
    casillas[i + 1]?.select();
  }
  const { avisar } = useAvisos();

  // El control vive en la base (validar_lectura): la pantalla lo consulta mientras se
  // escribe y la base lo vuelve a aplicar al grabar. Se guarda por fila con la clave
  // de lo consultado para no repetir consultas de filas que no cambiaron.
  const [validaciones, setValidaciones] = useState<Record<string, Validacion>>({});
  const cache = useRef(new Map<string, Validacion>());
  const claveDe = (id: string, texto: string) => `${id}|${fecha}|${turno}|${texto.trim()}`;

  useEffect(() => {
    let vigente = true;
    const t = setTimeout(async () => {
      const res: Record<string, Validacion> = {};
      await Promise.all(
        Object.entries(capturas)
          .filter(([, texto]) => texto.trim() !== "")
          .map(async ([id, texto]) => {
            const clave = claveDe(id, texto);
            const lect = Number(texto.replace(",", "."));
            if (isNaN(lect)) {
              res[id] = { clave, nivel: "error", mensaje: "Escriba un número" };
              return;
            }
            const guardada = cache.current.get(clave);
            if (guardada) {
              res[id] = guardada;
              return;
            }
            const { data, error } = await supabase().rpc("validar_lectura", {
              p_componente: id,
              p_fecha: fecha,
              p_turno: turno,
              p_lectura: lect,
            });
            const v: Validacion = error
              ? { clave, nivel: "aviso", mensaje: "No se pudo validar: revise la conexión" }
              : { clave, ...(data as { nivel: Validacion["nivel"]; mensaje: string }) };
            if (!error) cache.current.set(clave, v);
            res[id] = v;
          })
      );
      if (vigente) setValidaciones(res);
    }, 350);
    return () => {
      vigente = false;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [capturas, fecha, turno]);

  function validacionDe(id: string): Validacion | "validando" | null {
    const texto = capturas[id] ?? "";
    if (texto.trim() === "") return null;
    const v = validaciones[id];
    return v && v.clave === claveDe(id, texto) ? v : "validando";
  }

  const porComponente = useMemo(
    () => new Map((ultimas ?? []).map((l) => [l.componente_id, l])),
    [ultimas]
  );

  const filas = useMemo(() => {
    if (!equipos || !componentes) return [];
    // Solo equipos activos: un equipo fuera de servicio no se captura.
    const nombreEq = new Map(equipos.filter((e) => e.activo).map((e) => [e.id, e.cod_interno]));
    return componentes
      .filter((c) => c.activo && nombreEq.has(c.equipo_id))
      .map((c) => ({ comp: c, equipo: nombreEq.get(c.equipo_id) ?? "" }))
      .sort(
        (a, b) =>
          a.equipo.localeCompare(b.equipo, "es", { numeric: true }) ||
          a.comp.tipo_horometro.localeCompare(b.comp.tipo_horometro)
      );
  }, [equipos, componentes]);

  function ultima(c: Componente): UltimaLectura | undefined {
    return porComponente.get(c.id);
  }

  const grabar = useMutation({
    mutationFn: async () => {
      const inserciones: { comp: Componente; lectura: number }[] = [];
      for (const { comp } of filas) {
        const texto = capturas[comp.id];
        if (!texto || texto.trim() === "") continue;
        const lect = Number(texto.replace(",", "."));
        if (isNaN(lect)) throw new Error(`Lectura inválida en ${comp.nombre}`);
        const res = validacionDe(comp.id);
        if (res === "validando") throw new Error("Espere a que termine la validación de las lecturas");
        if (res?.nivel === "error") throw new Error(`${comp.nombre}: ${res.mensaje}`);
        inserciones.push({ comp, lectura: lect });
      }
      if (inserciones.length === 0) throw new Error("No hay lecturas para grabar");
      const { error } = await supabase()
        .from("lecturas")
        .insert(
          inserciones.map((ins) => ({
            componente_id: ins.comp.id,
            fecha,
            turno,
            lectura: ins.lectura,
            origen: "app",
            creado_por: session?.user.id,
          }))
        );
      if (error) throw error;
      return inserciones.length;
    },
    onSuccess: (n) => {
      setCapturas({});
      cache.current.clear();
      avisar(`${n} lectura(s) grabada(s)`);
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });

  return (
    <>
      <h1>Captura de lecturas de horómetro</h1>
      <p className="subtitulo">
        Se escribe lo que marca el contador al cierre del turno, nunca horas acumuladas.
      </p>
      <div className="panel-formulario panel-grabar">
        <div className="fila-campos">
          <label className="campo" style={{ maxWidth: 170 }}>
            <span>Fecha</span>
            <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} />
          </label>
          <label className="campo" style={{ maxWidth: 130 }}>
            <span>Turno</span>
            <select value={turno} onChange={(e) => setTurno(e.target.value as Turno)}>
              <option>Dia</option>
              <option>Noche</option>
            </select>
          </label>
          <div style={{ alignSelf: "flex-end" }}>
            <button onClick={() => grabar.mutate()} disabled={grabar.isPending}>
              {grabar.isPending ? "Grabando…" : "Grabar lecturas"}
            </button>
          </div>
        </div>
      </div>
      <div className="tabla-marco">
        <table className="tabla-lecturas">
          <thead>
            <tr>
              <th>Equipo</th>
              <th>Horómetro</th>
              <th className="num">Última lectura</th>
              <th>Fecha últ.</th>
              <th className="num" style={{ width: 130 }}>
                Nueva lectura
              </th>
              <th>Control</th>
            </tr>
          </thead>
          <tbody>
            {filas.map(({ comp, equipo }) => {
              const u = ultima(comp);
              const texto = capturas[comp.id] ?? "";
              const res = validacionDe(comp.id);
              return (
                <tr key={comp.id} className={texto.trim() !== "" ? "fila-con-valor" : ""}>
                  <td className="c-equipo">{equipo}</td>
                  <td className="c-horo">{comp.tipo_horometro}</td>
                  <td className="num c-ultima">{u ? fNum(u.lectura) : "Sin lecturas"}</td>
                  <td className="c-fecha">{u ? `${fFecha(u.fecha)} ${u.turno}` : ""}</td>
                  <td className="num c-nueva">
                    <input
                      className="casilla-lectura"
                      inputMode="decimal"
                      aria-label={`Nueva lectura ${equipo} ${comp.tipo_horometro}`}
                      style={{ width: 110, textAlign: "right" }}
                      value={texto}
                      onKeyDown={siguienteCasilla}
                      onChange={(e) => setCapturas({ ...capturas, [comp.id]: e.target.value })}
                    />
                  </td>
                  <td className="c-control">
                    {res === "validando" ? (
                      <span className="nota">Validando…</span>
                    ) : (
                      res && <span className={`control-${res.nivel}`}>{res.mensaje}</span>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
