#!/usr/bin/env bash
# qemu-vps-delete.sh — Destruye y elimina una VM QEMU/KVM completamente
#
# Elimina en orden: apagado forzado → snapshots → definición libvirt
#                   → reglas iptables → disco qcow2
#
# Uso: ./qemu-vps-delete.sh [OPCIONES]
#
# Opciones:
#   --name   NAME   Nombre de la VM   (default: sdlc-vps)
#   --vm-ip  IP     IP de la VM       (requerido para limpiar iptables)
#   --force         Omite confirmación interactiva
#
# Ejemplos:
#   ./qemu-vps-delete.sh
#   ./qemu-vps-delete.sh --name sdlc-vps --vm-ip 192.168.122.50
#   ./qemu-vps-delete.sh --vm-ip 192.168.122.50 --force

set -euo pipefail

# ─── colores ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()   { echo -e "\n${BOLD}[$1]${RESET} $2"; }
die()    { err "$*"; exit 1; }

# ─── defaults ────────────────────────────────────────────────────────────────
VM_NAME="sdlc-vps"
VM_IP=""
FORCE=false
DISK_DIR="$HOME/vms/disks"
PORTS=(22 80 443 3000 3001 4566 6443 8080 9000 9090 16686)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   VM_NAME="$2"; shift 2 ;;
    --vm-ip)  VM_IP="$2";   shift 2 ;;
    --force)  FORCE=true;   shift   ;;
    --help|-h)
      sed -n '2,/^set -/{ /^set -/d; s/^# \{0,1\}//; p }' "$0"
      exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

DISK_PATH="$DISK_DIR/${VM_NAME}.qcow2"

# ─── confirmación ─────────────────────────────────────────────────────────────
echo -e "${RED}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         ELIMINACIÓN DESTRUCTIVA E IRREVERSIBLE       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  VM:    ${BOLD}${VM_NAME}${RESET}"
echo -e "  Disco: ${BOLD}${DISK_PATH}${RESET}"
[[ -n "$VM_IP" ]] && echo -e "  IP:    ${BOLD}${VM_IP}${RESET} (se limpiarán reglas iptables)"
echo ""
warn "Se eliminará: apagado forzado, snapshots, definición libvirt, disco qcow2."
[[ -z "$VM_IP" ]] && warn "Sin --vm-ip: las reglas iptables NO se limpiarán automáticamente."
echo ""

if [[ "$FORCE" == false ]]; then
  read -r -p "  ¿Confirmas? (escribe 'si' para continuar): " confirm
  [[ "$confirm" == "si" ]] || { info "Operación cancelada."; exit 0; }
fi

echo ""

# ─── 1. Forzar apagado ────────────────────────────────────────────────────────
step "1/5" "Forzar apagado de la VM"
if virsh domstate "$VM_NAME" &>/dev/null; then
  virsh destroy "$VM_NAME" 2>/dev/null && info "VM detenida." || info "VM ya estaba apagada."
else
  warn "La VM '$VM_NAME' no existe en libvirt — continuando limpieza."
fi

# ─── 2. Eliminar snapshots ────────────────────────────────────────────────────
step "2/5" "Eliminar snapshots"
mapfile -t SNAPS < <(virsh snapshot-list "$VM_NAME" --name 2>/dev/null || true)
if [[ ${#SNAPS[@]} -eq 0 ]]; then
  info "Sin snapshots."
else
  for snap in "${SNAPS[@]}"; do
    [[ -z "$snap" ]] && continue
    virsh snapshot-delete "$VM_NAME" --snapshotname "$snap"
    ok "Snapshot eliminado: $snap"
  done
fi

# ─── 3. Desregistrar de libvirt ───────────────────────────────────────────────
step "3/5" "Desregistrar VM de libvirt (--remove-all-storage)"
virsh undefine "$VM_NAME" \
  --remove-all-storage \
  --snapshots-metadata \
  --nvram 2>/dev/null \
  && ok "VM desregistrada." \
  || warn "No se pudo desregistrar (¿ya no existía?)."

# ─── 4. Limpiar iptables ──────────────────────────────────────────────────────
step "4/5" "Limpiar reglas iptables"
if [[ -n "$VM_IP" ]]; then
  info "Eliminando port-forwarding para $VM_IP (puertos: ${PORTS[*]})..."
  for PORT in "${PORTS[@]}"; do
    sudo iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j DNAT \
      --to-destination "${VM_IP}:${PORT}" 2>/dev/null || true
    sudo iptables -D FORWARD -p tcp -d "$VM_IP" --dport "$PORT" -j ACCEPT 2>/dev/null || true
  done
  sudo netfilter-persistent save
  ok "Reglas iptables eliminadas."
else
  warn "Sin --vm-ip: iptables no modificado."
  warn "Limpieza manual:  sudo iptables -t nat -L --line-numbers"
fi

# ─── 5. Disco huérfano ────────────────────────────────────────────────────────
step "5/5" "Eliminar disco qcow2 si quedó huérfano"
if [[ -f "$DISK_PATH" ]]; then
  rm -f "$DISK_PATH"
  ok "Disco eliminado: $DISK_PATH"
else
  info "Disco no encontrado (ya fue eliminado por --remove-all-storage)."
fi

# ─── verificación final ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Verificación ──────────────────────────────────────────${RESET}"
virsh list --all 2>/dev/null | grep "$VM_NAME" \
  && warn "La VM aún aparece en virsh list" \
  || ok  "VM ausente de virsh list"

[[ -f "$DISK_PATH" ]] \
  && warn "Disco aún existe: $DISK_PATH" \
  || ok  "Disco ausente: $DISK_PATH"

virsh snapshot-list "$VM_NAME" 2>/dev/null \
  && warn "Aún hay snapshots registrados" \
  || ok  "Sin snapshots registrados"

echo ""
ok "Eliminación completa de '${VM_NAME}'."
