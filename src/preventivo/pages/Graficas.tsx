import EnlaceEquipo from "../components/EnlaceEquipo";
import { useMemo, useState } from "react";
import { useControlPm, useLecturasDesde, usePmDesde } from "../lib/queries";
import { EsqueletoTabla } from "../../components/Esqueleto";
import { useNombreUnidad } from "../../lib/unidad";
import { fFecha, fNum, hoyISO, sumarDiasISO } from "../../lib/fmt";
import { PestaniasSistema, SISTEMAS } from "../lib/sistemas";
import EstadoBadge from "../components/EstadoBadge";
import GraficaHorometro, { type PuntoHorometro } from "../components/GraficaHorometro";
import type { ControlFila } from "../lib/types";

const VENTANA_DIAS = 30;

interface Serie {
  fila: ControlFila;
  puntos: PuntoHorometro[];
  horas: number | null;
  porDia: number | null;
}

export default function Graficas() {
  const hasta = hoyISO();
  const unidad = useNombreUnidad();
  const desde = sumarDiasISO(hasta, -VENTANA_DIAS);
  const { data: control, isLoading: c1 } = useControlPm();
  const { data: lecturas, isLoading: c2 } = useLecturasDesde(desde);
  const { data: pms } = usePmDesde(desde);
  const [seccion, setSeccion] = useState(1);
  const [vista, setVista] = useState<"graficas" | "tabla">("graficas");

  const series = useMemo<Serie[]>(() => {
    const porComp = new Map<string, PuntoHorometro[]>();
    const ordenadas = (lecturas ?? []).slice().sort((a, b) => a.num_turno - b.num_turno);
    for (const l of ordenadas) {
      if (!porComp.has(l.componente_id)) porComp.set(l.componente_id, []);
      porComp.get(l.componente_id)!.push({
        fecha: l.fecha,
        turno: l.turno,
        acumulado: Number(l.lectura_acum),
        contador: Number(l.lectura),
      });
    }
    return (control ?? [])
      .filter((f) => (f.seccion ?? 0) === seccion)
      .sort(
        (a, b) =>
          a.cod_interno.localeCompare(b.cod_interno, "es", { numeric: true }) ||
          a.tipo_horometro.localeCompare(b.tipo_horometro)
      )
      .map((fila) => {
        const puntos = porComp.get(fila.componente_id) ?? [];
        if (puntos.length < 2) return { fila, puntos, horas: null, porDia: null };
        const primero = puntos[0];
        const ultimo = puntos[puntos.length - 1];
        const horas = ultimo.acumulado - primero.acumulado;
        const dias =
          (new Date(ultimo.fecha).getTime() - new Date(primero.fecha).getTime()) / 86400000 +
          (ultimo.turno === "Noche" ? 0.5 : 0) -
          (primero.turno === "Noche" ? 0.5 : 0);
        return { fila, puntos, horas, porDia: dias > 0 ? horas / dias : null };
      });
  }, [control, lecturas, seccion]);

  const sistema = SISTEMAS.find((s) => s.seccion === seccion)!;

  return (
    <>
      <h1>Evolución de horómetros</h1>
      <p className="subtitulo">
        {unidad ?? "Todas las unidades"} · horómetro acumulado del {fFecha(desde)} al {fFecha(hasta)} (últimos {VENTANA_DIAS} días) ·
        cada gráfica tiene su propia escala
      </p>
      <PestaniasSistema seccion={seccion} onCambio={setSeccion} />
      <div className="barra-acciones">
        <div className="selector-vista">
          <button
            className={vista === "graficas" ? "activo" : ""}
            onClick={() => setVista("graficas")}
          >
            Gráficas
          </button>
          <button className={vista === "tabla" ? "activo" : ""} onClick={() => setVista("tabla")}>
            Tabla
          </button>
        </div>
        <div className="espacio" />
        <span className="nota leyenda-grafica">
          <span className="clave-linea" /> Horómetro acumulado
          <span className="clave-meta" /> Meta del próximo PM
          <span className="clave-pm" /> PM ejecutado
        </span>
      </div>

      {(c1 || c2) && <EsqueletoTabla filas={6} conResumen={false} />}

      {!c1 && !c2 && vista === "graficas" && (
        <div className="rejilla-graficas">
          {series.map(({ fila, puntos, horas, porDia }) => (
            <div className="tarjeta-grafica" key={fila.componente_id}>
              <div className="tg-cabecera">
                <div>
                  <div className="tg-equipo">
                    <EnlaceEquipo componenteId={fila.componente_id} texto={fila.cod_interno} />
                  </div>
                  <div className="tg-componente">{fila.nombre}</div>
                </div>
                <EstadoBadge estado={fila.estado} />
              </div>
              {puntos.length >= 2 ? (
                <GraficaHorometro
                  puntos={puntos}
                  desde={desde}
                  hasta={hasta}
                  meta={fila.meta_acum}
                  pms={(pms ?? []).filter((p) => p.componente_id === fila.componente_id)}
                />
              ) : (
                <div className="tg-vacia">
                  {puntos.length === 1
                    ? "Solo 1 lectura en los últimos 30 días"
                    : "Sin lecturas en los últimos 30 días"}
                </div>
              )}
              <div className="tg-pie">
                <div>
                  <span className="tg-dato">{horas !== null ? `+${fNum(horas)} h` : "Sin dato"}</span>
                  <span className="tg-etiqueta">en 30 días</span>
                </div>
                <div>
                  <span className="tg-dato">{porDia !== null ? `${fNum(porDia, 1)} h/día` : "Sin dato"}</span>
                  <span className="tg-etiqueta">promedio</span>
                </div>
                <MetaPie fila={fila} />
              </div>
            </div>
          ))}
        </div>
      )}

      {!c1 && !c2 && vista === "tabla" && (
        <>
          <div className="titulo-tabla">Evolución de horómetros · {sistema.titulo}</div>
          <div className="tabla-marco">
            <table>
              <thead>
                <tr>
                  <th>Equipo</th>
                  <th>Componente</th>
                  <th className="num">Lecturas</th>
                  <th>Primera</th>
                  <th className="num">Horómetro inicial</th>
                  <th>Última</th>
                  <th className="num">Horómetro final</th>
                  <th className="num">Horas en 30 días</th>
                  <th className="num">Promedio h/día</th>
                  <th className="num">Meta PM</th>
                  <th>Estado</th>
                </tr>
              </thead>
              <tbody>
                {series.map(({ fila, puntos, horas, porDia }) => {
                  const p0 = puntos[0];
                  const p1 = puntos[puntos.length - 1];
                  return (
                    <tr key={fila.componente_id}>
                      <td><EnlaceEquipo componenteId={fila.componente_id} texto={fila.cod_interno} /></td>
                      <td>{fila.nombre}</td>
                      <td className="num">{puntos.length}</td>
                      <td>{p0 ? fFecha(p0.fecha) : ""}</td>
                      <td className="num">{p0 ? fNum(p0.acumulado) : ""}</td>
                      <td>{p1 ? fFecha(p1.fecha) : ""}</td>
                      <td className="num">{p1 ? fNum(p1.acumulado) : ""}</td>
                      <td className="num">{horas !== null ? fNum(horas) : ""}</td>
                      <td className="num">{porDia !== null ? fNum(porDia, 1) : ""}</td>
                      <td className="num">{fNum(fila.meta_acum, 0)}</td>
                      <td>
                        <EstadoBadge estado={fila.estado} />
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}

function MetaPie({ fila }: { fila: ControlFila }) {
  const faltan = fila.hrs_faltantes;
  return (
    <div>
      <span className="tg-dato">{fila.meta_acum !== null ? `${fNum(fila.meta_acum, 0)} h` : "Sin dato"}</span>
      <span className="tg-etiqueta">meta PM</span>
      {faltan !== null &&
        (faltan <= 0 ? (
          <span className="tg-etiqueta tg-superada">superada por {fNum(-faltan, 0)} h</span>
        ) : (
          <span className="tg-etiqueta">faltan {fNum(faltan, 0)} h</span>
        ))}
    </div>
  );
}
