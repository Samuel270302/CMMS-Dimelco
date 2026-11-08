export type TipoHorometro =
  | "Diesel"
  | "Motor Eléctrico"
  | "Percusión #1"
  | "Percusión #2"
  | "Empernado";

export type Turno = "Dia" | "Noche";

export interface Unidad {
  id: string;
  nombre: string;
  activo: boolean;
  orden: number;
}

export interface Equipo {
  id: string;
  unidad_id: string;
  cod_interno: string;
  cod_sap: string | null;
  modelo: string;
  fecha_inicio_operacion: string | null;
  activo: boolean;
}

export interface Componente {
  id: string;
  equipo_id: string;
  tipo_horometro: TipoHorometro;
  nombre: string;
  sistema: string;
  seccion: number;
  cod_sap: string | null;
  plan_clave: string | null;
  aplica_rutina40: boolean;
  lectura_manual: boolean;
  activo: boolean;
}

export interface PlanMp {
  clave: string;
  sistema: string;
  componente_desc: string | null;
  aplica_a: string | null;
  tipo_horometro_desc: string | null;
  intervalo_h: number;
  ciclo_gamas: number[];
  dias_programar: number;
  dias_verificar: number;
  base_sin_pm: number | null;
  kits_sap: string | null;
  observaciones: string | null;
  orden: number;
}

export interface Lectura {
  id: string;
  componente_id: string;
  fecha: string;
  turno: Turno;
  lectura: number;
  origen: "app" | "import" | "manual";
  anulada: boolean;
  creado_por: string | null;
  creado_en: string;
}

export interface LecturaCalc extends Lectura {
  num_turno: number;
  turnos_transcurridos: number | null;
  horas_intervalo: number | null;
  lectura_acum: number;
  control: string;
}

export interface RegistroPm {
  id: string;
  componente_id: string;
  fecha: string;
  gama: number | null;
  lectura: number | null;
  responsable: string | null;
  creado_por: string | null;
  creado_en: string;
}

// Campos de anulación que solo se leen de las tablas (las vistas excluyen lo anulado).
export interface Anulacion {
  motivo_anulacion: string | null;
  anulado_por: string | null;
  anulado_en: string | null;
}

export interface CambioHorometro {
  id: string;
  componente_id: string;
  vigente_desde: string;
  offset_h: number;
  ultima_lectura_vieja: string | null;
  primera_lectura_nueva: string | null;
  metodo: string | null;
  fuente: string | null;
  estado: "Por validar" | "Validado";
  creado_en: string;
}

export interface ControlFila {
  componente_id: string;
  cod_interno: string;
  cod_sap: string | null;
  modelo: string;
  nombre: string;
  sistema: string;
  seccion?: number;
  tipo_horometro: TipoHorometro;
  plan_clave?: string;
  fecha_ultimo_pm: string | null;
  gama_ultimo_pm: number | null;
  horometro_ultimo_pm: number | null;
  proxima_gama: string | number | null;
  meta_acum: number | null;
  meta_contador: number | null;
  ultima_lectura_acum: number | null;
  ultima_lectura_contador: number | null;
  fecha_ultima_lectura: string | null;
  antiguedad_dias: number | null;
  hrs_faltantes: number | null;
  tendencia: number | null;
  dias_restantes: number | null;
  fecha_estimada: string | null;
  estado: string;
  observacion: string;
  unidad_id?: string | null;
  unidad?: string | null;
}

export interface UltimaLectura {
  componente_id: string;
  fecha: string;
  turno: Turno;
  lectura: number;
  lectura_acum: number;
  num_turno: number;
}

export interface ColumnaControl {
  columna: string;
  etiqueta: string;
  visible: boolean;
  orden: number;
}

export interface Perfil {
  user_id: string;
  nombre: string;
  correo: string | null;
  rol: "admin" | "capturador" | "invitado";
  activo: boolean;
  unidad_id: string | null;
  // Unidades que ve un capturador o invitado (app 0.6.0); el admin las ve todas.
  unidades?: string[] | null;
}

export interface CumplimientoPm {
  componente_id: string;
  equipo_id: string;
  cod_interno: string;
  nombre: string;
  tipo_horometro: TipoHorometro;
  sistema: string;
  seccion: number;
  fecha: string;
  mes: string;
  gama: number | null;
  lectura_acum: number | null;
  fecha_anterior: string | null;
  meta_acum: number | null;
  horas_atraso: number | null;
  a_tiempo: boolean | null;
  unidad_id?: string | null;
  unidad?: string | null;
}

export interface UtilizacionMes {
  componente_id: string;
  equipo_id: string;
  cod_interno: string;
  nombre: string;
  tipo_horometro: TipoHorometro;
  seccion: number;
  mes: string;
  horas: number;
  dias: number;
  h_dia: number | null;
  lecturas: number;
  unidad_id?: string | null;
  unidad?: string | null;
}
