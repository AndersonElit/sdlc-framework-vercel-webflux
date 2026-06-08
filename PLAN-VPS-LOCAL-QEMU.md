# Plan: VPS Local con QEMU/KVM → Oracle Cloud Infrastructure (OCI)

## Objetivo

Levantar un VPS local usando QEMU/KVM con Ubuntu 26.04 LTS configurado siguiendo los estándares de Oracle Cloud Infrastructure (OCI). El objetivo es que cuando se decida migrar a una VPS real en Oracle Cloud, los cambios necesarios sean mínimos — misma imagen base, mismo usuario, misma estructura de red, mismo cloud-init, mismos puertos.

Todo se ejecuta por línea de comando.

---

## Por qué configurar local siguiendo OCI

| Aspecto | QEMU/KVM local | OCI (cuando se migre) | Cambio requerido |
|---|---|---|---|
| Imagen base | `ubuntu-26.04-live-server-amd64.iso` | Imagen OCI Ubuntu 26.04 | Ninguno |
| Usuario por defecto | `ubuntu` (configurado manual) | `ubuntu` (OCI default) | Ninguno |
| Autenticación | SSH key only | SSH key only | Ninguno |
| cloud-init | `NoCloud` datasource | `OCI` datasource | Solo el datasource |
| Interfaz de red | `ens3` (virtio) | `ens3` (virtio) | Ninguno |
| Firewall | UFW local | UFW + OCI Security List | Replicar reglas UFW en Security List |
| Puertos expuestos | Port-forward QEMU | OCI Security List (Ingress Rules) | Mapear los mismos puertos |
| Almacenamiento | qcow2 (50 GB) | Boot Volume (50 GB) | Ninguno |
| NTP | `pool.ntp.org` | `169.254.169.254` (OCI NTP) | Un parámetro en `timesyncd.conf` |
| Metadata service | No aplica | `http://169.254.169.254/opc/v2/` | Solo si algún script lo usa |

---

## Prerequisitos en el host

### Paquetes QEMU/KVM

```bash
# Verificar soporte de virtualización en el CPU
egrep -c '(vmx|svm)' /proc/cpuinfo   # debe ser > 0

# Instalar QEMU/KVM y herramientas de gestión
sudo apt update
sudo apt install -y \
  qemu-system-x86 \
  qemu-utils \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  bridge-utils \
  virt-manager \
  cpu-checker

# Verificar KVM disponible
sudo kvm-ok

# Agregar usuario al grupo libvirt
sudo usermod -aG libvirt,kvm $USER
newgrp libvirt
```

### Descargar imagen ISO Ubuntu 26.04

```bash
mkdir -p ~/vms/iso
wget -P ~/vms/iso \
  https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso

# Verificar checksum
wget -P ~/vms/iso \
  https://releases.ubuntu.com/26.04/SHA256SUMS
sha256sum -c ~/vms/iso/SHA256SUMS --ignore-missing
```

---

## Paso 1 — Crear el disco virtual

```bash
mkdir -p ~/vms/disks

# Disco principal: 120 GB qcow2 (mismo tamaño planificado para OCI Boot Volume)
qemu-img create -f qcow2 ~/vms/disks/sdlc-vps.qcow2 120G

# Verificar
qemu-img info ~/vms/disks/sdlc-vps.qcow2
```

---

## Paso 2 — Crear la VM con virt-install

Configuración que replica el hardware virtual de OCI (VM.Standard.A1.Flex free tier):
- 4 vCPU
- 8 GB RAM
- Red virtio (mismo driver que OCI)
- Disco virtio (mismo driver que OCI)

```bash
virt-install \
  --name sdlc-vps \
  --ram 8192 \
  --vcpus 4 \
  --cpu host \
  --os-variant ubuntu24.04 \
  --disk path=~/vms/disks/sdlc-vps.qcow2,format=qcow2,bus=virtio \
  --cdrom ~/vms/iso/ubuntu-26.04-live-server-amd64.iso \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --extra-args 'console=ttyS0,115200n8 serial' \
  --noautoconsole \
  --boot cdrom,hd
```

Conectar a la consola de instalación:

