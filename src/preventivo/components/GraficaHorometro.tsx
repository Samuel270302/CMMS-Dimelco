import { useMemo, useRef, useState } from "react";
import { fFecha, fNum } from "../../lib/fmt";

export interface PuntoHorometro {
  fecha: string;
  turno: string;
  acumulado: number;
  contador: number;
}

const ANCHO = 360;
const ALTO = 150;
const M = { izq: 46, der: 12, arr: 10, aba: 22 };
const DIA_MS = 86400000;

// La línea usa un ámbar más oscuro que el del libro (#F5B301): sobre blanco,
// #F5B301 no llega a contraste 3:1; #B07800 sí. El ámbar claro queda como relleno.
const COLOR_LINEA = "#B07800";
const COLOR_RELLENO = "#F5B301";
const COLOR_META = "#9C0006";

function tiempo(p: { fecha: string; turno: string }) {
  return new Date(p.fecha + "T00:00:00").getTime() + (p.turno === "Noche" ? DIA_MS / 2 : 0);
}

function pasoLimpio(rango: number, divisiones: number) {
  const bruto = rango / divisiones;
  const mag = Math.pow(10, Math.floor(Math.log10(bruto)));
  const r = bruto / mag;
  return (r <= 1 ? 1 : r <= 2 ? 2 : r <= 5 ? 5 : 10) * mag;
}

function etiquetaEje(v: number) {
  return fNum(v, 0);
}

