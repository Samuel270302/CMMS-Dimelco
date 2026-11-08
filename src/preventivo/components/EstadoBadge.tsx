const CLASES: Record<string, string> = {
  "🔴 Vencido": "estado vencido",
  "📅 Programar": "estado programar",
  "🔧 Verificar repuestos": "estado repuestos",
  "🟢 Normal": "estado normal",
};

export default function EstadoBadge({ estado }: { estado: string | null }) {
  if (!estado) return null;
  const clase = CLASES[estado] ?? "estado sindatos";
  const texto = /^[\u{1F534}\u{1F4C5}\u{1F527}\u{1F7E2}\u{26AA}]/u.test(estado)
    ? estado.slice(estado.indexOf(" ") + 1)
    : estado;
  return <span className={clase}>{texto}</span>;
}
