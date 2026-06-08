#!/usr/bin/env bash
# qemu-vps.sh — Automatiza PLAN-VPS-LOCAL-QEMU.md desde el Paso 1
#
# ─── PREREQUISITOS (ejecutar manualmente una sola vez) ───────────────────────
#
#   1. Verificar soporte de virtualización en el CPU:
#        egrep -c '(vmx|svm)' /proc/cpuinfo   # debe ser > 0
#
#   2. Instalar paquetes QEMU/KVM:
#        sudo apt update
#        sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system \
#          libvirt-clients virtinst bridge-utils cpu-checker iptables-persistent
#        sudo kvm-ok
#        sudo usermod -aG libvirt,kvm $USER
#        newgrp libvirt
#
#   3. Descargar ISO Ubuntu 26.04 LTS:
#        mkdir -p ~/vms/iso
#        wget -P ~/vms/iso https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso
#        wget -P ~/vms/iso https://releases.ubuntu.com/26.04/SHA256SUMS
#        cd ~/vms/iso && sha256sum -c SHA256SUMS --ignore-missing
#
# ─────────────────────────────────────────────────────────────────────────────
#
# Uso: ./qemu-vps.sh <COMANDO> [OPCIONES]
#
# Comandos:
#   create     Paso 1-2: crea disco qcow2 + VM con virt-install
#   setup      Paso 4-5: config post-instalación vía SSH (OCI-compatible)
#   snapshot   Paso 6:   crea snapshot 'base-oci-config'
#   status     Muestra estado, IP y snapshots de la VM
#   delete     Destruye VM, snapshots, iptables y disco completamente
#
# Opciones:
#   --vcpus  N      vCPUs              (default: 4)
#   --ram    N      RAM en MB          (default: 8192)
#   --disksize S    Tamaño del disco   (default: 120G)
#   --name   NAME   Nombre de la VM    (default: sdlc-vps)
#   --vm-ip  IP     IP de la VM        (requerido en setup; opcional en delete)
#   --ssh-key FILE  Clave SSH pública  (default: ~/.ssh/id_ed25519.pub)
#                   Si no existe:  ssh-keygen -t ed25519 -C "sdlc-vps" -f ~/.ssh/id_ed25519
#   --force         Omite confirmación interactiva (solo en delete)
#
# Ejemplos:
#   ./qemu-vps.sh create --vcpus 2 --ram 4096 --disksize 60G
#   ./qemu-vps.sh status
#   ./qemu-vps.sh setup --vm-ip 192.168.122.50
#   ./qemu-vps.sh snapshot
#   ./qemu-vps.sh delete --vm-ip 192.168.122.50
#   ./qemu-vps.sh delete --vm-ip 192.168.122.50 --force

set -euo pipefail

# Si el grupo libvirt no está activo en la sesión actual, re-ejecutar con sg
if ! id -nG | grep -qw libvirt; then
  exec sg libvirt -c "bash $0 $*"
fi

# ─── colores ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
step()   { echo -e "\n${BOLD}[$1]${RESET} $2"; }
die()    { err "$*"; exit 1; }

# ─── defaults ────────────────────────────────────────────────────────────────
VCPUS=4
RAM=8192
DISKSIZE="60G"
VM_NAME="sdlc-vps"
VM_IP=""
VM_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
ISO_PATH="$HOME/vms/iso/ubuntu-26.04-live-server-amd64.iso"
DISK_DIR="$HOME/vms/disks"
FORCE=false
PORTS=(22 80 443 3000 3001 4566 6443 8080 9000 9090 16686)

# ─── parsear argumentos ───────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vcpus)    VCPUS="$2";    shift 2 ;;
    --ram)      RAM="$2";      shift 2 ;;
    --disksize) DISKSIZE="$2"; shift 2 ;;
    --name)     VM_NAME="$2";  shift 2 ;;
    --vm-ip)    VM_IP="$2";    shift 2 ;;
    --ssh-key)  SSH_KEY="$2";  shift 2 ;;
    --user)     VM_USER="$2";  shift 2 ;;
    --force)    FORCE=true;    shift   ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

