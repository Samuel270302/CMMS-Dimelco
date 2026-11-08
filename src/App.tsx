import { useState } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { leerConexion } from "./lib/config";
import { supabase } from "./lib/supabase";
import { AuthProvider, useAuth } from "./auth";
import { useTiempoReal } from "./lib/queries";
import { UnidadProvider } from "./lib/unidad";
import Layout from "./components/Layout";
import { AvisosProvider } from "./components/Avisos";
import Setup from "./pages/Setup";
import Login from "./pages/Login";
import Usuarios from "./pages/Usuarios";
import NuevoBacklog from "./pages/NuevoBacklog";
import FichaBacklog from "./pages/FichaBacklog";
import Kanban from "./pages/Kanban";
import PorEquipo from "./pages/PorEquipo";
import FichaEquipo from "./pages/FichaEquipoCmms";
import Calendario from "./pages/Calendario";
import Borrados from "./pages/Borrados";
import Capacidad from "./pages/Capacidad";
import Indicadores from "./pages/Indicadores";
import Equipos from "./pages/Equipos";
import Catalogos from "./pages/Catalogos";
import Parametros from "./pages/Parametros";
import ControlPm from "./preventivo/pages/ControlPm";
import Control40 from "./preventivo/pages/Control40";
import Graficas from "./preventivo/pages/Graficas";
import Programa from "./preventivo/pages/Programa";
import IndicadoresPm from "./preventivo/pages/Indicadores";
import Lecturas from "./preventivo/pages/Lecturas";
import RegistroPm from "./preventivo/pages/RegistroPm";
import Cambios from "./preventivo/pages/Cambios";
import Historial from "./preventivo/pages/Historial";
import EquiposPm from "./preventivo/pages/Equipos";
import PlanMp from "./preventivo/pages/PlanMp";

function Interior() {
  const { session, perfil, cargando, esAdmin, puedeCapturar } = useAuth();
  if (cargando) return <div className="pantalla-centro">Cargando…</div>;
  if (!session) return <Login />;
  if (!perfil?.activo) return <AccesoPendiente correo={session.user.email ?? ""} />;
  return (
    <UnidadProvider>
      <ConRealtime esAdmin={esAdmin} puedeCapturar={puedeCapturar} />
    </UnidadProvider>
  );
}

function AccesoPendiente({ correo }: { correo: string }) {
  return (
    <div className="pantalla-centro">
      <div className="tarjeta">
        <h1>Acceso pendiente de activación</h1>
        <p className="nota" style={{ marginBottom: 14 }}>
          La cuenta {correo} existe, pero un administrador todavía no la activa ni le asigna rol.
          Pídele al administrador que la active en la pantalla Usuarios.
        </p>
        <button className="boton-plano" style={{ width: "100%" }} onClick={() => supabase().auth.signOut()}>
          Cerrar sesión
        </button>
      </div>
    </div>
  );
}

function ConRealtime({ esAdmin, puedeCapturar }: { esAdmin: boolean; puedeCapturar: boolean }) {
  useTiempoReal();
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Navigate to="/preventivo/control" replace />} />
        <Route path="/preventivo/control" element={<ControlPm />} />
        <Route path="/preventivo/rutina40" element={<Control40 />} />
        <Route path="/preventivo/graficas" element={<Graficas />} />
        <Route path="/preventivo/programa" element={<Programa />} />
        <Route path="/preventivo/indicadores" element={<IndicadoresPm />} />
        {puedeCapturar && <Route path="/preventivo/lecturas" element={<Lecturas />} />}
        {puedeCapturar && <Route path="/preventivo/registro-pm" element={<RegistroPm />} />}
        {puedeCapturar && <Route path="/preventivo/cambios" element={<Cambios />} />}
        <Route path="/preventivo/historial" element={<Historial />} />
        {esAdmin && <Route path="/preventivo/equipos" element={<EquiposPm />} />}
        {esAdmin && <Route path="/preventivo/plan" element={<PlanMp />} />}
        {puedeCapturar && <Route path="/nuevo" element={<NuevoBacklog />} />}
        <Route path="/flota" element={<PorEquipo />} />
        <Route path="/backlog" element={<Navigate to="/flota" replace />} />
        <Route path="/backlog/:id" element={<FichaBacklog />} />
        <Route path="/kanban" element={<Kanban />} />
        <Route path="/calendario" element={<Calendario />} />
        <Route path="/equipo/:id" element={<FichaEquipo />} />
        <Route path="/indicadores" element={<Indicadores />} />
        {esAdmin && <Route path="/equipos" element={<Equipos />} />}
        {esAdmin && <Route path="/catalogos" element={<Catalogos />} />}
        {esAdmin && <Route path="/plazos" element={<Parametros />} />}
        {puedeCapturar && <Route path="/capacidad" element={<Capacidad />} />}
        {esAdmin && <Route path="/borrados" element={<Borrados />} />}
        {esAdmin && <Route path="/usuarios" element={<Usuarios />} />}
        <Route path="*" element={<Navigate to="/preventivo/control" replace />} />
      </Routes>
    </Layout>
  );
}

export default function App() {
  const [configurado, setConfigurado] = useState(() => leerConexion() !== null);
  if (!configurado) return <Setup alGuardar={() => setConfigurado(true)} />;
  return (
    <AuthProvider>
      <AvisosProvider>
        <Interior />
      </AvisosProvider>
    </AuthProvider>
  );
}
