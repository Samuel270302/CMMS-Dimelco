import { IconoCompresor, IconoDiesel, IconoPerforadora } from "../../components/Iconos";

export interface Sistema {
  seccion: number;
  pestania: string;
  titulo: string;
  icono: React.ReactNode;
}

export const SISTEMAS: Sistema[] = [
  { seccion: 1, pestania: "Motor diésel", titulo: "Motor diésel", icono: <IconoDiesel /> },
  { seccion: 2, pestania: "Compresor", titulo: "Compresor (horómetro motor eléctrico)", icono: <IconoCompresor /> },
  { seccion: 3, pestania: "Perforadoras y empernadoras", titulo: "Perforadoras y empernadoras, MP mayor", icono: <IconoPerforadora /> },
];

export function PestaniasSistema({
  seccion,
  onCambio,
}: {
  seccion: number;
  onCambio: (s: number) => void;
}) {
  return (
    <div className="pestanias">
      {SISTEMAS.map((s) => (
        <button
          key={s.seccion}
          className={`pestania ${s.seccion === seccion ? "activa" : ""}`}
          onClick={() => onCambio(s.seccion)}
        >
          {s.icono}
          {s.pestania}
        </button>
      ))}
    </div>
  );
}
