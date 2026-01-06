# =============================================================================
# Oracle Cloud Infrastructure - Free Tier VM para cliente WireGuard
# Región: Madrid (eu-madrid-1)
# =============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables - Personaliza estos valores
# -----------------------------------------------------------------------------

variable "tenancy_ocid" {
  description = "OCID del tenancy (lo encuentras en OCI Console -> Profile -> Tenancy)"
  type        = string
}

variable "user_ocid" {
  description = "OCID de tu usuario (OCI Console -> Profile -> My profile)"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint de tu API key"
  type        = string
}

variable "private_key_path" {
  description = "Ruta a tu clave privada de API (ej: ~/.oci/oci_api_key.pem)"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "Región de OCI"
  type        = string
  default     = "eu-madrid-1"
}

variable "ssh_public_key" {
  description = "Tu clave pública SSH para acceder a la VM"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Ruta a tu clave privada SSH (para esperar a cloud-init)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "vm_name" {
  description = "Nombre de la VM"
  type        = string
  default     = "vpn-client-madrid"
}

variable "allowed_ssh_cidr" {
  description = "IP o CIDR permitido para SSH e ICMP (ej: 88.20.45.123/32 para una IP, 0.0.0.0/0 para todas)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "availability_domain_number" {
  description = "Número del Availability Domain a usar (1, 2, 3...). Usa 0 para el primero disponible."
  type        = number
  default     = 0
}

variable "instance_shape" {
  description = "Shape de la instancia (VM.Standard.E2.1.Micro para Free Tier AMD, VM.Standard.A1.Flex para Free Tier ARM)"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_ocpus" {
  description = "Número de OCPUs (solo para shapes Flex). Free Tier ARM permite hasta 4 OCPUs totales."
  type        = number
  default     = 1
}

variable "instance_memory_gb" {
  description = "Memoria en GB (solo para shapes Flex). Free Tier ARM permite hasta 24GB totales."
  type        = number
  default     = 6
}

variable "vcn_cidr" {
  description = "CIDR block para la VCN (evita rangos comunes como 10.0.0.0/16 para no colisionar con VPNs)"
  type        = string
  default     = "10.100.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block para la subnet pública (debe estar dentro del vcn_cidr)"
  type        = string
  default     = "10.100.1.0/24"
}

# -----------------------------------------------------------------------------
# Provider
# -----------------------------------------------------------------------------

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

# Obtener el Availability Domain
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Imagen Ubuntu 22.04 (compatible con el shape seleccionado)
data "oci_core_images" "ubuntu" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# -----------------------------------------------------------------------------
# Networking - VCN
# -----------------------------------------------------------------------------

resource "oci_core_vcn" "vpn_vcn" {
  compartment_id = var.tenancy_ocid
  display_name   = "vcn-${var.vm_name}"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "vpnvcn"
}

# Internet Gateway - necesario para IP pública
resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "igw-${var.vm_name}"
  enabled        = true
}

# Route Table - ruta por defecto hacia Internet
resource "oci_core_route_table" "public_rt" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "rt-public-${var.vm_name}"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Security List - reglas de firewall
resource "oci_core_security_list" "vpn_sl" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "sl-${var.vm_name}"

  # Permitir todo el tráfico de salida (necesario para WireGuard cliente)
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH restringido a la IP especificada
  ingress_security_rules {
    source    = var.allowed_ssh_cidr
    protocol  = "6" # TCP
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP - para ping (restringido a la misma IP)
  ingress_security_rules {
    source    = var.allowed_ssh_cidr
    protocol  = "1" # ICMP
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    source    = var.allowed_ssh_cidr
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 8
    }
  }
}

# Subnet pública
resource "oci_core_subnet" "public_subnet" {
  compartment_id             = var.tenancy_ocid
  vcn_id                     = oci_core_vcn.vpn_vcn.id
  cidr_block                 = var.subnet_cidr
  display_name               = "subnet-public-${var.vm_name}"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public_rt.id
  security_list_ids          = [oci_core_security_list.vpn_sl.id]
  prohibit_public_ip_on_vnic = false # Permitir IPs públicas
}

# -----------------------------------------------------------------------------
# Compute - VM Free Tier
# -----------------------------------------------------------------------------

resource "oci_core_instance" "vpn_client" {
  compartment_id      = var.tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_number].name
  display_name        = var.vm_name
  shape               = var.instance_shape

  # Configuración de recursos para shapes Flex (ARM y otros)
  dynamic "shape_config" {
    for_each = length(regexall("Flex", var.instance_shape)) > 0 ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gb
    }
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public_subnet.id
    display_name     = "vnic-${var.vm_name}"
    assign_public_ip = true
    hostname_label   = var.vm_name
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOF
#!/bin/bash
set -e

# =============================================================================
# Configuración básica del sistema
# =============================================================================

# Hostname
hostnamectl set-hostname ${var.vm_name}

# Timezone
timedatectl set-timezone Europe/Madrid

# =============================================================================
# Instalación de paquetes
# =============================================================================

apt-get update
apt-get install -y \
  wireguard \
  wireguard-tools \
  resolvconf \
  htop \
  vim \
  curl \
  jq \
  net-tools \
  unattended-upgrades \
  fail2ban

# =============================================================================
# Seguridad - Actualizaciones automáticas
# =============================================================================

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE

# =============================================================================
# Seguridad - fail2ban para SSH
# =============================================================================

cat > /etc/fail2ban/jail.local << 'FAIL2BAN'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
FAIL2BAN

systemctl enable fail2ban
systemctl restart fail2ban

