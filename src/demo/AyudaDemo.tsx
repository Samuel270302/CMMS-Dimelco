// Ayuda de la demo web: usuarios de prueba en la entrada y franja con «Reiniciar datos».
// La base de la demo se importa solo al reiniciar, así no entra en la app normal.
const USUARIOS = [
  ["admin@prueba", "Administrador, todas las unidades"],
  ["cap@prueba", "Capturador de HEMCO"],
  ["cap.vtn@prueba", "Capturador de Veta Nueva"],
];

async function reiniciar() {
  if (!confirm("Se borran los datos de prueba de este navegador y se vuelven a cargar los iniciales. ¿Seguir?")) return;
  const m = await import("./servidor");
  await m.reiniciarDemo();
}

export default function AyudaDemo() {
  return (
    <div className="ayuda-demo">
      <strong>Demo de pruebas.</strong> Los datos viven solo en este navegador. Contraseña de todos: <code>prueba</code>
      <ul>
        {USUARIOS.map(([c, d]) => (
          <li key={c}>
            <code>{c}</code> {d}
          </li>
        ))}
      </ul>
    </div>
  );
}

export function FranjaDemo() {
  return (
    <div className="franja-demo">
      Demo de pruebas: los datos viven solo en este navegador y no tocan las bases de producción.
      <button className="boton-plano boton-chico" onClick={reiniciar}>
        Reiniciar datos
      </button>
    </div>
  );
}