```bash
virsh console sdlc-vps
# Salir de la consola: Ctrl + ]
```

---

## Paso 3 — Instalación Ubuntu 26.04 siguiendo convenciones OCI

Durante el instalador interactivo aplicar estas opciones — son las mismas que usa OCI en sus imágenes Ubuntu:

### 3.1 Idioma y teclado
```
Language:  English
Keyboard:  English (US)
```

### 3.2 Tipo de instalación
```
Ubuntu Server (minimized)    ← igual que las imágenes OCI
```

### 3.3 Red
```
# El instalador detecta la interfaz virtio como ens3 (mismo nombre en OCI)
Interface: ens3
Method:    DHCP                ← OCI también usa DHCP en la instancia
```

### 3.4 Almacenamiento
```
# Partición simple — igual que OCI Boot Volume
Use entire disk: yes
Disk layout:
  /dev/vda1   1 GB    EFI System Partition
  /dev/vda2   2 GB    /boot  (ext4)
  /dev/vda3   restante /     (ext4)
LVM: NO                       ← OCI no usa LVM en sus imágenes Ubuntu
```

### 3.5 Usuario — crítico para compatibilidad OCI
```
Your name:        ubuntu
Server name:      sdlc-vps
Username:         ubuntu          ← OCI usa "ubuntu" como usuario por defecto
Password:         (temporal, se deshabilita después)
```

### 3.6 SSH
```
Install OpenSSH server: YES
Import SSH keys:        NO    ← se configura manualmente después
```

### 3.7 Snaps
```
# No instalar ningún snap — igual que imágenes OCI minimizadas
(dejar todo desmarcado)
```

---

## Paso 4 — Configuración post-instalación (OCI-compatible)

### 4.1 Acceder a la VM

```bash
# IP de la VM (red NAT de libvirt — rango 192.168.122.0/24 por defecto)
virsh domifaddr sdlc-vps

# Conectar
ssh ubuntu@<ip-vm>
```

### 4.2 SSH key-only — deshabilitar password auth

OCI deshabilita autenticación por password por defecto:

```bash
# En el host: copiar clave pública a la VM
ssh-copy-id -i ~/.ssh/id_rsa.pub ubuntu@<ip-vm>

# En la VM: deshabilitar password auth
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### 4.3 Sudo sin password — igual que OCI

```bash
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ubuntu
sudo chmod 440 /etc/sudoers.d/ubuntu
```

### 4.4 Hostname — convención OCI

```bash
# OCI nombra instancias con el display name
sudo hostnamectl set-hostname sdlc-vps
echo "127.0.1.1 sdlc-vps" | sudo tee -a /etc/hosts
```

### 4.5 Zona horaria — OCI usa UTC

```bash
sudo timedatectl set-timezone UTC
```

### 4.6 NTP — preparado para OCI

```bash
sudo apt install -y systemd-timesyncd

# Configuración local (pool público)
sudo tee /etc/systemd/timesyncd.conf > /dev/null <<EOF
[Time]
NTP=pool.ntp.org
FallbackNTP=ntp.ubuntu.com
EOF

# En OCI simplemente se cambia a:
# NTP=169.254.169.254
sudo systemctl restart systemd-timesyncd
timedatectl status
```

### 4.7 cloud-init — preparado para OCI

OCI usa cloud-init para la configuración inicial de instancias. Instalarlo y dejarlo listo:

```bash
sudo apt install -y cloud-init

# Datasource local (QEMU/KVM)
sudo tee /etc/cloud/cloud.cfg.d/99-datasource.cfg > /dev/null <<EOF
datasource_list: [NoCloud, None]
EOF

# En OCI simplemente se cambia a:
# datasource_list: [Oracle, None]
sudo cloud-init clean
```

### 4.8 UFW — reglas que replican OCI Security List

En OCI los puertos se controlan con Security Lists (Ingress/Egress Rules). Configurar UFW local con las mismas reglas que se crearán en OCI:

```bash
sudo apt install -y ufw

# Política por defecto (igual que OCI: deny all inbound, allow all outbound)
sudo ufw default deny incoming
sudo ufw default allow outgoing

