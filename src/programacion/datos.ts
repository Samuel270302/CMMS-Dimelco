import { useQuery, useQueryClient, useMutation } from "@tanstack/react-query";
import { supabase } from "../lib/supabase";
import { usePorUnidad } from "../lib/queries";
import { useAvisos } from "../components/Avisos";
import type { Prioridad } from "../lib/types";

export type TipoOt = "Preventiva" | "Rutina 40 h" | "Correctiva" | "Emergencia";
export type Turno = "Dia" | "Noche";

export interface BacklogEnOt {
  id: string;
  folio: string;
  descripcion: string;
  prioridad: Prioridad;
  estado: string;
  fecha_programada: string | null;
}

export interface Ot {
  id: string;
  folio: string;
  unidad_id: string;
  equipo_id: string;
  tipo: TipoOt;
  componente_id: string | null;
  gama: number | null;
  fecha_estimada_pm: string | null;
  titulo: string;
  prioridad: Prioridad | null;
  estado: string;
  fecha: string;
  turno: Turno;
  reprogramaciones: number;
  cod_interno: string;
  modelo: string;
  flota: string | null;
  componente: string | null;
  unidad: string;
  hh_total: number;
  backlogs: BacklogEnOt[];
  avisos: string;
}

export interface OtHh {
  ot_id: string;
  especialidad_id: string;
  hh: number;
}

export interface OtEvento {
  id: string;
  ot_id: string;
  tipo: string;
  texto: string | null;
  creado_en: string;
}

export interface Pauta {
  plan_clave: string;
  gama: number | null;
  especialidad_id: string;
  hh: number;
}

async function datos<T>(q: PromiseLike<{ data: unknown; error: unknown }>): Promise<T> {
  const { data, error } = await q;
  if (error) throw error;
  return data as T;
}

// OT de la semana (sin las anuladas).
export const useOtsSemana = (desde: string, hasta: string) =>
  useQuery({
    queryKey: ["ot-semana", desde, hasta],
    queryFn: () =>
      datos<Ot[]>(
        supabase().from("v_ot").select("*").gte("fecha", desde).lte("fecha", hasta)
          .in("estado", ["Programada", "En ejecución", "Ejecutada", "Cerrada"]).order("fecha")
      ),
    select: usePorUnidad<Ot>(),
  });

export const useOtHh = (ids: string[]) => {
  const clave = [...ids].sort().join(",");
  return useQuery({
    queryKey: ["ot-hh", clave],
    enabled: ids.length > 0,
    queryFn: () => datos<OtHh[]>(supabase().from("v_ot_hh").select("*").in("ot_id", ids)),
  });
};

export const useEventosOt = (id: string | null) =>
  useQuery({
    queryKey: ["ot-eventos", id],
    enabled: !!id,
    queryFn: () => datos<OtEvento[]>(supabase().from("ot_eventos").select("*").eq("ot_id", id!).order("creado_en")),
  });

// PM con OT abierta (en cualquier fecha): no se sugieren otra vez.
export const usePmConOt = () =>
  useQuery({
    queryKey: ["ot-pm-abiertas"],
    queryFn: () =>
      datos<{ componente_id: string; tipo: TipoOt; folio: string; fecha: string }[]>(
        supabase().from("ordenes_trabajo").select("componente_id,tipo,folio,fecha")
          .in("estado", ["Programada", "En ejecución"]).not("componente_id", "is", null)
      ),
  });

// Backlogs que ya están en una OT.
export const useBacklogsEnOt = () =>
  useQuery({
    queryKey: ["ot-backlogs"],
    queryFn: () => datos<{ backlog_id: string; ot_id: string }[]>(supabase().from("ot_backlogs").select("backlog_id,ot_id")),
  });

export const usePautas = () =>
  useQuery({ queryKey: ["pautas_gama"], queryFn: () => datos<Pauta[]>(supabase().from("pautas_gama").select("*")) });

// HH estándar de un PM según la pauta: las de la gama y, para las especialidades que la
// gama no tiene, las generales del plan (igual que programar_pm en la base).
export function hhDePauta(pautas: Pauta[] | undefined, plan: string | null, gama: number | null): Map<string, number> {
  const m = new Map<string, number>();
  if (!plan) return m;
  const delPlan = (pautas ?? []).filter((p) => p.plan_clave === plan);
  for (const p of delPlan) if (p.gama === null) m.set(p.especialidad_id, Number(p.hh));
  for (const p of delPlan) if (gama !== null && Number(p.gama) === Number(gama)) m.set(p.especialidad_id, Number(p.hh));
  return m;
}

// Acciones del tablero: cada una llama a su función en la base y recarga.
export function useAccionesOt() {
  const qc = useQueryClient();
  const { avisar } = useAvisos();
  return useMutation({
    mutationFn: async ({ fn, args }: { fn: string; args: Record<string, unknown>; aviso: string }) => {
      const { error } = await supabase().rpc(fn, args);
      if (error) throw new Error(error.message);
    },
    onSuccess: (_d, v) => {
      avisar(v.aviso);
      qc.invalidateQueries();
    },
    onError: (e: Error) => avisar(e.message, "error"),
  });
}
