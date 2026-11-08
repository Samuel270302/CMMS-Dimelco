import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import FichaBacklog from "./FichaEquipo";
import FichaPreventivo from "../preventivo/pages/FichaEquipo";

// Ficha del equipo en el CMMS: la parte de preventivo (horómetros, PM, gráfica) y la de
// backlog (trabajos pendientes y cerrados) en pestañas. Las dos leen el mismo equipo.
type Pestania = "preventivo" | "backlog";
const CLAVE = "cmms.ficha.pestania";

function leer(): Pestania {
  try {
    return localStorage.getItem(CLAVE) === "backlog" ? "backlog" : "preventivo";
  } catch {
    return "preventivo";
  }
}

// Los enlaces desde backlog abren con ?vista=backlog; los de preventivo, sin nada.
export default function FichaEquipoCmms() {
  const [params] = useSearchParams();
  const pedida = params.get("vista");
  const [pestania, setPestania] = useState<Pestania>(() =>
    pedida === "backlog" || pedida === "preventivo" ? pedida : leer()
  );
  useEffect(() => {
    if (pedida === "backlog" || pedida === "preventivo") setPestania(pedida);
  }, [pedida]);
  function elegir(p: Pestania) {
    setPestania(p);
    try {
      localStorage.setItem(CLAVE, p);
    } catch {
      // sin almacenamiento: queda solo en esta vista
    }
  }
  return (
    <>
      <div className="pestanias">
        <button className={`pestania ${pestania === "preventivo" ? "activa" : ""}`} onClick={() => elegir("preventivo")}>
          Preventivo
        </button>
        <button className={`pestania ${pestania === "backlog" ? "activa" : ""}`} onClick={() => elegir("backlog")}>
          Backlog
        </button>
      </div>
      {pestania === "preventivo" ? <FichaPreventivo /> : <FichaBacklog />}
    </>
  );
}
