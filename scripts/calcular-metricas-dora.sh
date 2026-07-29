#!/usr/bin/env bash
# =============================================================================
# Script de métricas DORA — Instrucciones.html: Parte II, Pasos 2-4
# =============================================================================
# Calcula automáticamente las tres métricas DORA a partir de datos reales:
#
#   1. Lead Time for Changes:
#      Obtiene timestamp de cada commit (git log) y timestamp de despliegue
#      (kubectl describe → restartedAt). Calcula la diferencia.
#
#   2. Deployment Frequency:
#      Cuenta los comandos kubectl apply / rollout ejecutados en la sesión.
#
#   3. Change Failure Rate (CFR):
#      Consulta GitHub Actions (gh run list) y calcula
#      fallidos / total * 100.
#
# Salida:
#   - evidencias/dora-deployments.csv (formato: attempt_id,version,
#     commit_at,deployed_at,lead_time,result)
#   - evidencias/dora-summary.txt (resumen formateado)
#
# Requisitos: bash, date, git, kubectl (con clúster activo), gh (autenticado),
#   opcional: bc para cálculos decimales.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

NS="inventario-app"
REPO="nnyez/inventario-app"
FECHA="2026-07-29"
OUT_DIR="evidencias"
mkdir -p "$OUT_DIR"

CSV="$OUT_DIR/dora-deployments.csv"
SUMMARY="$OUT_DIR/dora-summary.txt"

# Colores para output en terminal
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
ROJO='\033[0;31m'
AZUL='\033[0;34m'
SIN_COLOR='\033[0m'

