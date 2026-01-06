# Oracle Cloud Free Tier - VM con Terraform

Terraform para desplegar una VM **VM.Standard.E2.1.Micro** (Always Free) en Oracle Cloud Infrastructure, ideal para clientes VPN, jump hosts, o servicios ligeros.

## Qué despliega

**Infraestructura de red:**
- VCN con CIDR configurable (default: `10.100.0.0/16`)
- Internet Gateway
- Route Table con ruta por defecto a Internet
- Security List con SSH e ICMP restringidos a IP específica
- Subnet pública con CIDR configurable (default: `10.100.1.0/24`)

**VM Free Tier:**
- VM.Standard.E2.1.Micro (1/8 OCPU, 1GB RAM) con Ubuntu 22.04
- Hostname configurado automáticamente
- Timezone Europe/Madrid

**Software preinstalado (cloud-init):**
- WireGuard + wireguard-tools
- Herramientas: htop, vim, curl, jq, net-tools
- unattended-upgrades (actualizaciones de seguridad automáticas)
- fail2ban (protección SSH: ban 1h tras 5 intentos fallidos)

**Configuración adicional:**
- IP forwarding habilitado
- Directorio `/etc/wireguard` con permisos correctos + template de config
- Bashrc personalizado con aliases útiles (ll, wg-status, wg-up, wg-down, etc.) para usuarios `ubuntu` y `root`
- **OCI Keep-Alive Service**: evita que Oracle reclame la instancia por inactividad

## Requisitos

- Cuenta en [Oracle Cloud](https://cloud.oracle.com) (Free Tier)
- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) (opcional, para verificar capacidad)
- Clave SSH generada

## Verificar capacidad antes de desplegar

El Free Tier tiene capacidad limitada y es común encontrar el error "Out of host capacity". Antes de desplegar, verifica la disponibilidad:

### 1. Instalar y configurar OCI CLI

```bash
# macOS
brew install oci-cli

# Linux
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Configurar (usa los mismos datos que para Terraform)
oci setup config
```

### 2. Listar Availability Domains de una región

```bash
# Madrid
oci iam availability-domain list \
  --compartment-id <TU_TENANCY_OCID> \
  --region eu-madrid-1

# Frankfurt (tiene 3 ADs)
oci iam availability-domain list \
  --compartment-id <TU_TENANCY_OCID> \
  --region eu-frankfurt-1
```

### 3. Verificar capacidad por shape

**AMD Micro (VM.Standard.E2.1.Micro):**
```bash
oci compute compute-capacity-report create \
  --compartment-id <TU_TENANCY_OCID> \
  --availability-domain "<AD_NAME>" \
  --shape-availabilities '[{"instanceShape":"VM.Standard.E2.1.Micro"}]' \
  --region eu-madrid-1
```

**ARM Flex (VM.Standard.A1.Flex):**
```bash
oci compute compute-capacity-report create \
  --compartment-id <TU_TENANCY_OCID> \
  --availability-domain "<AD_NAME>" \
  --shape-availabilities '[{"instanceShape":"VM.Standard.A1.Flex"}]' \
  --region eu-frankfurt-1
```

**Respuesta esperada:**
```json
{
  "availability-status": "AVAILABLE"    // ✅ Hay capacidad
  "availability-status": "OUT_OF_HOST_CAPACITY"  // ❌ Sin capacidad
}
```

### 4. Script para verificar múltiples ADs

Si una región tiene varios ADs (como Frankfurt con 3), verifica todos:

```bash
#!/bin/bash
TENANCY="<TU_TENANCY_OCID>"
REGION="eu-frankfurt-1"
SHAPE="VM.Standard.A1.Flex"

for AD in $(oci iam availability-domain list --compartment-id $TENANCY --region $REGION --query 'data[].name' --raw-output | tr -d '[]",' | tr ' ' '\n'); do
  echo "Verificando $AD..."
  oci compute compute-capacity-report create \
    --compartment-id $TENANCY \
    --availability-domain "$AD" \
    --shape-availabilities "[{\"instanceShape\":\"$SHAPE\"}]" \
    --region $REGION \
    --query 'data."shape-availabilities"[0]."availability-status"' \
    --raw-output
done
```

## Habilitar nuevas regiones

Por defecto solo tienes acceso a tu **home region** (donde creaste la cuenta). Para desplegar en otras regiones:

### 1. Suscribirse a una región