DISK_PATH="$DISK_DIR/${VM_NAME}.qcow2"

# ─── helpers ─────────────────────────────────────────────────────────────────
require_vm_exists() {
  virsh domstate "$VM_NAME" &>/dev/null || die "La VM '$VM_NAME' no existe. Ejecuta primero: create"
}

require_vm_ip() {
  if [[ -z "$VM_IP" ]]; then
    local detected
    detected=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || true)
    if [[ -n "$detected" ]]; then
      VM_IP="$detected"
      info "IP detectada automáticamente: $VM_IP"
    else
      die "No se pudo detectar la IP de la VM. Pasa --vm-ip <IP> manualmente."
    fi
  fi
}

ssh_vm() {
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${VM_USER}@${VM_IP}" "$@"
}

# ─── COMANDO: help ────────────────────────────────────────────────────────────
cmd_help() {
  sed -n '2,/^set -/{ /^set -/d; s/^# \{0,1\}//; p }' "$0"
}

# ─── COMANDO: create  (Pasos 1 y 2) ──────────────────────────────────────────
cmd_create() {
  header "Paso 1 — Crear disco virtual"

  if virsh domstate "$VM_NAME" &>/dev/null; then
    die "La VM '$VM_NAME' ya existe. Ejecuta 'delete' primero si quieres recrearla."
  fi

  [[ -f "$ISO_PATH" ]] || die "ISO no encontrada: $ISO_PATH — ver prerequisito 3 en la cabecera del script."

  mkdir -p "$DISK_DIR"

  if [[ -f "$DISK_PATH" ]]; then
    warn "Disco ya existe: $DISK_PATH — reutilizando."
  else
    info "Creando disco qcow2: $DISK_PATH ($DISKSIZE)"
    qemu-img create -f qcow2 "$DISK_PATH" "$DISKSIZE"
  fi

  qemu-img info "$DISK_PATH"

  header "Paso 2 — Crear VM con virt-install"
  info "name=$VM_NAME  vcpus=$VCPUS  ram=${RAM}MB  disk=$DISKSIZE"

  # libvirt-qemu necesita permiso de traversal en el home para acceder a ~/vms/
  if [[ "$(stat -c '%a' "$HOME")" != *[1357]* ]]; then
    info "Concediendo permiso de traversal a libvirt-qemu en $HOME..."
    sudo chmod o+x "$HOME"
  fi

  virt-install \
    --name "$VM_NAME" \
    --ram "$RAM" \
    --vcpus "$VCPUS" \
    --cpu host-model \
    --os-variant ubuntu24.04 \
    --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
    --location "${ISO_PATH},kernel=casper/vmlinuz,initrd=casper/initrd" \
    --extra-args "console=ttyS0,115200n8 ---" \
    --network network=default,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --boot cdrom,hd

  ok "VM '$VM_NAME' creada."
  echo ""
  warn "Próximos pasos:"
  echo "  1. Conectar a la consola:   virsh console $VM_NAME"
  echo "  2. Instalar Ubuntu (ver PLAN-VPS-LOCAL-QEMU.md § Paso 3)"
  echo "  3. Ver IP asignada:         ./qemu-vps.sh status"
  echo "  4. Config post-install:     ./qemu-vps.sh setup --vm-ip <IP>"
}