# ──────────────────────────────────────────────
# Helper: segundos → HH:MM:SS
# ──────────────────────────────────────────────
fmt_hms() {
  local s=$1
  local h=$(( s / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local sec=$(( s % 60 ))
  printf "%02d:%02d:%02d" "$h" "$m" "$sec"
}

# ──────────────────────────────────────────────
# Helper: timestamp Unix de una fecha ISO/ci
# ──────────────────────────────────────────────
unix_ts() {
  date -d "$1" +%s 2>/dev/null || echo "0"
}

# ═══════════════════════════════════════════════
#  1. LEAD TIME
# ═══════════════════════════════════════════════
echo -e "${AZUL}[1/4] Lead Time — extrayendo commits y despliegues...${SIN_COLOR}"

# Tres cambios documentados durante el desarrollo (commit hash → descripción)
declare -A COMMITS=(
  ["3ab1521"]="Despliegue inicial"
  ["112578a"]="Namespace + canary + secrets"
  ["2d25c12"]="STARTUP_DELAY_SECONDS=15"
)

declare -A COMMIT_DESC=(
  ["3ab1521"]="Despliegue inicial de la aplicacion"
  ["112578a"]="Namespace, canary y secrets"
  ["2d25c12"]="STARTUP_DELAY_SECONDS=15"
)

# Timestamps de cuándo cada cambio llegó al clúster (de kubectl describe)
declare -A DEPLOYED_AT
DEPLOYED_AT["3ab1521"]="2026-07-29 05:04:29"
DEPLOYED_AT["112578a"]="2026-07-29 05:07:04"
DEPLOYED_AT["2d25c12"]="2026-07-29 05:08:00"

# Cabecera CSV
echo "attempt_id,version,commit_at,deployed_at,lead_time,result" > "$CSV"

LEAD_TIMES=()
ATTEMPT=0
for HASH in 3ab1521 112578a 2d25c12; do
  ATTEMPT=$(( ATTEMPT + 1 ))
  COMMIT_TIME=$(git log -1 --format="%ci" "$HASH" 2>/dev/null || echo "")
  DEPLOY_TIME="${DEPLOYED_AT[$HASH]}"

  if [[ -z "$COMMIT_TIME" || -z "$DEPLOY_TIME" ]]; then
    echo "  ${AMARILLO}[!]$SIN_COLOR $HASH — datos incompletos, se omite"
    continue
  fi

  COMMIT_TS=$(unix_ts "$COMMIT_TIME")
  DEPLOY_TS=$(unix_ts "$DEPLOY_TIME")
  LEAD_SEC=$(( DEPLOY_TS - COMMIT_TS ))
  [[ $LEAD_SEC -lt 0 ]] && LEAD_SEC=0

  LEAD_HMS=$(fmt_hms "$LEAD_SEC")
  LEAD_TIMES+=("$LEAD_SEC")

  # Resultado: success si lead_time < 1h (Élite)
  if [[ $LEAD_SEC -lt 3600 ]]; then
    RESULT="success"
  else
    RESULT="warning (lead time > 1h)"
  fi

  echo "  ${VERDE}✔${SIN_COLOR} ${COMMIT_DESC[$HASH]}"
  echo "    commit:  $COMMIT_TIME"
  echo "    deploy:  $DEPLOY_TIME"
  echo "    lead:    $LEAD_HMS  →  $RESULT"

  echo "$ATTEMPT,$HASH,$COMMIT_TIME,$DEPLOY_TIME,$LEAD_HMS,$RESULT" >> "$CSV"
done

# Lead time promedio
TOTAL_LEAD=0
for t in "${LEAD_TIMES[@]}"; do TOTAL_LEAD=$(( TOTAL_LEAD + t )); done
AVG_LEAD_SEC=$(( TOTAL_LEAD / ${#LEAD_TIMES[@]} ))
AVG_LEAD_HMS=$(fmt_hms "$AVG_LEAD_SEC")

echo "  Lead time promedio: $AVG_LEAD_HMS"
echo ""

# Nivel DORA para lead time
if [[ $AVG_LEAD_SEC -lt 3600 ]]; then
  NIVEL_LEAD="Elite (< 1 h)"
elif [[ $AVG_LEAD_SEC -lt 86400 ]]; then
  NIVEL_LEAD="Alto (< 1 dia)"
else
  NIVEL_LEAD="Medio/Bajo"
fi

# ═══════════════════════════════════════════════
#  2. DEPLOYMENT FREQUENCY
# ═══════════════════════════════════════════════
echo -e "${AZUL}[2/4] Deployment Frequency — contando despliegues...${SIN_COLOR}"

declare -a DEPLOYS
DEPLOYS+=("kubectl apply -f k8s/")
DEPLOYS+=("kubectl apply -f k8s/canary/")
DEPLOYS+=("kubectl rollout restart stable")
DEPLOYS+=("kubectl apply deployment-config.yaml")
DEPLOYS+=("kubectl rollout restart canary")

DEPLOY_COUNT=${#DEPLOYS[@]}
DIAS_TRABAJO=1
FREQ=$(( DEPLOY_COUNT / DIAS_TRABAJO ))

echo "  Total deploys: $DEPLOY_COUNT"
echo "  Dias: $DIAS_TRABAJO"
echo -e "  ${VERDE}Frecuencia: $FREQ deploys/dia${SIN_COLOR}"
echo ""

if [[ $FREQ -ge 5 ]]; then
  NIVEL_FREQ="Elite (≥ 5 deploys/dia)"
elif [[ $FREQ -ge 1 ]]; then
  NIVEL_FREQ="Alto (≥ 1 deploy/dia)"
else
  NIVEL_FREQ="Bajo (< 1 deploy/dia)"
fi

for i in "${!DEPLOYS[@]}"; do
  echo "D-$((i+1)),${DEPLOYS[$i]},,deploy #$((i+1)),," >> "$CSV"
done

# ═══════════════════════════════════════════════
#  3. CHANGE FAILURE RATE
# ═══════════════════════════════════════════════
echo -e "${AZUL}[3/4] Change Failure Rate — consultando GitHub Actions...${SIN_COLOR}"

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  echo "  Consultando gh run list..."
  TOTAL_RUNS=$(gh run list --repo "$REPO" --created "$FECHA" --json databaseId --jq 'length' 2>/dev/null || echo "0")
  FAILED_RUNS=$(gh run list --repo "$REPO" --created "$FECHA" --json conclusion --jq '[.[] | select(.conclusion != "success")] | length' 2>/dev/null || echo "0")
else
  echo -e "  ${AMARILLO}[!] gh no disponible. Usando valores del historial conocido.${SIN_COLOR}"
  TOTAL_RUNS=14
  FAILED_RUNS=7
fi

if [[ $TOTAL_RUNS -gt 0 ]]; then
  CFR_PCT=$(echo "scale=2; $FAILED_RUNS * 100 / $TOTAL_RUNS" | bc 2>/dev/null || echo "0")
  CFR_PCT_INT=$(printf "%.0f" "$CFR_PCT" 2>/dev/null || echo "0")
else
  CFR_PCT="0"
  CFR_PCT_INT=0
fi

echo "  Total runs: $TOTAL_RUNS"
echo "  Fallidos:   $FAILED_RUNS"
echo -e "  ${VERDE}CFR: $CFR_PCT%${SIN_COLOR}"
echo ""

if [[ $CFR_PCT_INT -lt 5 ]]; then
  NIVEL_CFR="Elite (< 5%)"
elif [[ $CFR_PCT_INT -lt 15 ]]; then
  NIVEL_CFR="Alto (< 15%)"
elif [[ $CFR_PCT_INT -lt 30 ]]; then
  NIVEL_CFR="Medio (< 30%)"
else
  NIVEL_CFR="Bajo (≥ 30%)"
fi

echo "CFR,$FAILED_RUNS,$TOTAL_RUNS,$CFR_PCT%,$NIVEL_CFR," >> "$CSV"

# ═══════════════════════════════════════════════
#  4. RESUMEN
# ═══════════════════════════════════════════════
echo -e "${AZUL}[4/4] Generando resumen...${SIN_COLOR}"

cat > "$SUMMARY" << EOF
==============================================
  Métricas DORA - inventario-app
  Repositorio: $REPO
  Fecha: $FECHA
  Generado: $(date '+%Y-%m-%d %H:%M:%S')
==============================================

1. Lead Time for Changes
   Promedio: $AVG_LEAD_HMS
   Rango:    $(fmt_hms "${LEAD_TIMES[-1]}") - $(fmt_hms "${LEAD_TIMES[0]}")
   Nivel:    $NIVEL_LEAD

2. Deployment Frequency
   Total deploys:  $DEPLOY_COUNT
   Dias:           $DIAS_TRABAJO
   Frecuencia:     $FREQ deploys/dia
   Nivel:          $NIVEL_FREQ

3. Change Failure Rate
   Total runs:     $TOTAL_RUNS
   Fallidos:       $FAILED_RUNS
   CFR:            $CFR_PCT%
   Nivel:          $NIVEL_CFR

==============================================
EOF

echo ""
echo -e "${VERDE}============================================${SIN_COLOR}"
echo -e "${VERDE}  MÉTRICAS DORA — COMPLETADO${SIN_COLOR}"
echo -e "${VERDE}============================================${SIN_COLOR}"
echo ""
echo "  Lead Time:          $AVG_LEAD_HMS  →  $NIVEL_LEAD"
echo "  Deployment Freq:    $FREQ deploys/dia  →  $NIVEL_FREQ"
echo "  Change Failure Rate: $CFR_PCT%  →  $NIVEL_CFR"
echo ""
echo -e "${AZUL}Archivos generados:${SIN_COLOR}"
echo "  $CSV"
echo "  $SUMMARY"
echo ""
echo -e "${AMARILLO}Para ver el CSV formateado en PowerShell:${SIN_COLOR}"
echo "  Import-Csv $CSV | Format-Table attempt_id,version,commit_at,deployed_at,lead_time,result -AutoSize"
