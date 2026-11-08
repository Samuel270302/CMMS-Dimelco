#!/usr/bin/env bash
# Une las migraciones en supabase/instalar_todo.sql para pegarlas de una vez en el SQL Editor.
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
{
  echo "-- Instalación completa de la base del CMMS (generado por tools/armar_instalacion.sh)."
  echo "-- Backlog 001 a 018 y preventivo 019. Se puede repetir sobre la base de backlog en uso:"
  echo "-- solo agrega lo que falta. No ejecutar en producción sin la aprobación de la fusión."
  for f in "$RAIZ"/supabase/migrations/*.sql; do
    echo; echo "-- ===== $(basename "$f") ====="; cat "$f"
  done
} > "$RAIZ/supabase/instalar_todo.sql"
echo "supabase/instalar_todo.sql armado"