# --- Reglas de entrada (Ingress Rules en OCI Security List) ---
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 80/tcp      # HTTP  (Traefik)
sudo ufw allow 443/tcp     # HTTPS (Traefik)
sudo ufw allow 3000/tcp    # Gitea
sudo ufw allow 8080/tcp    # Jenkins
sudo ufw allow 9000/tcp    # SonarQube
sudo ufw allow 9090/tcp    # Prometheus
sudo ufw allow 3001/tcp    # Grafana (3000 ocupado por Gitea)
sudo ufw allow 16686/tcp   # Jaeger UI
sudo ufw allow 4566/tcp    # floci (AWS emulator)
sudo ufw allow 6443/tcp    # K3s API server

# Puertos internos — solo desde la misma red (no exponer a internet en OCI)
# PostgreSQL, MongoDB, Kafka: sin regla UFW (acceso solo local)

sudo ufw --force enable
sudo ufw status verbose
```

### 4.9 Parámetro kernel requerido por SonarQube

```bash
# Permanente
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf
sudo sysctl -p /etc/sysctl.d/99-sonarqube.conf
```

### 4.10 Límites de archivos abiertos — OCI usa valores altos por defecto

```bash
sudo tee /etc/security/limits.d/99-sdlc.conf > /dev/null <<EOF
*    soft nofile 65536
*    hard nofile 65536
ubuntu soft nofile 65536
ubuntu hard nofile 65536
EOF
```

---

## Paso 5 — Port-forwarding en QEMU/KVM (acceso desde el host)

En QEMU/KVM con red NAT la VM no es accesible directamente desde el host en todos los puertos. Se configura port-forwarding con `iptables`:

```bash
# IP de la VM (anotar después de crearla)
VM_IP="192.168.122.X"

# Port-forwarding desde el host → VM (equivalente a las Ingress Rules de OCI)
for PORT in 22 80 443 3000 3001 4566 6443 8080 9000 9090 16686; do
  sudo iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT \
    --to-destination ${VM_IP}:${PORT}
  sudo iptables -A FORWARD -p tcp -d $VM_IP --dport $PORT -j ACCEPT
done
sudo iptables -t nat -A POSTROUTING -j MASQUERADE

# Persistir reglas
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

## Paso 6 — Snapshot inicial (punto de restauración)

```bash
# Apagar la VM limpiamente
virsh shutdown sdlc-vps

# Crear snapshot "base-oci-config"
virsh snapshot-create-as sdlc-vps \
  --name "base-oci-config" \
  --description "Ubuntu 26.04 limpio, configurado OCI-compatible" \
  --atomic

# Verificar
virsh snapshot-list sdlc-vps
```

---

## Paso 7 — Gestión de la VM

```bash
# Iniciar
virsh start sdlc-vps

# Apagar (limpio)
virsh shutdown sdlc-vps

# Forzar apagado
virsh destroy sdlc-vps

# Estado
virsh domstate sdlc-vps

# Consola serial
virsh console sdlc-vps

# Autostart al reiniciar el host
virsh autostart sdlc-vps

# Restaurar snapshot
virsh snapshot-revert sdlc-vps base-oci-config
```

---

## Migración a OCI — cambios mínimos requeridos

Cuando se decida migrar a Oracle Cloud, los únicos cambios son:

| Paso | Acción | Tiempo estimado |
|---|---|---|
| **1** | Crear instancia OCI: Shape `VM.Standard.A1.Flex`, 4 OCPU, 8 GB RAM, imagen Ubuntu 26.04, 120 GB Boot Volume | 5 min (consola OCI) |
| **2** | Copiar la clave SSH pública usada localmente a OCI al crear la instancia | Durante creación |
| **3** | Replicar reglas UFW como OCI Security List Ingress Rules (mismos puertos ya definidos) | 5 min |
| **4** | Cambiar NTP: `NTP=169.254.169.254` en `/etc/systemd/timesyncd.conf` | 1 min |
| **5** | Cambiar cloud-init datasource: `datasource_list: [Oracle, None]` | 1 min |
| **6** | Ejecutar `vps-setup.sh` (script de instalación de servicios) — idéntico al local | ~30 min |

