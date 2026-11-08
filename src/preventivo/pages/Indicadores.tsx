import { useMemo, useState } from "react";
import { useControlPm, useCumplimiento, useUtilizacion } from "../lib/queries";
import { fFecha, fNum, gamaTexto, hoyISO } from "../../lib/fmt";
import { SISTEMAS } from "../lib/sistemas";
import EnlaceEquipo from "../components/EnlaceEquipo";
import { EsqueletoTabla } from "../../components/Esqueleto";
import { useNombreUnidad } from "../../lib/unidad";
import type { CumplimientoPm } from "../lib/types";

const MESES_GRAFICA = 12;
const MESES_TABLA = 6;
const NOMBRE_MES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
// Una lectura está al día si tiene 2 días o menos.
const DIAS_AL_DIA = 2;

function mesesHasta(hoy: string, n: number) {
  const [a, m] = hoy.split("-").map(Number);
  return Array.from({ length: n }, (_, k) => {
    const d = new Date(a, m - 1 - (n - 1 - k), 1);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-01`;
  });
}
const etiquetaMes = (mes: string) => `${NOMBRE_MES[Number(mes.slice(5, 7)) - 1]} ${mes.slice(2, 4)}`;

interface ResumenMes {
  mes: string;
  aTiempo: number;
  conMeta: number;
  sinMeta: number;
}

function resumir(filas: CumplimientoPm[], mes: string): ResumenMes {
  const delMes = filas.filter((f) => f.mes.slice(0, 10) === mes);
  return {
    mes,
    aTiempo: delMes.filter((f) => f.a_tiempo === true).length,
    conMeta: delMes.filter((f) => f.a_tiempo !== null).length,
    sinMeta: delMes.filter((f) => f.a_tiempo === null).length,
  };
}
const pct = (r: { aTiempo: number; conMeta: number }) => (r.conMeta ? (100 * r.aTiempo) / r.conMeta : null);

export default function Indicadores() {
  const hoy = hoyISO();
  const unidad = useNombreUnidad();
  const { data: cumplimiento, isLoading: c1 } = useCumplimiento();
  const { data: utilizacion, isLoading: c2 } = useUtilizacion();
  const { data: control, isLoading: c3 } = useControlPm();

  const meses = useMemo(() => mesesHasta(hoy, MESES_GRAFICA), [hoy]);
  const mesesTabla = meses.slice(-MESES_TABLA);
  const filasCump = cumplimiento ?? [];
  const porMes = meses.map((m) => resumir(filasCump, m));

  const ultimos3 = porMes.slice(-3).reduce(
    (t, r) => ({ aTiempo: t.aTiempo + r.aTiempo, conMeta: t.conMeta + r.conMeta, sinMeta: t.sinMeta + r.sinMeta }),
    { aTiempo: 0, conMeta: 0, sinMeta: 0 }
  );

  const vencidos = (control ?? [])
    .filter((f) => f.estado.includes("Vencido") && f.hrs_faltantes !== null)
    .sort((a, b) => (a.hrs_faltantes ?? 0) - (b.hrs_faltantes ?? 0));
  const atrasoAbierto = vencidos.reduce((s, f) => s + Math.max(-(f.hrs_faltantes ?? 0), 0), 0);

  const atrasados = filasCump
    .filter((f) => f.mes.slice(0, 10) >= meses[0] && (f.horas_atraso ?? 0) > 0)
    .sort((a, b) => (b.horas_atraso ?? 0) - (a.horas_atraso ?? 0));

  const lecturasAtrasadas = (control ?? [])
    .filter((f) => f.antiguedad_dias === null || f.antiguedad_dias > DIAS_AL_DIA)
    .sort((a, b) => (b.antiguedad_dias ?? 9999) - (a.antiguedad_dias ?? 9999));
  const totalComp = (control ?? []).length;
  const alDia = totalComp - lecturasAtrasadas.length;

  const mesActual = meses[meses.length - 1];
  const utilMes = (utilizacion ?? []).filter((u) => u.mes.slice(0, 10) === mesActual && u.h_dia !== null);
  const utilFlota = utilMes.length ? utilMes.reduce((s, u) => s + Number(u.h_dia), 0) / utilMes.length : null;

  if (c1 || c2 || c3) return <EsqueletoTabla />;

  return (
    <>
      <h1>Indicadores de gestión</h1>
      <p className="subtitulo">
        {unidad ?? "Todas las unidades"} · PM mayor contra la meta de horas del plan · utilización a partir de las lecturas · al {fFecha(hoy)}
      </p>

      <div className="resumen resumen-4">
        <Indicador
          valor={pct(ultimos3) !== null ? `${fNum(pct(ultimos3), 0)} %` : "Sin dato"}
          titulo="Cumplimiento del plan, últimos 3 meses"
          detalle={`${ultimos3.aTiempo} de ${ultimos3.conMeta} PM antes de la meta${ultimos3.sinMeta ? ` · ${ultimos3.sinMeta} sin meta` : ""}`}
        />
        <Indicador
          valor={`${fNum(atrasoAbierto, 0)} h`}
          titulo="Atraso de los PM vencidos abiertos"
          detalle={`${vencidos.length} componente(s) vencido(s)`}
          clase="alerta"
        />
        <Indicador
          valor={utilFlota !== null ? `${fNum(utilFlota, 1)} h/día` : "Sin dato"}
          titulo={`Utilización media, ${etiquetaMes(mesActual)}`}
          detalle={`${utilMes.length} componente(s) con lecturas en el mes`}
        />
        <Indicador
          valor={totalComp ? `${fNum((100 * alDia) / totalComp, 0)} %` : "Sin dato"}
          titulo="Lecturas al día (hasta 2 días)"
          detalle={`${alDia} de ${totalComp} componentes`}
          clase={alDia < totalComp ? "alerta" : ""}
        />
      </div>

      <section className="panel-indicador">
        <div className="titulo-seccion">Cumplimiento del plan por mes</div>
        <p className="nota">
          PM mayor ejecutado antes de pasar su meta (PM anterior + intervalo del plan). Los PM sin lectura propia o
          sin lectura en el PM anterior no tienen meta y no entran al porcentaje.
        </p>
        <GraficaCumplimiento datos={porMes} />
      </section>

      <div className="titulo-tabla">Cumplimiento por sistema · últimos {MESES_TABLA} meses</div>
      <div className="tabla-marco" style={{ marginBottom: 16 }}>
        <table>
          <thead>
            <tr>
              <th>Sistema</th>
              {mesesTabla.map((m) => (
                <th key={m} className="num">
                  {etiquetaMes(m)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {SISTEMAS.map((s) => (
              <tr key={s.seccion}>
                <td>{s.pestania}</td>
                {mesesTabla.map((m) => {
                  const r = resumir(
                    filasCump.filter((f) => f.seccion === s.seccion),
                    m
                  );
                  const p = pct(r);
                  return (
                    <td key={m} className="num" title={`${r.aTiempo} de ${r.conMeta} con meta · ${r.sinMeta} sin meta`}>
                      {p === null ? (r.sinMeta ? "Sin meta" : "") : `${fNum(p, 0)} % (${r.aTiempo}/${r.conMeta})`}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="pila-tablas">
        <div>
          <div className="titulo-tabla">PM ejecutados después de la meta · {MESES_GRAFICA} meses</div>
          <div className="tabla-marco">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Equipo</th>
                  <th>Componente</th>
                  <th className="num">Gama</th>
                  <th className="num">Meta</th>
                  <th className="num">Ejecutado a</th>
                  <th className="num">Atraso</th>
                </tr>
              </thead>
              <tbody>
                {atrasados.map((f) => (
                  <tr key={`${f.componente_id}-${f.fecha}`}>
                    <td>{fFecha(f.fecha)}</td>
                    <td>
                      <EnlaceEquipo componenteId={f.componente_id} texto={f.cod_interno} />
                    </td>
                    <td>{f.nombre}</td>
                    <td className="num">{gamaTexto(f.gama)}</td>
                    <td className="num">{fNum(f.meta_acum, 0)}</td>
                    <td className="num">{fNum(f.lectura_acum)}</td>
                    <td className="num control-error">{fNum(f.horas_atraso)} h</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {atrasados.length === 0 && <p className="nota grupo-vacio">Ningún PM se ejecutó después de su meta.</p>}
          </div>
        </div>
        <div>
          <div className="titulo-tabla">PM vencidos abiertos</div>
          <div className="tabla-marco">
            <table>
              <thead>
                <tr>
                  <th>Equipo</th>
                  <th>Componente</th>
                  <th className="num">Próxima gama</th>
                  <th className="num">Meta</th>
                  <th className="num">Actual</th>
                  <th className="num">Atraso</th>
                </tr>
              </thead>
              <tbody>
                {vencidos.map((f) => (
                  <tr key={f.componente_id}>
                    <td>
                      <EnlaceEquipo componenteId={f.componente_id} texto={f.cod_interno} />
                    </td>
                    <td>{f.nombre}</td>
                    <td className="num">{gamaTexto(f.proxima_gama)}</td>
                    <td className="num">{fNum(f.meta_acum, 0)}</td>
                    <td className="num">{fNum(f.ultima_lectura_acum)}</td>
                    <td className="num control-error">{fNum(-(f.hrs_faltantes ?? 0))} h</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {vencidos.length === 0 && <p className="nota grupo-vacio">No hay PM vencidos.</p>}
          </div>
        </div>
      </div>

      <TablaUtilizacion meses={mesesTabla} />

      <div className="titulo-tabla" style={{ marginTop: 16 }}>
        Componentes con más de 2 días sin lectura · {lecturasAtrasadas.length}
      </div>
      <div className="tabla-marco">
        <table>
          <thead>
            <tr>
              <th>Equipo</th>
              <th>Componente</th>
              <th>Última lectura</th>
              <th className="num">Días sin lectura</th>
            </tr>
          </thead>
          <tbody>
            {lecturasAtrasadas.map((f) => (
              <tr key={f.componente_id}>
                <td>
                  <EnlaceEquipo componenteId={f.componente_id} texto={f.cod_interno} />
                </td>
                <td>{f.nombre}</td>
                <td>{f.fecha_ultima_lectura ? fFecha(f.fecha_ultima_lectura) : "Sin lecturas"}</td>
                <td className="num">{f.antiguedad_dias ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {lecturasAtrasadas.length === 0 && <p className="nota grupo-vacio">Todos los componentes están al día.</p>}
      </div>
    </>
  );
}

function Indicador({ valor, titulo, detalle, clase = "" }: { valor: string; titulo: string; detalle: string; clase?: string }) {
  return (
    <div className={`chip indicador ${clase}`}>
      <span className="n">{valor}</span>
      <span className="t">{titulo}</span>
      <span className="d">{detalle}</span>
    </div>
  );
}

// Columnas de un solo color (una serie): la escala va de 0 a 100 % y cada columna
// lleva su porcentaje encima; el detalle va en el tooltip.
function GraficaCumplimiento({ datos }: { datos: ResumenMes[] }) {
  const [activo, setActivo] = useState<number | null>(null);
  const ANCHO = 760;
  const ALTO = 220;
  const M = { izq: 40, der: 8, arr: 22, aba: 26 };
  const banda = (ANCHO - M.izq - M.der) / datos.length;
  const barra = Math.min(24, banda * 0.6);
  const y = (v: number) => M.arr + (ALTO - M.arr - M.aba) * (1 - v / 100);
  const base = y(0);
  return (
    <div className="grafica grafica-cumplimiento" onMouseLeave={() => setActivo(null)}>
      <svg viewBox={`0 0 ${ANCHO} ${ALTO}`} role="img" aria-label="Cumplimiento del plan por mes">
        {[0, 50, 100].map((v) => (
          <g key={v}>
            <line className="grafica-grilla" x1={M.izq} x2={ANCHO - M.der} y1={y(v)} y2={y(v)} />
            <text className="grafica-eje" x={M.izq - 6} y={y(v) + 3} textAnchor="end">
              {v} %
            </text>
          </g>
        ))}
        {datos.map((d, k) => {
          const x = M.izq + banda * k + banda / 2;
          const p = pct(d);
          const tope = p === null ? base : y(p);
          const alto = base - tope;
          return (
            <g key={d.mes} onMouseEnter={() => setActivo(k)}>
              <rect x={x - banda / 2} y={M.arr} width={banda} height={ALTO - M.arr - M.aba} fill="transparent" />
              {p !== null && alto > 0 && (
                <path
                  className="barra-cumplimiento"
                  d={`M${x - barra / 2},${base} V${tope + Math.min(4, alto)} q0,-4 4,-4 H${x + barra / 2 - 4} q4,0 4,4 V${base} Z`}
                />
              )}
              <text className="grafica-valor" x={x} y={(p === null ? base : tope) - 6} textAnchor="middle">
                {p === null ? (d.sinMeta ? "s/m" : "") : `${fNum(p, 0)} %`}
              </text>
              <text className="grafica-eje" x={x} y={ALTO - 8} textAnchor="middle">
                {etiquetaMes(d.mes)}
              </text>
            </g>
          );
        })}
      </svg>
      {activo !== null && (
        <div
          className="grafica-tooltip"
          style={{
            left: `${((M.izq + banda * activo + banda / 2) / ANCHO) * 100}%`,
            transform: activo > datos.length * 0.6 ? "translateX(calc(-100% - 14px))" : "translateX(14px)",
          }}
        >
          <div className="tt-valor">{etiquetaMes(datos[activo].mes)}</div>
          <div className="tt-sub">
            {datos[activo].conMeta
              ? `${datos[activo].aTiempo} de ${datos[activo].conMeta} PM antes de la meta`
              : "Sin PM con meta"}
          </div>
          {datos[activo].sinMeta > 0 && <div className="tt-sub">{datos[activo].sinMeta} PM sin meta</div>}
        </div>
      )}
      <p className="nota">s/m: hubo PM en el mes, pero ninguno con meta calculable.</p>
    </div>
  );
}

function TablaUtilizacion({ meses }: { meses: string[] }) {
  const { data } = useUtilizacion();
  const filas = useMemo(() => {
    const m = new Map<string, { id: string; equipo: string; nombre: string; seccion: number; valores: Map<string, number | null> }>();
    for (const u of data ?? []) {
      if (!m.has(u.componente_id))
        m.set(u.componente_id, { id: u.componente_id, equipo: u.cod_interno, nombre: u.nombre, seccion: u.seccion, valores: new Map() });
      m.get(u.componente_id)!.valores.set(u.mes.slice(0, 10), u.h_dia);
    }
    return [...m.values()]
      .filter((f) => meses.some((mes) => f.valores.has(mes)))
      .sort((a, b) => a.seccion - b.seccion || a.equipo.localeCompare(b.equipo, "es", { numeric: true }));
  }, [data, meses]);
  return (
    <>
      <div className="titulo-tabla">Utilización por componente (h/día) · últimos {meses.length} meses</div>
      <div className="tabla-marco">
        <table>
          <thead>
            <tr>
              <th>Equipo</th>
              <th>Componente</th>
              {meses.map((m) => (
                <th key={m} className="num">
                  {etiquetaMes(m)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <tr key={f.id}>
                <td>
                  <EnlaceEquipo componenteId={f.id} texto={f.equipo} />
                </td>
                <td>{f.nombre}</td>
                {meses.map((m) => (
                  <td key={m} className="num">
                    {f.valores.has(m) ? fNum(f.valores.get(m), 1) : ""}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="nota">
        Horas de cada intervalo entre lecturas divididas por los días del intervalo; un intervalo que cruza de mes
        cuenta en el mes de la lectura que lo cierra. Celda vacía: sin lecturas ese mes.
      </p>
    </>
  );
}