# ─── COMANDO: setup  (Pasos 4 y 5) ───────────────────────────────────────────
cmd_setup() {
  header "Paso 4 — Configuración post-instalación en la VM"

  require_vm_exists
  require_vm_ip

  [[ -f "$SSH_KEY" ]] || die "Clave SSH no encontrada: $SSH_KEY. Pasa --ssh-key con la ruta correcta."

  info "Copiando clave SSH a la VM ($VM_IP) como usuario '$VM_USER'..."
  ssh-copy-id -i "$SSH_KEY" "${VM_USER}@${VM_IP}"

  info "Ejecutando configuración OCI-compatible en la VM..."

  local vm_user="$VM_USER"
  ssh_vm "bash -s" <<REMOTE
set -euo pipefail
VM_USER="${vm_user}"

# 4.2 — SSH key-only, deshabilitar password auth
echo "[4.2] SSH key-only..."
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config
sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config
sudo systemctl restart ssh

# 4.3 — sudo sin password (igual que OCI)
echo "[4.3] sudo NOPASSWD para \$VM_USER..."
echo "\$VM_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/\$VM_USER > /dev/null
sudo chmod 440 /etc/sudoers.d/\$VM_USER

# 4.4 — hostname convención OCI
echo "[4.4] Hostname..."
sudo hostnamectl set-hostname sdlc-vps
grep -q "127.0.1.1 sdlc-vps" /etc/hosts \
  || echo "127.0.1.1 sdlc-vps" | sudo tee -a /etc/hosts

# 4.5 — zona horaria UTC
echo "[4.5] UTC timezone..."
sudo timedatectl set-timezone UTC

# 4.6 — NTP pool público (cambiar a 169.254.169.254 al migrar a OCI)
echo "[4.6] NTP..."
sudo apt-get install -y -qq systemd-timesyncd
sudo tee /etc/systemd/timesyncd.conf > /dev/null <<EOF
[Time]
NTP=pool.ntp.org
FallbackNTP=ntp.ubuntu.com
EOF
sudo systemctl restart systemd-timesyncd

# 4.7 — cloud-init datasource NoCloud (cambiar a Oracle al migrar a OCI)
echo "[4.7] cloud-init datasource NoCloud..."
sudo apt-get install -y -qq cloud-init
sudo tee /etc/cloud/cloud.cfg.d/99-datasource.cfg > /dev/null <<EOF
datasource_list: [NoCloud, None]
EOF
sudo cloud-init clean

# 4.8 — UFW replicando OCI Security List
echo "[4.8] UFW..."
sudo apt-get install -y -qq ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
for PORT in 22 80 443 3000 3001 4566 6443 8080 9000 9090 16686; do
  sudo ufw allow "\${PORT}/tcp"
done
sudo ufw --force enable
sudo ufw status verbose

# 4.9 — vm.max_map_count para SonarQube
echo "[4.9] vm.max_map_count..."
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf
sudo sysctl -p /etc/sysctl.d/99-sonarqube.conf

# 4.10 — límites de archivos abiertos
echo "[4.10] Límites nofile..."
sudo tee /etc/security/limits.d/99-sdlc.conf > /dev/null <<EOF
*          soft nofile 65536
*          hard nofile 65536
\$VM_USER   soft nofile 65536
\$VM_USER   hard nofile 65536
EOF

# 4.11 — habilitar consola serial para virsh console
echo "[4.11] Consola serial (virsh console)..."
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"/' /etc/default/grub
sudo update-grub
sudo systemctl enable --now serial-getty@ttyS0.service

echo "[OK] Configuración en VM completa."
REMOTE

  header "Paso 5 — Port-forwarding host → VM (iptables)"
  info "VM IP: $VM_IP  |  puertos: ${PORTS[*]}"

  for PORT in "${PORTS[@]}"; do
    sudo iptables -t nat -C PREROUTING -p tcp --dport "$PORT" -j DNAT \
      --to-destination "${VM_IP}:${PORT}" 2>/dev/null \
      || sudo iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT \
           --to-destination "${VM_IP}:${PORT}"
    sudo iptables -C FORWARD -p tcp -d "$VM_IP" --dport "$PORT" -j ACCEPT 2>/dev/null \
      || sudo iptables -A FORWARD -p tcp -d "$VM_IP" --dport "$PORT" -j ACCEPT
  done
  sudo iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -j MASQUERADE

  sudo netfilter-persistent save
  ok "Port-forwarding configurado."
  ok "Setup completo. SSH: ssh ${VM_USER}@${VM_IP}"
}

