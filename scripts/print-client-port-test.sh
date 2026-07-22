#!/usr/bin/env bash
# Print (and optionally write) Windows PowerShell port tests for the family PC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_FILE="${PROJECT_DIR}/scripts/out/client-port-test.ps1"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
load_env_file "${PROJECT_DIR}/.env"

HOST="${PANEL_DOMAIN:-${SERVER_IP:-vpn.example.com}}"
VLESS_PORT="${VLESS_PORT:-4433}"
SS_PORT="${SS_PORT:-8388}"
VMESS_PORT="${VMESS_PORT:-16888}"

mkdir -p "${PROJECT_DIR}/scripts/out"

write_ps1() {
  cat >"${OUT_FILE}" <<EOF
# happroxy — test TCP reachability from Windows to the VPN server.
# Run in PowerShell:  .\client-port-test.ps1

\$HostName = "${HOST}"

function Test-ServerPort {
  param([int]\$Port, [string]\$Label)
  Write-Host "Testing \$Label (\${HostName}:\$Port)..." -NoNewline
  try {
    \$r = Test-NetConnection -ComputerName \$HostName -Port \$Port -WarningAction SilentlyContinue
    if (\$r.TcpTestSucceeded) {
      Write-Host " OK" -ForegroundColor Green
      return \$true
    }
    Write-Host " FAIL" -ForegroundColor Red
    return \$false
  } catch {
    Write-Host " FAIL (\$_)" -ForegroundColor Red
    return \$false
  }
}

Write-Host "=== happroxy port test → \$HostName ===" -ForegroundColor Cyan
\$ss = Test-ServerPort -Port ${SS_PORT} -Label "Shadowsocks"
\$vless = Test-ServerPort -Port ${VLESS_PORT} -Label "VLESS Reality"
\$vmess = Test-ServerPort -Port ${VMESS_PORT} -Label "VMess"

Write-Host ""
if (\$ss -and -not \$vless) {
  Write-Host "VLESS port ${VLESS_PORT} blocked from your network. On server run:" -ForegroundColor Yellow
  Write-Host "  sudo bash scripts/migrate-vless-port.sh 8444" -ForegroundColor Yellow
  Write-Host "Use Shadowsocks in Happ until VLESS port is migrated." -ForegroundColor Yellow
} elseif (\$vless) {
  Write-Host "VLESS port reachable — if Happ still fails, update Happ and re-import subscription." -ForegroundColor Green
}
EOF
}

write_ps1

cat <<EOF
=== Test ports from your PC (Windows PowerShell) ===

File saved: ${OUT_FILE}

Copy to PC or run manually:

  Test-NetConnection ${HOST} -Port ${SS_PORT}
  Test-NetConnection ${HOST} -Port ${VLESS_PORT}
  Test-NetConnection ${HOST} -Port ${VMESS_PORT}

Interpretation:
  SS OK, VLESS FAIL  → migrate port: sudo bash scripts/migrate-vless-port.sh 8444
  Both OK              → Happ issue: update app, refresh subscription, try Proxy mode
  Both FAIL            → local firewall / network on PC

EOF
