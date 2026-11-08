import { useControl40 } from "../lib/queries";
import { hoyISO, fFecha } from "../../lib/fmt";
import ControlTabla from "../components/ControlTabla";
import { EsqueletoTabla } from "../../components/Esqueleto";
import { useNombreUnidad } from "../../lib/unidad";

export default function Control40() {
  const { data, isLoading, error } = useControl40();
  const unidad = useNombreUnidad();
  if (isLoading) return <EsqueletoTabla />;
  if (error) return <p className="error-texto">Error al cargar: {String(error)}</p>;
  const filas = (data ?? []).slice().sort((a, b) =>
    a.cod_interno.localeCompare(b.cod_interno, "es", { numeric: true }) ||
    a.tipo_horometro.localeCompare(b.tipo_horometro)
  );
  return (
    <>
      <h1>Rutina de percusión 40 h</h1>
      <p className="subtitulo">
        {unidad ?? "Todas las unidades"} · una fila por brazo · cualquier PM reinicia el conteo · al {fFecha(hoyISO())}
      </p>
      <ControlTabla
        filas={filas}
        titulo={`Control de preventivos · ${unidad ? unidad + " · " : ""}Rutina de percusión 40 h`}
        archivo={`Control 40h ${unidad ? unidad + " " : ""}${hoyISO()}.xlsx`}
      />
    </>
  );
}
