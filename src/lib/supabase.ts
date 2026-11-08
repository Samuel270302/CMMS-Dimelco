import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { leerConexion } from "./config";

// Demo web (VITE_DEMO=1): la base corre en el navegador y responde a través de fetchDemo.
export const esDemo = import.meta.env.VITE_DEMO === "1";
let fetchDemo: typeof fetch | null = null;
export async function prepararDemo() {
  if (!esDemo || fetchDemo) return;
  const m = await import("../demo/servidor");
  await m.baseDemo();
  fetchDemo = m.fetchDemo as typeof fetch;
}

let cliente: SupabaseClient | null = null;

export function supabase(): SupabaseClient {
  if (!cliente) {
    const cfg = leerConexion();
    if (!cfg) throw new Error("Sin configuración de conexión");
    cliente = createClient(cfg.url, cfg.anonKey, {
      auth: { persistSession: true, autoRefreshToken: true },
      ...(esDemo && fetchDemo ? { global: { fetch: fetchDemo } } : {}),
    });
  }
  return cliente;
}

export function reiniciarCliente() {
  cliente = null;
}