1. Ve a [OCI Console](https://cloud.oracle.com)
2. Profile (arriba derecha) → **Manage Regions**
3. Busca la región deseada (ej: Germany Central - Frankfurt)
4. Clic en **Subscribe**
5. Espera 2-5 minutos hasta que aparezca como "Subscribed"

### 2. Replicar dominio de identidad (si es necesario)

Si al intentar usar la nueva región recibes errores de autenticación:

1. Ve a **Identity & Security → Domains**
2. Selecciona tu dominio (OracleIdentityCloudService)
3. **Actions → Gestionar regiones**
4. Añade la nueva región

### 3. Regiones recomendadas en Europa

| Región | Identificador | ADs | Notas |
|--------|---------------|-----|-------|
| Madrid | `eu-madrid-1` | 1 | Home region común en España |
| Frankfurt | `eu-frankfurt-1` | 3 | Mayor disponibilidad, más ADs |
| Amsterdam | `eu-amsterdam-1` | 1 | Buena alternativa |
| London | `uk-london-1` | 1 | Post-Brexit, puede variar |

### 4. Importante sobre shapes por región

| Shape | Disponibilidad |
|-------|----------------|
| `VM.Standard.E2.1.Micro` | **Solo en home region** |
| `VM.Standard.A1.Flex` | En cualquier región suscrita |

Si tu home region es Madrid y quieres desplegar en Frankfurt, **debes usar ARM (A1.Flex)**.

## Configuración inicial

### 1. Crear API Key para OCI

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
```

### 2. Subir API Key a OCI Console

1. OCI Console → Profile → My profile → API keys → Add API key
2. Pegar contenido de `~/.oci/oci_api_key_public.pem`
3. Guardar los valores que aparecen (tenancy, user, fingerprint)

### 3. Configurar variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edita `terraform.tfvars` con tus valores:

```hcl
tenancy_ocid               = "ocid1.tenancy.oc1..aaaa..."
user_ocid                  = "ocid1.user.oc1..aaaa..."
fingerprint                = "aa:bb:cc:dd:..."
private_key_path           = "~/.oci/oci_api_key.pem"
region                     = "eu-frankfurt-1"
ssh_public_key             = "ssh-rsa AAAAB3..."
ssh_private_key_path       = "~/.ssh/id_rsa"
vm_name                    = "my-vm"
allowed_ssh_cidr           = "YOUR_PUBLIC_IP/32"
availability_domain_number = 1
instance_shape             = "VM.Standard.A1.Flex"
instance_ocpus             = 1
instance_memory_gb         = 6
vcn_cidr                   = "10.100.0.0/16"
subnet_cidr                = "10.100.1.0/24"
```

Para obtener tu IP pública: `curl ifconfig.me`

### Variables disponibles

| Variable | Descripción | Default |
|----------|-------------|---------|
| `region` | Región de OCI | `eu-frankfurt-1` |
| `vm_name` | Nombre de la VM | `free-tier-vm` |
| `allowed_ssh_cidr` | IP/CIDR permitido para SSH | `0.0.0.0/0` |
| `availability_domain_number` | Índice del AD (0, 1, 2...) | `0` |
| `instance_shape` | Shape de la instancia | `VM.Standard.E2.1.Micro` |
| `instance_ocpus` | OCPUs (solo Flex) | `1` |
| `instance_memory_gb` | RAM en GB (solo Flex) | `6` |
| `vcn_cidr` | CIDR de la VCN | `10.100.0.0/16` |
| `subnet_cidr` | CIDR de la subnet pública | `10.100.1.0/24` |
| `ssh_private_key_path` | Ruta a clave privada SSH | `~/.ssh/id_rsa` |

### Shapes disponibles (Free Tier)

| Shape | Recursos | Disponibilidad |
|-------|----------|----------------|
| `VM.Standard.E2.1.Micro` | 1/8 OCPU, 1GB RAM | Solo home region |
| `VM.Standard.A1.Flex` | Configurable hasta 4 OCPU, 24GB RAM | Cualquier región suscrita |

### CIDRs recomendados

Para evitar colisiones con VPNs, túneles o redes corporativas, evita rangos comunes como `10.0.0.0/16` o `192.168.0.0/16`. Rangos recomendados:

- `10.100.0.0/16` (default)
- `10.99.0.0/16`
- `10.250.0.0/16`
- `172.20.0.0/16`

## Despliegue

```bash
terraform init
terraform plan
terraform apply
```

El despliegue incluye una espera automática hasta que cloud-init termine. Verás algo como:

```
null_resource.wait_for_cloud_init: Creating...
null_resource.wait_for_cloud_init: Provisioning with 'remote-exec'...
null_resource.wait_for_cloud_init (remote-exec): Connecting to remote host via SSH...
null_resource.wait_for_cloud_init (remote-exec): Esperando a que cloud-init termine...
null_resource.wait_for_cloud_init (remote-exec): status: done
null_resource.wait_for_cloud_init (remote-exec): Cloud-init completado!
null_resource.wait_for_cloud_init: Creation complete after 2m30s

Apply complete! Resources: 7 added, 0 changed, 0 destroyed.
```

**Nota:** Para que la espera funcione, la máquina que ejecuta Terraform debe poder conectar por SSH a la VM (verifica `allowed_ssh_cidr`).

## Outputs

```bash
terraform output vm_public_ip    # IP pública de la VM
terraform output ssh_command     # Comando SSH listo para usar
```

## Conexión

```bash
ssh ubuntu@$(terraform output -raw vm_public_ip)
```

## Configurar WireGuard

La VM viene con WireGuard instalado y un template de configuración:

```bash
# Copiar template
sudo cp /etc/wireguard/wg0.conf.template /etc/wireguard/wg0.conf

# Editar con tus valores
sudo vim /etc/wireguard/wg0.conf

# Activar
sudo wg-quick up wg0

# Habilitar en el arranque
sudo systemctl enable wg-quick@wg0
```

Aliases disponibles: `wg-status`, `wg-up`, `wg-down`

## Verificar cloud-init (opcional)

Terraform espera automáticamente a que cloud-init termine. Si necesitas verificar manualmente:

```bash
# Ver log personalizado
cat /var/log/cloud-init-custom.log

# Ver estado
cloud-init status

# Ver log completo
sudo cat /var/log/cloud-init-output.log
```

## OCI Keep-Alive (Anti-Idle)

Oracle puede reclamar instancias Free Tier que considere "idle" durante 7 días consecutivos. Los criterios son:

| Métrica | Umbral | Aplica a |
|---------|--------|----------|
| CPU (percentil 95) | < 10% | Todas las instancias |
| Network | < 10% | Todas las instancias |
| Memory | < 10% | Solo ARM (A1.Flex) |

Este Terraform incluye un servicio systemd que genera carga mínima cada 6 horas para evitar que la instancia sea marcada como idle.

```bash
# Ver estado del timer
systemctl status oci-keep-alive.timer

# Ver logs del servicio
journalctl -u oci-keep-alive.service

# Ejecutar manualmente
sudo /usr/local/bin/oci-keep-alive.sh
```

**Alternativa recomendada:** Convertir tu cuenta a Pay As You Go (PAYG). No te cobrarán mientras uses solo recursos Free Tier, pero evitarás el riesgo de reclamación.

## Despliegue en otras regiones

El Free Tier permite 2 VMs Micro (solo home region) o distribuir los 4 OCPUs ARM entre regiones.

1. Suscríbete a la región en OCI Console (Manage Regions)
2. Crea un nuevo directorio o workspace
3. Modifica `terraform.tfvars`:
   ```hcl
   region                     = "eu-amsterdam-1"
   vm_name                    = "vpn-client-amsterdam"
   availability_domain_number = 0
   instance_shape             = "VM.Standard.A1.Flex"
   vcn_cidr                   = "10.101.0.0/16"  # Diferente CIDR por región
   subnet_cidr                = "10.101.1.0/24"
   ```
4. `terraform init && terraform apply`

Regiones recomendadas: `eu-frankfurt-1`, `eu-amsterdam-1`, `uk-london-1`

## Solución de problemas

### Error: Out of host capacity

Si recibes este error, no hay VMs disponibles en ese AD. Opciones:

**1. Probar otro Availability Domain** (si la región tiene varios):
```hcl
availability_domain_number = 1  # Probar 0, 1, 2...
```

**2. Probar otra región:**
```hcl
region = "eu-frankfurt-1"  # Frankfurt suele tener más capacidad
```

**3. Script de reintento automático:**
```bash
until terraform apply -auto-approve; do
  echo "$(date): Sin capacidad, reintentando en 60s..."
  sleep 60
done
```

**4. Reintento en background:**
```bash
nohup bash -c 'until terraform apply -auto-approve; do sleep 60; done' > retry.log 2>&1 &
tail -f retry.log  # Ver progreso
```

Los huecos suelen aparecer de madrugada o temprano por la mañana.

### Error: NotAuthenticated en nueva región

La suscripción a la región tarda en propagarse. Espera 5-10 minutos y reintenta. Si persiste, replica el dominio de identidad (ver sección anterior).

### Error: 404-NotAuthorizedOrNotFound

Puede ser:
- Imagen no disponible para ese shape en esa región
- AD incorrecto
- Dominio de identidad no replicado

Limpia el state y reintenta:
```bash
terraform destroy -auto-approve
rm -rf .terraform terraform.tfstate*
terraform init
terraform apply
```

## Destruir recursos

```bash
terraform destroy
```

## Seguridad

- El archivo `terraform.tfvars` contiene datos sensibles y está en `.gitignore`
- SSH está restringido a la IP especificada en `allowed_ssh_cidr`
- Nunca subas claves `.pem` al repositorio

## Free Tier Limits

| Recurso | Límite Always Free | Notas |
|---------|-------------------|-------|
| VM.Standard.E2.1.Micro | 2 instancias | Solo disponible en home region |
| VM.Standard.A1.Flex (ARM) | 4 OCPUs / 24GB RAM total | Disponible en cualquier región suscrita |
| Boot Volume | 200GB total | |
| Object Storage | 20GB | |

**Nota importante:** El shape `VM.Standard.E2.1.Micro` (AMD) solo está disponible en tu **home region** (la región donde creaste la cuenta). Para otras regiones, usa `VM.Standard.A1.Flex` (ARM).

## Licencia

MIT
