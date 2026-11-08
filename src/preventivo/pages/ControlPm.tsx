import { useState } from "react";
import { useControl40, useControlPm } from "../lib/queries";
import { hoyISO, fFecha } from "../../lib/fmt";
import { reporteSemanal } from "../lib/reporte";
import { PestaniasSistema, SISTEMAS } from "../lib/sistemas";
import ControlTabla from "../components/ControlTabla";
import { EsqueletoTabla } from "../../components/Esqueleto";
import { useAvisos } from "../../components/Avisos";
import { useNombreUnidad } from "../../lib/unidad";

export default function ControlPm() {
  const { data, isLoading, error } = useControlPm();
  const { data: r40 } = useControl40();
  const [seccion, setSeccion] = useState(1);
  const { avisar } = useAvisos();
  const unidad = useNombreUnidad();
  if (isLoading) return <EsqueletoTabla />;
  if (error) return <p className="error-texto">Error al cargar: {String(error)}</p>;
  const todas = (data ?? []).slice().sort((a, b) =>
    a.cod_interno.localeCompare(b.cod_interno, "es", { numeric: true }) ||
    a.tipo_horometro.localeCompare(b.tipo_horometro)
  );
  const sistema = SISTEMAS.find((s) => s.seccion === seccion)!;
  const filas = todas.filter((f) => (f.seccion ?? 0) === seccion);
  return (
    <>
      <div className="cabecera-pagina">
        <div style={{ flex: 1 }}>
          <h1>Control y proyección de mantenimientos preventivos</h1>
          <p className="subtitulo">{unidad ?? "Todas las unidades"} · PM mayor por horómetro · al {fFecha(hoyISO())}</p>
        </div>
        <button
          className="boton-secundario"
          onClick={async () => {
            try {
              const ruta = await reporteSemanal(todas, r40 ?? [], unidad);
              if (ruta) avisar(`Reporte guardado en ${ruta}`);
            } catch (e) {
              avisar(`No se pudo generar el reporte: ${String(e)}`, "error");
            }
          }}
        >
          Reporte semanal (PDF)
        </button>
      </div>
      <PestaniasSistema seccion={seccion} onCambio={setSeccion} />
      <ControlTabla
        filas={filas}
        titulo={`Control de preventivos · ${unidad ? unidad + " · " : ""}${sistema.titulo}`}
        archivo={`Control PM ${unidad ? unidad + " " : ""}${sistema.pestania} ${hoyISO()}.xlsx`}
      />
    </>
  );
}
