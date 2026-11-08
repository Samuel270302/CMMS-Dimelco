import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { HashRouter } from "react-router-dom";
import App from "./App";
import "./styles.css";
import { esDemo, prepararDemo } from "./lib/supabase";

const qc = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 15000, retry: 1, refetchOnWindowFocus: true },
  },
});

const raiz = ReactDOM.createRoot(document.getElementById("root")!);

function montar() {
  raiz.render(
    <React.StrictMode>
      <QueryClientProvider client={qc}>
        <HashRouter>
          <App />
        </HashRouter>
      </QueryClientProvider>
    </React.StrictMode>
  );
}

// Demo web: antes de mostrar la app se abre (o se crea, la primera vez) la base del navegador.
if (esDemo) {
  raiz.render(
    <div className="pantalla-centro">
      <div className="tarjeta">
        <h1>CMMS Dimelco · demo de pruebas</h1>
        <p className="nota">Preparando la base de datos en este navegador. La primera vez tarda unos segundos.</p>
      </div>
    </div>
  );
  prepararDemo().then(montar, (e) =>
    raiz.render(
      <div className="pantalla-centro">
        <div className="tarjeta">
          <h1>No se pudo abrir la demo</h1>
          <p className="error-texto">{String(e)}</p>
          <p className="nota">Use Chrome o Edge actualizados. Si sigue fallando, borre los datos del sitio y recargue.</p>
        </div>
      </div>
    )
  );
} else {
  montar();
}
