import { Link } from "react-router-dom";
import { useComponentes } from "../lib/queries";

// Las vistas de control traen el componente; la ficha se abre por equipo.
export default function EnlaceEquipo({ componenteId, texto }: { componenteId: string; texto: string }) {
  const { data: componentes } = useComponentes();
  const equipoId = componentes?.find((c) => c.id === componenteId)?.equipo_id;
  if (!equipoId) return <>{texto}</>;
  return (
    <Link to={`/equipo/${equipoId}`} className="enlace-equipo" title={`Abrir la ficha de ${texto}`}>
      {texto}
    </Link>
  );
}
