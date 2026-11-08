import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo } from "react";
import { supabase } from "../../lib/supabase";
import { reportarCanal } from "../../lib/conexion";
import { useUnidad } from "../../lib/unidad";
import type {
  CambioHorometro,
  ColumnaControl,
  Componente,
  ControlFila,
  CumplimientoPm,
  Equipo,
  LecturaCalc,
  Perfil,
  PlanMp,
  RegistroPm,
  UltimaLectura,
  UtilizacionMes,
} from "./types";

async function todo<T>(tabla: string, orden?: string): Promise<T[]> {
  let q = supabase().from(tabla).select("*");
  if (orden) q = q.order(orden);
  const { data, error } = await q;
  if (error) throw error;
  return data as T[];
}

// Filtro por unidad: el capturador e invitado ya reciben solo su unidad desde la base;
// el admin elige una unidad en el menú y aquí se filtra lo ya descargado.
function usePorUnidad<T extends { unidad_id?: string | null }>() {
  const { unidadId } = useUnidad();
  return useCallback((filas: T[]) => (unidadId ? filas.filter((f) => f.unidad_id === unidadId) : filas), [unidadId]);
}

const consultaEquipos = { queryKey: ["prev:equipos"], queryFn: () => todo<Equipo>("equipos", "cod_interno") };
const consultaComponentes = { queryKey: ["prev:componentes"], queryFn: () => todo<Componente>("componentes") };

// Componentes de la unidad elegida (null = todas).
export function useComponentesUnidad(): Set<string> | null {
  const { unidadId } = useUnidad();
  const { data: equipos } = useQuery(consultaEquipos);
  const { data: componentes } = useQuery(consultaComponentes);
  return useMemo(() => {
    if (!unidadId) return null;
    const eqs = new Set((equipos ?? []).filter((e) => e.unidad_id === unidadId).map((e) => e.id));
    return new Set((componentes ?? []).filter((c) => eqs.has(c.equipo_id)).map((c) => c.id));
  }, [unidadId, equipos, componentes]);
}

function usePorComponente<T extends { componente_id: string }>() {
  const comps = useComponentesUnidad();
  return useCallback((filas: T[]) => (comps ? filas.filter((f) => comps.has(f.componente_id)) : filas), [comps]);
}

export const useControlPm = () =>
  useQuery({
    queryKey: ["prev:v_control_pm"],
    queryFn: () => todo<ControlFila>("v_control_pm"),
    select: usePorUnidad<ControlFila>(),
  });

export const useControl40 = () =>
  useQuery({
    queryKey: ["prev:v_control_40"],
    queryFn: () => todo<ControlFila>("v_control_40"),
    select: usePorUnidad<ControlFila>(),
  });

export const useEquipos = () => useQuery({ ...consultaEquipos, select: usePorUnidad<Equipo>() });

export function useComponentes() {
  const { unidadId } = useUnidad();
  const { data: equipos } = useQuery(consultaEquipos);
  const filtro = useCallback(
    (filas: Componente[]) => {
      if (!unidadId) return filas;
      const eqs = new Set((equipos ?? []).filter((e) => e.unidad_id === unidadId).map((e) => e.id));
      return filas.filter((c) => eqs.has(c.equipo_id));
    },
    [unidadId, equipos]
  );
  return useQuery({ ...consultaComponentes, select: filtro });
}

// Última lectura de cada componente.
export function useUltimasLecturas() {
  const filtro = usePorComponente<UltimaLectura>();
  return useQuery({
    queryKey: ["prev:v_ultima_lectura"],
    queryFn: () => todo<UltimaLectura>("v_ultima_lectura"),
    select: filtro,
  });
}

export const usePlanes = () =>
  useQuery({ queryKey: ["prev:planes_mp"], queryFn: () => todo<PlanMp>("planes_mp", "orden") });

export const useCambios = () =>
  useQuery({
    queryKey: ["prev:cambios_horometro"],
    queryFn: () => todo<CambioHorometro>("cambios_horometro", "vigente_desde"),
    select: usePorComponente<CambioHorometro>(),
  });

export const useColumnas = () =>
  useQuery({
    queryKey: ["prev:columnas_control"],
    queryFn: () => todo<ColumnaControl>("columnas_control", "orden"),
  });

export const useCumplimiento = () =>
  useQuery({
    queryKey: ["prev:v_cumplimiento_pm"],
    queryFn: () => todo<CumplimientoPm>("v_cumplimiento_pm", "fecha"),
    select: usePorUnidad<CumplimientoPm>(),
  });

export const useUtilizacion = () =>
  useQuery({
    queryKey: ["prev:v_utilizacion_mensual"],
    queryFn: () => todo<UtilizacionMes>("v_utilizacion_mensual", "mes"),
    select: usePorUnidad<UtilizacionMes>(),
  });

export const usePerfiles = () =>
  useQuery({ queryKey: ["prev:perfiles"], queryFn: () => todo<Perfil>("perfiles", "nombre") });

export function useLecturasRecientes(limite = 400) {
  const filtro = usePorComponente<LecturaCalc>();
  return useQuery({
    select: filtro,
    queryKey: ["prev:v_lecturas", limite],
    queryFn: async () => {
      const { data, error } = await supabase()
        .from("v_lecturas")
        .select("*")
        .order("num_turno", { ascending: false })
        .limit(limite);
      if (error) throw error;
      return data as LecturaCalc[];
    },
  });
}

type LecturaVentana = Pick<
  LecturaCalc,
  "id" | "componente_id" | "fecha" | "turno" | "lectura" | "lectura_acum" | "num_turno"
>;

export function useLecturasDesde(desde: string) {
  const filtro = usePorComponente<LecturaVentana>();
  return useQuery({
    select: filtro,
    queryKey: ["prev:v_lecturas_desde", desde],
    queryFn: async () => {
      const { data, error } = await supabase()
        .from("v_lecturas")
        .select("id,componente_id,fecha,turno,lectura,lectura_acum,num_turno")
        .gte("fecha", desde)
        .order("num_turno", { ascending: true })
        .limit(5000);
      if (error) throw error;
      return data as LecturaVentana[];
    },
  });
}

export interface PmVentana {
  componente_id: string;
  fecha: string;
  gama: number | null;
  lectura_acum: number | null;
}

export function usePmDesde(desde: string) {
  const filtro = usePorComponente<PmVentana>();
  return useQuery({
    select: filtro,
    queryKey: ["prev:v_registros_pm_desde", desde],
    queryFn: async () => {
      const { data, error } = await supabase()
        .from("v_registros_pm")
        .select("componente_id,fecha,gama,lectura_acum")
        .gte("fecha", desde)
        .order("fecha", { ascending: true })
        .limit(2000);
      if (error) throw error;
      return data as PmVentana[];
    },
  });
}

export function useRegistrosPm(limite = 300) {
  const filtro = usePorComponente<RegistroPm>();
  return useQuery({
    select: filtro,
    queryKey: ["prev:registros_pm", limite],
    queryFn: async () => {
      const { data, error } = await supabase()
        .from("registros_pm")
        .select("*")
        .eq("anulado", false)
        .order("fecha", { ascending: false })
        .limit(limite);
      if (error) throw error;
      return data as RegistroPm[];
    },
  });
}

export function useParametros() {
  return useQuery({
    queryKey: ["prev:parametros"],
    queryFn: () =>
      todo<{
        clave: string;
        valor: number | null;
        valor_texto: string | null;
        descripcion: string | null;
      }>("parametros"),
  });
}