# ─── COMANDO: snapshot  (Paso 6) ─────────────────────────────────────────────
cmd_snapshot() {
  header "Paso 6 — Snapshot base-oci-config"

  require_vm_exists

  local state
  state=$(virsh domstate "$VM_NAME")

  if [[ "$state" == "running" ]]; then
    info "Apagando VM limpiamente..."
    virsh shutdown "$VM_NAME"
    local tries=0
    while virsh domstate "$VM_NAME" | grep -q "running" && [[ $tries -lt 30 ]]; do
      sleep 2
      tries=$((tries + 1))
    done
    virsh domstate "$VM_NAME" | grep -q "running" && virsh destroy "$VM_NAME" || true
  fi

  if virsh snapshot-list "$VM_NAME" --name 2>/dev/null | grep -q "^base-oci-config$"; then
    warn "Snapshot 'base-oci-config' ya existe — omitiendo."
  else
    info "Creando snapshot..."
    virsh snapshot-create-as "$VM_NAME" \
      --name "base-oci-config" \
      --description "Ubuntu 26.04 limpio, configurado OCI-compatible" \
      --atomic
  fi

  virsh snapshot-list "$VM_NAME"
  ok "Para restaurar: virsh snapshot-revert $VM_NAME base-oci-config"
}

# ─── COMANDO: status ──────────────────────────────────────────────────────────
cmd_status() {
  header "Estado de '$VM_NAME'"

  if ! virsh domstate "$VM_NAME" &>/dev/null; then
    warn "La VM '$VM_NAME' no existe."
    return
  fi

  echo -e "${BOLD}Estado:${RESET}"
  virsh domstate "$VM_NAME"

  echo -e "\n${BOLD}Info:${RESET}"
  virsh dominfo "$VM_NAME" | grep -E "(Name|State|CPU|Memory|Persistent|Autostart)"

  echo -e "\n${BOLD}IP:${RESET}"
  local ip
  ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || true)
  if [[ -n "$ip" ]]; then
    ok "IP: $ip"
    echo "  SSH: ssh ubuntu@${ip}"
  else
    warn "Sin IP asignada (¿está corriendo?)"
  fi

  echo -e "\n${BOLD}Snapshots:${RESET}"
  virsh snapshot-list "$VM_NAME" 2>/dev/null || warn "No hay snapshots."

  echo -e "\n${BOLD}Disco:${RESET}"
  if [[ -f "$DISK_PATH" ]]; then
    qemu-img info --force-share "$DISK_PATH" | grep -E "(file format|virtual size|disk size)"
  else
    warn "Disco no encontrado: $DISK_PATH"
  fi
}

# ─── COMANDO: delete ──────────────────────────────────────────────────────────
cmd_delete() {
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

  step "1/5" "Forzar apagado de la VM"
  if virsh domstate "$VM_NAME" &>/dev/null; then
    virsh destroy "$VM_NAME" 2>/dev/null && info "VM detenida." || info "VM ya estaba apagada."
  else
    warn "La VM '$VM_NAME' no existe en libvirt — continuando limpieza."
  fi

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

  step "3/5" "Desregistrar VM de libvirt (--remove-all-storage)"
  virsh undefine "$VM_NAME" \
    --remove-all-storage \
    --snapshots-metadata \
    --nvram 2>/dev/null \
    && ok "VM desregistrada." \
    || warn "No se pudo desregistrar (¿ya no existía?)."

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

  step "5/5" "Eliminar disco qcow2 si quedó huérfano"
  if [[ -f "$DISK_PATH" ]]; then
    rm -f "$DISK_PATH"
    ok "Disco eliminado: $DISK_PATH"
  else
    info "Disco no encontrado (ya fue eliminado por --remove-all-storage)."
  fi

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
}

# ─── dispatcher ───────────────────────────────────────────────────────────────
case "$COMMAND" in
  create)   cmd_create   ;;
  setup)    cmd_setup    ;;
  snapshot) cmd_snapshot ;;
  status)   cmd_status   ;;
  delete)   cmd_delete   ;;
  help|--help|-h) cmd_help ;;
  *) err "Comando desconocido: $COMMAND"; echo ""; cmd_help; exit 1 ;;
esac