export default function GraficaHorometro({
  puntos,
  desde,
  hasta,
  meta,
  pms = [],
}: {
  puntos: PuntoHorometro[];
  desde: string;
  hasta: string;
  meta: number | null;
  pms?: { fecha: string; gama: number | null; lectura_acum: number | null }[];
}) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [activo, setActivo] = useState<number | null>(null);

  const g = useMemo(() => {
    const t0 = new Date(desde + "T00:00:00").getTime();
    const t1 = new Date(hasta + "T00:00:00").getTime() + DIA_MS;
    const ys = puntos.map((p) => p.acumulado);
    let yMin = Math.min(...ys);
    let yMax = Math.max(...ys);
    const tramo = Math.max(yMax - yMin, 20);
    // La meta entra a la escala solo si está cerca de los datos; si no, aplastaría la línea.
    const metaVisible = meta !== null && meta >= yMin - tramo && meta <= yMax + tramo;
    if (metaVisible) {
      yMin = Math.min(yMin, meta!);
      yMax = Math.max(yMax, meta!);
    }
    // Igual que la meta: un PM con lectura muy alejada de los datos no se dibuja.
    const pmsVisibles = pms.filter(
      (p) => p.lectura_acum !== null && p.lectura_acum >= yMin - tramo && p.lectura_acum <= yMax + tramo
    );
    for (const p of pmsVisibles) {
      yMin = Math.min(yMin, p.lectura_acum!);
      yMax = Math.max(yMax, p.lectura_acum!);
    }
    if (yMax - yMin < 10) {
      yMin -= 5;
      yMax += 5;
    }
    const paso = pasoLimpio(yMax - yMin, 3);
    yMin = Math.floor(yMin / paso) * paso;
    yMax = Math.ceil(yMax / paso) * paso;
    const ticks: number[] = [];
    for (let v = yMin; v <= yMax + paso / 2; v += paso) ticks.push(v);

    const x = (t: number) => M.izq + ((t - t0) / (t1 - t0)) * (ANCHO - M.izq - M.der);
    const y = (v: number) => ALTO - M.aba - ((v - yMin) / (yMax - yMin)) * (ALTO - M.arr - M.aba);
    const xy = puntos.map((p) => ({ px: x(tiempo(p)), py: y(p.acumulado) }));
    const linea = xy.map((c, i) => `${i ? "L" : "M"}${c.px.toFixed(1)},${c.py.toFixed(1)}`).join("");
    const base = ALTO - M.aba;
    const area = xy.length
      ? `${linea}L${xy[xy.length - 1].px.toFixed(1)},${base}L${xy[0].px.toFixed(1)},${base}Z`
      : "";
    const mitad = new Date((t0 + t1) / 2);
    const etiquetasX = [
      { px: x(t0), texto: fFecha(desde).slice(0, 5), ancla: "start" as const },
      { px: x(mitad.getTime()), texto: fFecha(mitad.toISOString().slice(0, 10)).slice(0, 5), ancla: "middle" as const },
      { px: x(t1 - DIA_MS), texto: fFecha(hasta).slice(0, 5), ancla: "end" as const },
    ];
    const marcasPm = pmsVisibles.map((p) => ({
      px: x(new Date(p.fecha + "T12:00:00").getTime()),
      py: y(p.lectura_acum!),
      gama: p.gama,
      fecha: p.fecha,
    }));
    return { xy, linea, area, ticks, y, metaVisible, etiquetasX, marcasPm };
  }, [puntos, desde, hasta, meta, pms]);

  function mover(e: React.PointerEvent<SVGSVGElement>) {
    const svg = svgRef.current;
    if (!svg || g.xy.length === 0) return;
    const r = svg.getBoundingClientRect();
    const px = ((e.clientX - r.left) / r.width) * ANCHO;
    let mejor = 0;
    g.xy.forEach((c, i) => {
      if (Math.abs(c.px - px) < Math.abs(g.xy[mejor].px - px)) mejor = i;
    });
    setActivo(mejor);
  }

  const ultimo = g.xy[g.xy.length - 1];
  const sel = activo !== null ? puntos[activo] : null;
  const selXY = activo !== null ? g.xy[activo] : null;

  return (
    <div className="grafica">
      <svg
        ref={svgRef}
        viewBox={`0 0 ${ANCHO} ${ALTO}`}
        role="img"
        aria-label="Evolución del horómetro acumulado"
        onPointerMove={mover}
        onPointerLeave={() => setActivo(null)}
      >
        {g.ticks.map((v) => (
          <g key={v}>
            <line x1={M.izq} x2={ANCHO - M.der} y1={g.y(v)} y2={g.y(v)} className="grafica-grilla" />
            <text x={M.izq - 6} y={g.y(v) + 3.5} textAnchor="end" className="grafica-eje">
              {etiquetaEje(v)}
            </text>
          </g>
        ))}
        {g.etiquetasX.map((t) => (
          <text key={t.texto + t.ancla} x={t.px} y={ALTO - 6} textAnchor={t.ancla} className="grafica-eje">
            {t.texto}
          </text>
        ))}
        {g.metaVisible && meta !== null && (
          <g>
            <line
              x1={M.izq}
              x2={ANCHO - M.der}
              y1={g.y(meta)}
              y2={g.y(meta)}
              stroke={COLOR_META}
              strokeWidth={1}
              strokeDasharray="4 3"
            />
            <text x={ANCHO - M.der - 2} y={g.y(meta) - 4} textAnchor="end" className="grafica-meta">
              Meta PM {fNum(meta, 0)} h
            </text>
          </g>
        )}
        <path d={g.area} fill={COLOR_RELLENO} opacity={0.12} />
        <path d={g.linea} fill="none" stroke={COLOR_LINEA} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
        {g.marcasPm.map((m) => (
          <g key={m.fecha + m.gama}>
            <path
              d={`M${m.px},${m.py - 6}L${m.px + 6},${m.py}L${m.px},${m.py + 6}L${m.px - 6},${m.py}Z`}
              fill="#252525"
              stroke="#ffffff"
              strokeWidth={2}
            />
            <text x={m.px} y={m.py - 10} textAnchor="middle" className="grafica-pm">
              PM {m.gama ?? "s/g"}
            </text>
          </g>
        ))}
        {ultimo && <circle cx={ultimo.px} cy={ultimo.py} r={4} fill={COLOR_LINEA} stroke="#ffffff" strokeWidth={2} />}
        {selXY && (
          <g>
            <line x1={selXY.px} x2={selXY.px} y1={M.arr} y2={ALTO - M.aba} className="grafica-cruz" />
            <circle cx={selXY.px} cy={selXY.py} r={4.5} fill={COLOR_LINEA} stroke="#ffffff" strokeWidth={2} />
          </g>
        )}
      </svg>
      {sel && selXY && (
        <div
          className="grafica-tooltip"
          style={{
            left: `${(selXY.px / ANCHO) * 100}%`,
            transform: selXY.px > ANCHO * 0.6 ? "translateX(calc(-100% - 10px))" : "translateX(10px)",
          }}
        >
          <div className="tt-valor">{fNum(sel.acumulado)} h</div>
          <div className="tt-linea">
            <span className="tt-clave" />
            {fFecha(sel.fecha)} · {sel.turno}
          </div>
          {sel.contador !== sel.acumulado && <div className="tt-sub">Contador {fNum(sel.contador)} h</div>}
          {pms
            .filter((p) => p.fecha === sel.fecha)
            .map((p) => (
              <div key={p.fecha + p.gama} className="tt-sub tt-pm">
                PM gama {p.gama ?? "sin gama"} ejecutado este día
              </div>
            ))}
        </div>
      )}
    </div>
  );
}
