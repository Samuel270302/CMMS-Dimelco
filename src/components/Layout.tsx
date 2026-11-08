import { useEffect, useState } from "react";
import { NavLink, useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../auth";
import { esDemo, supabase } from "../lib/supabase";
import { FranjaDemo } from "../demo/AyudaDemo";
import { useEstadoConexion } from "../lib/conexion";
import { cambiosPendientes, marcarPendientes } from "../lib/pendientes";
import DialogoConfirmar from "./DialogoConfirmar";
import DialogoContrasena from "./DialogoContrasena";
import AvisoActualizacion from "./AvisoActualizacion";
import { SelectorUnidad } from "../lib/unidad";
import { useAvisos } from "./Avisos";
import { useEsMovil } from "../lib/movil";
import {
  IconoAjustes,
  IconoCalendario,
  IconoCamion,
  IconoGrafica,
  IconoHistorial,
  IconoIndicadores,
  IconoKanban,
  IconoLlave,
  IconoMas,
  IconoPlanilla,
  IconoPrograma,
  IconoReinicio,
  IconoTablero,
  IconoTemporizador,
  IconoUsuarios,
} from "./Iconos";
import logoApp from "../assets/logo-app.svg";

interface Enlace {
  a: string;
  texto: string;
  icono: React.ReactNode;
  captura: boolean;
}

// Backlog (correctivo).
const enlaces: Enlace[] = [
  { a: "/nuevo", texto: "Nuevo backlog", icono: <IconoMas />, captura: true },
  { a: "/flota", texto: "Por equipo", icono: <IconoCamion />, captura: false },
  { a: "/kanban", texto: "Kanban", icono: <IconoKanban />, captura: false },
  { a: "/calendario", texto: "Calendario", icono: <IconoCalendario />, captura: false },
  { a: "/indicadores", texto: "Indicadores backlog", icono: <IconoIndicadores />, captura: false },
  { a: "/capacidad", texto: "Capacidad del taller", icono: <IconoAjustes />, captura: true },
];

// Programación de preventivos y correctivos.
const enlacesProgramacion: Enlace[] = [
  { a: "/programacion", texto: "Tablero semanal", icono: <IconoCalendario />, captura: false },
];

// Preventivo por horómetros.
const enlacesPreventivo: Enlace[] = [
  { a: "/preventivo/control", texto: "Control PM", icono: <IconoTablero />, captura: false },
  { a: "/preventivo/rutina40", texto: "Rutina 40 h", icono: <IconoTemporizador />, captura: false },
  { a: "/preventivo/programa", texto: "Programa 4 semanas", icono: <IconoPrograma />, captura: false },
  { a: "/preventivo/lecturas", texto: "Lecturas", icono: <IconoPlanilla />, captura: true },
  { a: "/preventivo/registro-pm", texto: "Registro PM", icono: <IconoLlave />, captura: true },
  { a: "/preventivo/cambios", texto: "Cambios horómetro", icono: <IconoReinicio />, captura: true },
  { a: "/preventivo/historial", texto: "Historial", icono: <IconoHistorial />, captura: false },
  { a: "/preventivo/graficas", texto: "Gráficas", icono: <IconoGrafica />, captura: false },
  { a: "/preventivo/indicadores", texto: "Indicadores PM", icono: <IconoIndicadores />, captura: false },
];

// Nombre de la pantalla para el encabezado del celular.
function tituloDe(ruta: string): string {
  const todos = [...enlacesProgramacion, ...enlaces, ...enlacesPreventivo, ...enlacesAdmin];
  const exacto = todos.find((e) => e.a === ruta);
  if (exacto) return exacto.texto;
  if (ruta.startsWith("/backlog/")) return "Backlog";
  if (ruta.startsWith("/equipo/")) return "Equipo";
  return "CMMS Dimelco";
}

const NOMBRE_ROL = { admin: "Administrador", capturador: "Capturador", invitado: "Invitado (solo consulta)" };

const enlacesAdmin = [
  { a: "/equipos", texto: "Equipos", icono: <IconoPrograma /> },
  { a: "/preventivo/equipos", texto: "Componentes y horómetros", icono: <IconoTablero /> },
  { a: "/preventivo/plan", texto: "Plan MP", icono: <IconoLlave /> },
  { a: "/catalogos", texto: "Familias y sistemas", icono: <IconoLlave /> },
  { a: "/plazos", texto: "Plazos por prioridad", icono: <IconoCalendario /> },
  { a: "/borrados", texto: "Backlogs borrados", icono: <IconoHistorial /> },
  { a: "/usuarios", texto: "Usuarios", icono: <IconoUsuarios /> },
];

export default function Layout({ children }: { children: React.ReactNode }) {
  const { perfil, esAdmin, puedeCapturar } = useAuth();
  const conexion = useEstadoConexion();
  const navegar = useNavigate();
  const [destino, setDestino] = useState<string | null>(null);
  const [cambiandoClave, setCambiandoClave] = useState(false);
  const [guardandoClave, setGuardandoClave] = useState(false);
  const { avisar } = useAvisos();
  const esMovil = useEsMovil();
  const { pathname } = useLocation();
  const [masAbierto, setMasAbierto] = useState(false);
  useEffect(() => setMasAbierto(false), [pathname]);
  // Barra inferior del celular: Control PM, Lecturas (capturador) o Calendario, Por equipo.
  const barra = [
    enlacesProgramacion[0],
    puedeCapturar && !esAdmin ? enlacesPreventivo[3] : enlaces[3],
    enlaces[1],
  ];

  async function cambiarClave(contrasena: string) {
    setGuardandoClave(true);
    const { error } = await supabase().auth.updateUser({ password: contrasena });
    setGuardandoClave(false);
    if (error) {
      avisar(
        error.message.includes("different from the old")
          ? "La contraseña nueva debe ser distinta de la actual"
          : `No se pudo cambiar la contraseña: ${error.message}`,
        "error"
      );
      return;
    }
    setCambiandoClave(false);
    avisar("Contraseña cambiada");
  }

  function alNavegar(e: React.MouseEvent, a: string) {
    if (cambiosPendientes() > 0) {
      e.preventDefault();
      setDestino(a);
    }
  }
  return (
    <div className="app">
      {cambiandoClave && (
        <DialogoContrasena
          titulo="Cambiar mi contraseña"
          detalle={perfil?.correo ?? undefined}
          boton="Cambiar"
          ocupado={guardandoClave}
          onAceptar={cambiarClave}
          onCerrar={() => setCambiandoClave(false)}
        />
      )}
      {esMovil && (
        <header className="cabecera-movil">
          <img className="logo-app" src={logoApp} alt="" />
          <span>{tituloDe(pathname)}</span>
          <span className={`punto-conexion ${conexion}`} title={conexion} />
        </header>
      )}
      {esMovil && masAbierto && <div className="velo-menu" onClick={() => setMasAbierto(false)} />}
      <aside className={`menu${esMovil ? " menu-movil" : ""}${masAbierto ? " abierto" : ""}`} aria-hidden={esMovil && !masAbierto}>
        <div className="logo">
          <img className="logo-app" src={logoApp} alt="" />
          <div>
            <span className="logo-titulo">CMMS Dimelco</span>
            <span className="logo-sub">Dimelco · mantenimiento</span>
          </div>
        </div>
        <SelectorUnidad />
        <nav>
          <div className="menu-seccion">Programación</div>
          {enlacesProgramacion.map((e) => (
            <NavLink key={e.a} to={e.a} onClick={(ev) => alNavegar(ev, e.a)} className={({ isActive }) => (isActive ? "activo" : "")}>
              {e.icono}
              {e.texto}
            </NavLink>
          ))}
          <div className="menu-seccion">Preventivo</div>
          {enlacesPreventivo.filter((e) => puedeCapturar || !e.captura).map((e) => (
            <NavLink key={e.a} to={e.a} onClick={(ev) => alNavegar(ev, e.a)} className={({ isActive }) => (isActive ? "activo" : "")}>
              {e.icono}
              {e.texto}
            </NavLink>
          ))}
          <div className="menu-seccion">Backlog</div>
          {enlaces.filter((e) => puedeCapturar || !e.captura).map((e) => (
            <NavLink key={e.a} to={e.a} onClick={(ev) => alNavegar(ev, e.a)} className={({ isActive }) => (isActive ? "activo" : "")}>
              {e.icono}
              {e.texto}
            </NavLink>
          ))}
          {esAdmin && (
            <>
              <div className="menu-seccion">Administración</div>
              {enlacesAdmin.map((e) => (
                <NavLink key={e.a} to={e.a} onClick={(ev) => alNavegar(ev, e.a)} className={({ isActive }) => (isActive ? "activo" : "")}>
                  {e.icono}
                  {e.texto}
                </NavLink>
              ))}
            </>
          )}
        </nav>
        <div className="menu-pie">
          <div className="usuario">
            <div>{perfil?.nombre ?? "…"}</div>
            <div className="usuario-rol">{perfil ? NOMBRE_ROL[perfil.rol] : ""}</div>
          </div>
          <button className="boton-plano" onClick={() => setCambiandoClave(true)}>
            Cambiar contraseña
          </button>
          <button className="boton-plano" onClick={() => supabase().auth.signOut()}>
            Cerrar sesión
          </button>
          <div className="pie-estado">
            <span className={`punto-conexion ${conexion}`} />
            {conexion === "en_linea" ? "En línea" : conexion === "reconectando" ? "Reconectando…" : "Sin conexión"}
            <span className="pie-version">v{__APP_VERSION__}</span>
          </div>
        </div>
      </aside>
      {esMovil && (
        <nav className="barra-inferior" aria-label="Navegación principal">
          {barra.map((e) => (
            <NavLink key={e.a} to={e.a} onClick={(ev) => alNavegar(ev, e.a)} className={({ isActive }) => (isActive ? "activo" : "")}>
              {e.icono}
              <span>{e.texto === "Nuevo backlog" ? "Nuevo" : e.texto}</span>
            </NavLink>
          ))}
          <button className={masAbierto ? "activo" : ""} onClick={() => setMasAbierto((x) => !x)} aria-expanded={masAbierto}>
            <IconoAjustes />
            <span>Más</span>
          </button>
        </nav>
      )}
      <main className="contenido">
        {esDemo && <FranjaDemo />}
        <AvisoActualizacion />
        {children}
      </main>
      {destino && (
        <DialogoConfirmar
          titulo="Hay cambios sin grabar"
          texto="Hay datos escritos que todavía no se grabaron. Si sales de la pantalla se pierden."
          confirmar="Salir sin grabar"
          cancelar="Seguir editando"
          onRespuesta={(si) => {
            const a = destino;
            setDestino(null);
            if (si) {
              marcarPendientes(0);
              navegar(a);
            }
          }}
        />
      )}
    </div>
  );
}