**Total de cambios de configuración: 3 parámetros** (NTP server, cloud-init datasource, Security List).

Los scripts de instalación de servicios (`vps-setup.sh`), las configuraciones de systemd, los valores de Helm y los manifiestos de K3s son **idénticos** en local y en OCI.

---

## Estructura de archivos generados

```
~/vms/
  iso/
    ubuntu-26.04-live-server-amd64.iso
    SHA256SUMS
  disks/
    sdlc-vps.qcow2          ← disco de la VM (120 GB, formato qcow2)
```

Libvirt almacena la definición XML de la VM en:
```
/etc/libvirt/qemu/sdlc-vps.xml
```

---

## Eliminar la VM completamente

Para poder crear y eliminar la VM las veces que sea necesario, ejecutar los pasos en este orden. El proceso es destructivo e irreversible — borra disco, snapshots y definición.

### Eliminar en un solo bloque

```bash
# 1. Forzar apagado si está corriendo
virsh destroy sdlc-vps 2>/dev/null || true

# 2. Eliminar todos los snapshots
for snap in $(virsh snapshot-list sdlc-vps --name 2>/dev/null); do
  virsh snapshot-delete sdlc-vps --snapshotname "$snap"
done

# 3. Desregistrar la VM de libvirt (--remove-all-storage borra el qcow2)
virsh undefine sdlc-vps \
  --remove-all-storage \
  --snapshots-metadata \
  --nvram 2>/dev/null || true

# 4. Limpiar port-forwarding iptables del host
VM_IP="192.168.122.X"   # reemplazar con la IP que tenía la VM
for PORT in 22 80 443 3000 3001 4566 6443 8080 9000 9090 16686; do
  sudo iptables -t nat -D PREROUTING -p tcp --dport $PORT -j DNAT \
    --to-destination ${VM_IP}:${PORT} 2>/dev/null || true
  sudo iptables -D FORWARD -p tcp -d $VM_IP --dport $PORT -j ACCEPT 2>/dev/null || true
done
sudo netfilter-persistent save

# 5. Eliminar el disco si quedó huérfano (por si --remove-all-storage falló)
rm -f ~/vms/disks/sdlc-vps.qcow2

# 6. Verificar que no queda nada
virsh list --all | grep sdlc-vps || echo "VM eliminada correctamente"
ls ~/vms/disks/
```

### Verificar limpieza completa

```bash
# No debe aparecer ningún resultado
virsh list --all | grep sdlc-vps
virsh snapshot-list sdlc-vps 2>&1
ls ~/vms/disks/sdlc-vps.qcow2 2>&1
```

### Recrear desde cero

Una vez eliminada, volver al **Paso 1** del plan para crear el disco y la VM nuevamente:

```bash
# Recrear disco
qemu-img create -f qcow2 ~/vms/disks/sdlc-vps.qcow2 120G

# Recrear VM (mismo comando del Paso 2)
virt-install \
  --name sdlc-vps \
  --ram 8192 \
  --vcpus 4 \
  --cpu host \
  --os-variant ubuntu24.04 \
  --disk path=~/vms/disks/sdlc-vps.qcow2,format=qcow2,bus=virtio \
  --cdrom ~/vms/iso/ubuntu-26.04-live-server-amd64.iso \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --extra-args 'console=ttyS0,115200n8 serial' \
  --noautoconsole \
  --boot cdrom,hd
```

> La ISO ya está descargada en `~/vms/iso/` — no es necesario volver a descargarla.

---

## Referencia de comandos rápidos

```bash
# Ver todas las VMs
virsh list --all

# IP de la VM
virsh domifaddr sdlc-vps

# SSH a la VM
ssh ubuntu@$(virsh domifaddr sdlc-vps | awk '/ipv4/{print $4}' | cut -d/ -f1)

# Ver snapshots
virsh snapshot-list sdlc-vps

# Info de la VM
virsh dominfo sdlc-vps

# Editar CPU/RAM sin recrear
virsh setvcpus sdlc-vps 4 --config
virsh setmem   sdlc-vps 8388608 --config   # 8 GB en KB
```
