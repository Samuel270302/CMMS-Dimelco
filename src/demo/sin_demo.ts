// Reemplaza a ./servidor fuera de la demo (alias en vite.config.ts): así PGlite y los
// datos de prueba no entran en la app de escritorio ni en el sitio normal.
export const baseDemo = async () => {
  throw new Error("La demo no está en esta compilación");
};
export const fetchDemo = fetch;
export const reiniciarDemo = async () => {};