# =============================================================================
# Networking - IP forwarding
# =============================================================================

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# =============================================================================
# WireGuard - Preparar directorio y template
# =============================================================================

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /etc/wireguard/wg0.conf.template << 'WGTEMPLATE'
[Interface]
PrivateKey = <CLAVE_PRIVADA_CLIENTE>
Address = <IP_ASIGNADA_POR_UCG>/32

[Peer]
PublicKey = <CLAVE_PUBLICA_UCG>
Endpoint = <IP_PUBLICA_CASA>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGTEMPLATE

chmod 600 /etc/wireguard/wg0.conf.template

# =============================================================================
# Bashrc personalizado para usuario ubuntu
# =============================================================================

cat > /home/ubuntu/.bashrc << 'BASHRC'
# Permisos por defecto
umask 022

# Historial
export HISTFILESIZE=100000
export HISTSIZE=100000
export HISTTIMEFORMAT='%d%m%y %H%M%S -> '
export HISTCONTROL=ignoredups:erasedups

# Aliases - ls
alias ls='ls --color=auto'
alias ll='ls -laFh --color=auto'
alias l='ls -lFh --color=auto'
alias la='ls -A'

# Aliases - grep con color
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
export GREP_COLORS='ms=1;37'

# Aliases - utilidades
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'

# Función strace
strace() { command strace -Ff -s 512 "$@"; }

# MySQL prompt
export MYSQL_PS1='( \d ) > '

# Prompt: [HH:MM:SS] hostname - user [path]$
PS1='\[\e[1;38;5;245m\][\t]\[\e[0m\] \[\e[1;38;5;226m\]\h\[\e[0m\] - \[\e[1;38;5;84m\]\u\[\e[0m\] \[\e[1;38;5;196m\][\w]\$\[\e[0m\] '

# WireGuard aliases
alias wg-status='sudo wg show'
alias wg-up='sudo wg-quick up wg0'
alias wg-down='sudo wg-quick down wg0'
BASHRC

chown ubuntu:ubuntu /home/ubuntu/.bashrc

# Copiar bashrc también a root
cp /home/ubuntu/.bashrc /root/.bashrc

# =============================================================================
# Oracle Keep-Alive Service
# Evita que Oracle reclame la instancia por inactividad
# Criterios idle: CPU<10%, Network<10%, Memory<10% (ARM) durante 7 días
# =============================================================================

# Crear script de keep-alive
cat > /usr/local/bin/oci-keep-alive.sh << 'KEEPALIVE'
#!/bin/bash
# OCI Keep-Alive Script
# Genera carga mínima periódica para evitar que Oracle marque la instancia como idle

# Generar carga de CPU (~15% durante 30 segundos)
stress_cpu() {
    timeout 30 dd if=/dev/urandom bs=1M count=100 | md5sum > /dev/null 2>&1
}

# Generar tráfico de red (descarga pequeña)
stress_network() {
    curl -s -o /dev/null https://www.google.com
    curl -s -o /dev/null https://cloudflare.com/cdn-cgi/trace
}

# Generar uso de memoria (solo relevante para ARM)
stress_memory() {
    # Reserva temporal 512MB por 10 segundos
    python3 -c "
import time
data = bytearray(512 * 1024 * 1024)
time.sleep(10)
del data
" 2>/dev/null || true
}

echo "[$(date)] OCI Keep-Alive ejecutándose..."
stress_cpu
stress_network
stress_memory
echo "[$(date)] OCI Keep-Alive completado"
KEEPALIVE

chmod +x /usr/local/bin/oci-keep-alive.sh

# Crear servicio systemd
cat > /etc/systemd/system/oci-keep-alive.service << 'SERVICE'
[Unit]
Description=OCI Keep-Alive Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-keep-alive.sh
SERVICE

# Crear timer systemd (ejecutar cada 6 horas)
cat > /etc/systemd/system/oci-keep-alive.timer << 'TIMER'
[Unit]
Description=Run OCI Keep-Alive every 6 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
TIMER

# Habilitar y arrancar el timer
systemctl daemon-reload
systemctl enable oci-keep-alive.timer
systemctl start oci-keep-alive.timer

# =============================================================================
# Fin
# =============================================================================

echo "Cloud-init completado: $(date)" >> /var/log/cloud-init-custom.log
    EOF
    )
  }

  # Evitar que Oracle reclame la instancia
  instance_options {
    are_legacy_imds_endpoints_disabled = false
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "vm_public_ip" {
  description = "IP pública de la VM"
  value       = oci_core_instance.vpn_client.public_ip
}

output "vm_private_ip" {
  description = "IP privada de la VM"
  value       = oci_core_instance.vpn_client.private_ip
}

output "ssh_command" {
  description = "Comando para conectar por SSH"
  value       = "ssh ubuntu@${oci_core_instance.vpn_client.public_ip}"
}

output "vm_ocid" {
  description = "OCID de la instancia"
  value       = oci_core_instance.vpn_client.id
}

# -----------------------------------------------------------------------------
# Wait for cloud-init to complete
# -----------------------------------------------------------------------------

resource "null_resource" "wait_for_cloud_init" {
  depends_on = [oci_core_instance.vpn_client]

  connection {
    type        = "ssh"
    host        = oci_core_instance.vpn_client.public_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Esperando a que cloud-init termine...'",
      "sudo cloud-init status --wait",
      "echo 'Cloud-init completado!'",
      "cat /var/log/cloud-init-custom.log 2>/dev/null || echo 'Log no disponible aún'"
    ]
  }
}
