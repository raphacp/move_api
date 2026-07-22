#!/usr/bin/env bash
# k3s.sh — Emula mgc kubernetes para clusters K3s na Magalu Cloud
# Move Tech 2026 (Magalu × Prósper Digital Skills)
#
# Uso:
#   k3s.sh kubernetes cluster create              --name NOME
#   k3s.sh kubernetes cluster start               --cluster-id ID
#   k3s.sh kubernetes cluster stop                --cluster-id ID
#   k3s.sh kubernetes cluster kubeconfig          --cluster-id ID --raw > arquivo.yaml
#   k3s.sh kubernetes cluster list
#   k3s.sh kubernetes cluster get                 --cluster-id ID
#   k3s.sh kubernetes cluster delete              --cluster-id ID
#   k3s.sh kubernetes cluster configure-registry  --cluster-id ID
#   k3s.sh network ip-cleanup

set -euo pipefail

# ─── Auto-update ──────────────────────────────────────────────────────────────
SCRIPT_URL="https://raw.githubusercontent.com/move-tech-cloud-computing/k3s-mgc/main/k3s.sh"

_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

check_update() {
  local tmp; tmp=$(mktemp)
  curl --connect-timeout 3 -sf "${SCRIPT_URL}?$(date +%s)" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

  local local_hash remote_hash
  local_hash=$(_sha256 "$0")
  remote_hash=$(_sha256 "$tmp")

  if [[ "$local_hash" == "$remote_hash" ]]; then
    rm -f "$tmp"
    return 0
  fi

  echo -e "\n${Y}⚠${N} Uma versão mais recente do script está disponível."
  local _upd="n"
  [[ -t 0 ]] && read -rp "  Atualizar agora? [s/N] " _upd
  if [[ "$(echo "$_upd" | tr '[:upper:]' '[:lower:]')" == "s" ]]; then
    chmod +x "$tmp"
    mv "$tmp" "$0"
    echo -e "${G}✓${N} Script atualizado. Rode o comando novamente."
    exit 0
  fi
  rm -f "$tmp"
  echo ""
}

# ─── Constantes ───────────────────────────────────────────────────────────────
SG_NAME="sg-k3s-cluster"
MACHINE_TYPE="BV2-2-40"
IMAGE_NAME="cloud-ubuntu-24.04 LTS"
VM_USER="ubuntu"
SSH_KEY_NAME="ssh-k3s-cluster"
SSH_KEY_PATH="${HOME}/.ssh/${SSH_KEY_NAME}"

# ─── Cores ────────────────────────────────────────────────────────────────────
G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m'
C='\033[0;36m' B='\033[1m'   D='\033[2m' N='\033[0m'

ok()        { echo -e "${G}✓${N} $*"; }
info()      { echo -e "${C}→${N} $*"; }
warn()      { echo -e "${Y}⚠${N} $*"; }
die()       { echo -e "\n${R}✗${N} $*\n" >&2; exit 1; }
hdr()       { echo -e "\n┌ ${B}$*${N}"; }
step()      { echo -e "\n${C}→${N} $(printf '%-20s' "$1") $2"; }
step_ok()   { echo -e "${G}✓${N} $(printf '%-20s' "$1") $2"; }
step_data() { printf "    %-10s %s\n" "$1" "$2"; }

# ─── mgc wrapper que strip ANSI e força JSON ──────────────────────────────────
mgcj() { "$@" --output json 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Lookups de cluster via API ───────────────────────────────────────────────

# Retorna JSON {vm_id, name, ip} buscando pelo ID da VM, ou falha com exit 1
cluster_by_id() {
  local vm_id="$1"
  local vm_json
  vm_json=$(mgcj mgc virtual-machine instances get "$vm_id" 2>/dev/null) || return 1
  echo "$vm_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
name = d.get('name', '')
if not name.startswith('vm-k3s-cluster-'):
    sys.exit(1)
ifaces = d.get('network', {}).get('interfaces', [])
ip = ifaces[0].get('associated_public_ipv4', '') if ifaces else ''
print(json.dumps({'vm_id': d['id'], 'name': name[len('vm-k3s-cluster-'):], 'ip': ip}))
" 2>/dev/null
}

# Lista todos os clusters como linhas "vm_id|name|ip"
list_clusters() {
  mgcj mgc virtual-machine instances list | python3 -c "
import json, sys
vms = json.load(sys.stdin).get('instances', [])
prefix = 'vm-k3s-cluster-'
for v in vms:
    n = v.get('name', '')
    if not n.startswith(prefix):
        continue
    ifaces = v.get('network', {}).get('interfaces', [])
    ip = ifaces[0].get('associated_public_ipv4', '—') if ifaces else '—'
    print(v['id'] + '|' + n[len(prefix):] + '|' + ip)
" 2>/dev/null || true
}

# Conta clusters restantes, excluindo o VM ID informado
count_clusters_except() {
  local exclude_id="$1"
  mgcj mgc virtual-machine instances list | python3 -c "
import json, sys
vms = json.load(sys.stdin).get('instances', [])
print(sum(1 for v in vms
          if v.get('name', '').startswith('vm-k3s-cluster-')
          and v.get('id', '') != '$exclude_id'))
" 2>/dev/null || echo "0"
}

# Retorna o ID do SG pelo nome, ou string vazia
get_sg_id() {
  mgcj mgc network security-groups list | python3 -c "
import json, sys
sgs = json.load(sys.stdin).get('security_groups', [])
match = [s for s in sgs if s.get('name') == '${SG_NAME}']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo ""
}

# ─── Pré-requisitos ───────────────────────────────────────────────────────────
check_prereqs() {
  command -v mgc     >/dev/null 2>&1 || die "mgc CLI não encontrado. Veja: https://docs.magalu.cloud/docs/cli-mgc"
  command -v ssh     >/dev/null 2>&1 || die "ssh não encontrado."
  command -v python3 >/dev/null 2>&1 || die "python3 não encontrado."
  command -v kubectl >/dev/null 2>&1 || warn "kubectl não encontrado. Instale: https://kubernetes.io/docs/tasks/tools/"
  mgcj mgc virtual-machine instances list >/dev/null 2>&1 || die "mgc não autenticado. Execute: mgc auth login"
}

# ─── Garante chave SSH dedicada ───────────────────────────────────────────────
_ssh_status=""  # "criada" | "já existia"

ensure_ssh_key() {
  step "Chave SSH" "Verificando chave SSH"

  if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_PATH}" -C "k3s-mgc" >/dev/null 2>&1
    chmod 600 "${SSH_KEY_PATH}"
    _ssh_status="gerada"
  else
    _ssh_status="já existia"
  fi

  local registered
  registered=$(mgcj mgc profile ssh-keys list | python3 -c "
import json, sys
keys = json.load(sys.stdin).get('results', [])
print('yes' if any(k.get('name') == '${SSH_KEY_NAME}' for k in keys) else 'no')
" 2>/dev/null || echo "no")

  if [[ "$registered" == "no" ]]; then
    mgcj mgc profile ssh-keys create \
      --name="${SSH_KEY_NAME}" \
      --key="$(cat "${SSH_KEY_PATH}.pub")" >/dev/null || die "Falha ao cadastrar chave SSH na Magalu Cloud"
    _ssh_status="cadastrada"
  fi

  step_ok "Chave SSH" "Chave ${_ssh_status}"
  step_data "Nome"  "${SSH_KEY_NAME}"
  step_data "Local" "${SSH_KEY_PATH}"
}

# ─── SSH helper ───────────────────────────────────────────────────────────────
vm_ssh() { ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "${VM_USER}@${1}" "${@:2}"; }

wait_ssh() {
  local ip="$1"
  step "SSH" "Aguardando conexão"
  for i in $(seq 1 60); do
    if ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
         ubuntu@"$ip" "exit 0" 2>/dev/null; then
      step_ok "SSH" "Conexão estabelecida"
      return 0
    fi
    sleep 5
  done
  die "Timeout ao aguardar SSH (300s). Verifique a VM no console da MGC."
}

# ─── Garante Security Group ───────────────────────────────────────────────────
_sg_id=""  # preenchido por ensure_sg

ensure_sg() {
  step "Security Group" "Verificando grupo de segurança"

  _sg_id=$(get_sg_id)

  if [[ -n "$_sg_id" ]]; then
    step_ok "Security Group" "Grupo já existente"
    step_data "Nome" "${SG_NAME}"
    step_data "ID"   "${_sg_id}"
    return
  fi

  local sg_json
  sg_json=$(mgcj mgc network security-groups create \
    --name="${SG_NAME}" \
    --description="K3s — Move Tech") || die "Falha ao criar Security Group"

  _sg_id=$(echo "$sg_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" || echo "")
  [[ -n "$_sg_id" ]] || die "Não foi possível obter o ID do Security Group"

  for port in 22 80 8000 6443; do
    mgcj mgc network security-groups rules create \
      --security-group-id="$_sg_id" --direction="ingress" --ethertype="IPv4" \
      --protocol="tcp" --port-range-min=$port --port-range-max=$port \
      --remote-ip-prefix="0.0.0.0/0" --wait >/dev/null
    mgcj mgc network security-groups rules create \
      --security-group-id="$_sg_id" --direction="ingress" --ethertype="IPv6" \
      --protocol="tcp" --port-range-min=$port --port-range-max=$port \
      --remote-ip-prefix="::/0" --wait >/dev/null
  done

  mgcj mgc network security-groups rules create \
    --security-group-id="$_sg_id" --direction="egress" --ethertype="IPv4" \
    --protocol="tcp" --remote-ip-prefix="0.0.0.0/0" --wait >/dev/null
  mgcj mgc network security-groups rules create \
    --security-group-id="$_sg_id" --direction="egress" --ethertype="IPv6" \
    --protocol="tcp" --remote-ip-prefix="::/0" --wait >/dev/null

  step_ok "Security Group" "Grupo criado com sucesso"
  step_data "Nome"   "${SG_NAME}"
  step_data "ID"     "${_sg_id}"
  step_data "Portas" "22 (SSH)  80 (HTTP)  8000 (API)  6443 (Kubernetes)"
}

# ─── COMANDO: create ──────────────────────────────────────────────────────────
cmd_create() {
  local name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)   name="$2";      shift 2 ;;
      --name=*) name="${1#*=}"; shift   ;;
      *) shift ;;
    esac
  done

  [[ -n "$name" ]] || die "Informe o nome do cluster: --name NOME"

  local vm_name="vm-k3s-cluster-${name}"

  hdr "Criando cluster '${name}'"

  check_prereqs
  ensure_ssh_key
  ensure_sg
  local sg_id="$_sg_id"

  # ── VM ───────────────────────────────────────────────────────────────────
  local vm_id
  vm_id=$(mgcj mgc virtual-machine instances list | python3 -c "
import json,sys
vms=[v for v in json.load(sys.stdin).get('instances',[]) if v.get('name')=='${vm_name}']
print(vms[0]['id'] if vms else '')
" 2>/dev/null || echo "")

  if [[ -n "$vm_id" ]]; then
    step "Máquina virtual" "Verificando VM"
    step_ok "Máquina virtual" "VM já existente"
    step_data "Nome" "${vm_name}"
    step_data "ID"   "${vm_id}"
  else
    local vpc_id
    vpc_id=$(mgcj mgc network vpcs list | python3 -c "
import json,sys
vpcs=[v for v in json.load(sys.stdin).get('vpcs',[]) if v.get('name')=='vpc_default']
print(vpcs[0]['id'] if vpcs else '')
" 2>/dev/null || echo "")
    [[ -n "$vpc_id" ]] || die "vpc_default não encontrada."

    local ip_quota_ok
    ip_quota_ok=$(mgcj mgc network public-ips list | python3 -c "
import json,sys
ips = json.load(sys.stdin).get('public_ips', [])
orphans = [ip for ip in ips if ip.get('port_id') is None and ip.get('status') == 'created']
print(len(orphans))
" 2>/dev/null || echo "0")
    if [[ "$ip_quota_ok" -gt 0 ]]; then
      echo ""
      warn "Há ${ip_quota_ok} IP(s) público(s) órfão(s) que podem consumir sua cota."
      warn "Se a criação falhar, execute: ./k3s.sh network ip-cleanup"
      echo ""
    fi

    step "Máquina virtual" "Criando VM"
    local vm_json
    vm_json=$(mgcj mgc virtual-machine instances create \
      --name="${vm_name}" \
      --machine-type.name="${MACHINE_TYPE}" \
      --image.name="${IMAGE_NAME}" \
      --ssh-key-name="${SSH_KEY_NAME}" \
      --network.vpc.id="${vpc_id}" \
      --network.associate-public-ip=true \
      --network.interface.security-groups="[{\"id\":\"${sg_id}\"}]") || die "Falha ao criar VM"

    vm_id=$(echo "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" || echo "")
    [[ -n "$vm_id" ]] || die "Não foi possível obter o ID da VM"

    step_ok "Máquina virtual" "VM criada com sucesso"
    step_data "Nome"   "${vm_name}"
    step_data "ID"     "${vm_id}"
    step_data "Tipo"   "${MACHINE_TYPE}"
    step_data "Imagem" "Ubuntu 24.04 LTS"
  fi

  # ── IP público ───────────────────────────────────────────────────────────
  local vm_ip=""
  step "IP público" "Aguardando atribuição"
  for i in $(seq 1 30); do
    vm_ip=$(mgcj mgc virtual-machine instances get "$vm_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
    [[ -n "$vm_ip" ]] && break
    sleep 5
  done
  [[ -n "$vm_ip" ]] || die "IP público não atribuído. Execute: ./k3s.sh network ip-cleanup"
  step_ok "IP público" "IP atribuído"
  step_data "Endereço" "${vm_ip}"

  # ── SSH ──────────────────────────────────────────────────────────────────
  wait_ssh "$vm_ip"

  # ── K3s ──────────────────────────────────────────────────────────────────
  local k3s_installed
  k3s_installed=$(vm_ssh "$vm_ip" "command -v k3s >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "no")

  if [[ "$k3s_installed" == "yes" ]]; then
    step "K3s" "Verificando instalação"
    step_ok "K3s" "K3s já instalado"
  else
    step "K3s" "Instalando K3s"
    vm_ssh "$vm_ip" \
      "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--tls-san ${vm_ip} --disable=traefik --node-external-ip=${vm_ip}' sudo -E sh - >/dev/null 2>&1"
    local k3s_version
    k3s_version=$(vm_ssh "$vm_ip" "k3s --version 2>/dev/null | head -1 | awk '{print \$3}'" 2>/dev/null || echo "desconhecida")
    step_ok "K3s" "K3s instalado com sucesso"
    step_data "Versão" "${k3s_version}"
  fi

  # ── Aguarda K3s Ready ────────────────────────────────────────────────────
  step "Cluster" "Aguardando nó ficar pronto"
  local status=""
  for i in $(seq 1 24); do
    status=$(vm_ssh "$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
    [[ "$status" == "Ready" ]] && break
    sleep 5
  done
  [[ "$status" == "Ready" ]] || die "K3s não ficou Ready após 120s."
  step_ok "Cluster" "Nó pronto"

  # ── Kubeconfig ───────────────────────────────────────────────────────────
  step "kubectl" "Configurando acesso ao cluster"
  mkdir -p "${HOME}/.kube"
  vm_ssh "$vm_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${vm_ip}/g" \
    > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  step_ok "kubectl" "Configurado com sucesso"
  step_data "Arquivo"  "${HOME}/.kube/config"
  step_data "Contexto" "default"

  # ── Container Registry (interativo) ──────────────────────────────────────
  if [[ -t 0 ]]; then
    echo ""
    read -rp "  Deseja configurar acesso a um Container Registry? [s/N] " _reg_ans
    if [[ "$(echo "$_reg_ans" | tr '[:upper:]' '[:lower:]')" == "s" ]]; then
      setup_registry
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${G}${B}✓ Cluster '${name}' pronto!${N}"
  echo ""
  echo -e "  ID do cluster:  ${C}${vm_id}${N}"
  echo -e "  Verificar:      ${C}kubectl get nodes${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── COMANDO: kubeconfig ──────────────────────────────────────────────────────
cmd_kubeconfig() {
  local cluster_id="" raw=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      --raw|-r) raw=1; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
  local vm_ip
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  if [[ "$raw" -eq 1 ]]; then
    vm_ssh "$vm_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/${vm_ip}/g"
  else
    die "Use --raw para obter o kubeconfig:\n  ./k3s.sh kubernetes cluster kubeconfig --cluster-id ${cluster_id} --raw > meu-cluster.yaml"
  fi
}

# ─── COMANDO: list ────────────────────────────────────────────────────────────
cmd_list() {
  local clusters
  clusters=$(list_clusters)

  if [[ -z "$clusters" ]]; then
    echo "Nenhum cluster encontrado."
    return
  fi

  printf "%-20s %-40s %-15s\n" "NOME" "ID (--cluster-id)" "IP"
  printf "%-20s %-40s %-15s\n" "────────────────────" "────────────────────────────────────────" "───────────────"

  while IFS='|' read -r vm_id name ip; do
    [[ -z "$name" ]] && continue
    printf "%-20s %-40s %-15s\n" "$name" "$vm_id" "$ip"
  done <<< "$clusters"
}

# ─── COMANDO: get ─────────────────────────────────────────────────────────────
cmd_get() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado."

  local name vm_ip
  name=$(echo "$cluster"  | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  local k3s_version k3s_status
  k3s_version=$(vm_ssh "$vm_ip" "k3s --version 2>/dev/null | head -1 | awk '{print \$3}'" 2>/dev/null || echo "—")
  k3s_status=$(vm_ssh "$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "—")

  echo ""
  echo -e "${B}Cluster: ${name}${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-18s %s\n" "Nome:"       "${name}"
  printf "  %-18s %s\n" "ID:"         "${cluster_id}"
  printf "  %-18s %s\n" "Status:"     "${k3s_status}"
  printf "  %-18s %s\n" "IP:"         "${vm_ip}"
  printf "  %-18s %s\n" "Versão K3s:" "${k3s_version}"
  echo ""
}

# ─── COMANDO: delete ──────────────────────────────────────────────────────────
cmd_delete() {
  local cluster_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado."

  local name vm_ip
  name=$(echo "$cluster"  | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  hdr "Deletando cluster '${name}'"
  echo ""
  local confirm="n"
  [[ -t 0 ]] && read -rp "  Confirmar exclusão de '${name}' (${vm_ip})? [s/N] " confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "s" ]] || { echo "Cancelado."; exit 0; }

  step "Máquina virtual" "Deletando VM"
  if mgcj mgc virtual-machine instances delete "$cluster_id" --no-confirm --delete-public-ip >/dev/null; then
    step_ok "Máquina virtual" "VM deletada"
    step_data "IP liberado" "${vm_ip}"
  else
    warn "Falha ao deletar VM"
  fi

  local remaining
  remaining=$(count_clusters_except "$cluster_id")

  if [[ "$remaining" -eq 0 ]]; then
    local sg_id
    sg_id=$(get_sg_id)
    if [[ -n "$sg_id" ]]; then
      step "Security Group" "Deletando grupo de segurança"
      if mgcj mgc network security-groups delete --security-group-id "$sg_id" --no-confirm >/dev/null 2>&1; then
        step_ok "Security Group" "Grupo deletado"
      else
        warn "Falha ao deletar Security Group (pode já ter sido removido)"
      fi
    fi
  else
    warn "Security Group mantido — ainda há ${remaining} cluster(s) usando."
  fi

  echo ""
  ok "Cluster '${name}' removido."
}

# ─── COMANDO: stop ────────────────────────────────────────────────────────────
cmd_stop() {
  local cluster_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
  local name
  name=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")

  hdr "Parando cluster '${name}'"

  step "Máquina virtual" "Parando VM"
  mgcj mgc virtual-machine instances stop "$cluster_id" >/dev/null || die "Falha ao parar VM"
  step_ok "Máquina virtual" "VM parada"

  echo ""
  ok "Cluster '${name}' parado."
}

# ─── COMANDO: start ───────────────────────────────────────────────────────────
cmd_start() {
  local cluster_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"

  local cluster
  cluster=$(cluster_by_id "$cluster_id") || die "Cluster '${cluster_id}' não encontrado. Liste com: ./k3s.sh kubernetes cluster list"
  local name vm_ip_anterior
  name=$(echo "$cluster"         | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  vm_ip_anterior=$(echo "$cluster" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")

  hdr "Iniciando cluster '${name}'"

  step "Máquina virtual" "Iniciando VM"
  mgcj mgc virtual-machine instances start "$cluster_id" >/dev/null || die "Falha ao iniciar VM"
  step_ok "Máquina virtual" "VM iniciada"

  step "IP público" "Aguardando IP"
  local vm_ip=""
  for i in $(seq 1 30); do
    vm_ip=$(mgcj mgc virtual-machine instances get "$cluster_id" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ifaces=d.get('network',{}).get('interfaces',[])
print(ifaces[0].get('associated_public_ipv4','') if ifaces else '')
" 2>/dev/null || echo "")
    [[ -n "$vm_ip" ]] && break
    sleep 5
  done
  [[ -n "$vm_ip" ]] || die "IP público não disponível após iniciar VM."

  if [[ "$vm_ip" != "$vm_ip_anterior" ]]; then
    step_ok "IP público" "IP atribuído (alterado: ${vm_ip_anterior} → ${vm_ip})"
  else
    step_ok "IP público" "IP atribuído (${vm_ip})"
  fi

  wait_ssh "$vm_ip"

  # Atualiza node-external-ip no K3s se o IP mudou
  if [[ "$vm_ip" != "$vm_ip_anterior" ]]; then
    step "K3s" "Atualizando IP externo"
    vm_ssh "$vm_ip" \
      "printf 'node-external-ip: ${vm_ip}\ndisable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml >/dev/null && sudo systemctl restart k3s" \
      2>/dev/null || warn "Não foi possível atualizar node-external-ip (continue manualmente se necessário)"
    sleep 5
    step_ok "K3s" "IP externo atualizado"
  fi

  step "kubectl" "Atualizando acesso ao cluster"
  mkdir -p "${HOME}/.kube"
  vm_ssh "$vm_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${vm_ip}/g" \
    > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  step_ok "kubectl" "Configurado"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${G}${B}✓ Cluster '${name}' disponível!${N}"
  echo ""
  echo -e "  Verificar:  ${C}kubectl get nodes${N}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Helper: configurar Container Registry no cluster ────────────────────────
setup_registry() {
  info "Buscando Container Registries disponíveis"
  local reg_json
  reg_json=$(mgcj mgc container-registry registries list 2>/dev/null) || { warn "Falha ao listar registries."; return; }

  local registries
  registries=$(echo "$reg_json" | python3 -c "
import json,sys
results = json.load(sys.stdin).get('results', [])
for r in results:
    print(r['id'] + '|' + r['name'])
" 2>/dev/null || echo "")

  local reg_id="" reg_name=""

  if [[ -n "$registries" ]]; then
    echo ""
    local i=1
    while IFS='|' read -r rid rname; do
      echo -e "  [${i}] ${rname}"
      i=$((i+1))
    done <<< "$registries"
    echo -e "  [${i}] Criar novo registry"
    echo -e "  [0] Pular"
    echo ""
    read -rp "  Escolha: " _choice

    if [[ "$_choice" == "0" ]]; then
      warn "Registry não configurado. Para configurar depois: ./k3s.sh kubernetes cluster configure-registry --cluster-id ID"
      return
    fi

    local count; count=$(echo "$registries" | wc -l | tr -d ' ')
    if [[ "$_choice" -le "$count" ]] 2>/dev/null; then
      local line; line=$(echo "$registries" | sed -n "${_choice}p")
      reg_id="${line%%|*}"
      reg_name="${line##*|}"
    else
      read -rp "  Nome do novo registry: " reg_name
      [[ -n "$reg_name" ]] || { warn "Nome inválido. Pulando."; return; }
      info "Criando registry '${reg_name}'"
      mgcj mgc container-registry registries create --name="$reg_name" >/dev/null \
        || { warn "Falha ao criar registry."; return; }
      ok "Registry '${reg_name}' criado"
    fi
  else
    echo ""
    echo -e "  Nenhum Container Registry encontrado."
    echo -e "  [1] Criar novo registry"
    echo -e "  [0] Pular"
    echo ""
    read -rp "  Escolha: " _choice
    if [[ "$_choice" != "1" ]]; then
      warn "Registry não configurado. Para configurar depois: ./k3s.sh kubernetes cluster configure-registry --cluster-id ID"
      return
    fi
    read -rp "  Nome do novo registry: " reg_name
    [[ -n "$reg_name" ]] || { warn "Nome inválido. Pulando."; return; }
    info "Criando registry '${reg_name}'"
    mgcj mgc container-registry registries create --name="$reg_name" >/dev/null \
      || { warn "Falha ao criar registry."; return; }
    ok "Registry '${reg_name}' criado"
  fi

  info "Obtendo credenciais do Container Registry"
  local creds
  creds=$(mgcj mgc container-registry credentials get 2>/dev/null) || { warn "Falha ao obter credenciais."; return; }
  local cr_user cr_pass
  cr_user=$(echo "$creds" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null)
  cr_pass=$(echo "$creds" | python3 -c "import json,sys; print(json.load(sys.stdin).get('password',''))" 2>/dev/null)
  [[ -n "$cr_user" && -n "$cr_pass" ]] || { warn "Credenciais vazias."; return; }

  kubectl create secret docker-registry mgc-registry-secret \
    --docker-server="container-registry.br-se1.magalu.cloud" \
    --docker-username="$cr_user" \
    --docker-password="$cr_pass" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  kubectl patch serviceaccount default \
    -p '{"imagePullSecrets": [{"name": "mgc-registry-secret"}]}' >/dev/null 2>&1

  ok "Registry '${reg_name:-container-registry}' configurado (mgc-registry-secret)"
}

# ─── COMANDO: cluster configure-registry ─────────────────────────────────────
cmd_configure_registry() {
  local cluster_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-id) cluster_id="$2"; shift 2 ;;
      --cluster-id=*) cluster_id="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$cluster_id" ]] || die "Informe o ID do cluster: --cluster-id ID"
  cluster_by_id "$cluster_id" >/dev/null || die "Cluster '${cluster_id}' não encontrado."
  setup_registry
}

# ─── COMANDO: network ip-cleanup ─────────────────────────────────────────────
cmd_ip_cleanup() {
  hdr "IPs públicos órfãos"

  local list
  list=$(mgcj mgc network public-ips list 2>/dev/null) || die "Falha ao listar IPs públicos"

  local orphans
  orphans=$(echo "$list" | python3 -c "
import json,sys
ips = json.load(sys.stdin).get('public_ips', [])
orphans = [ip for ip in ips if ip.get('port_id') is None and ip.get('status') == 'created']
import json as j
print(j.dumps(orphans))
" 2>/dev/null || echo "[]")

  local count
  count=$(echo "$orphans" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [[ "$count" -eq 0 ]]; then
    ok "Nenhum IP público órfão encontrado."
    return
  fi

  echo ""
  echo -e "${Y}${count} IP(s) público(s) sem VM associada:${N}"
  echo "$orphans" | python3 -c "
import json,sys
for ip in json.load(sys.stdin):
    print(f\"  {ip['public_ip']}  (id: {ip['id']})\")
"
  echo ""
  read -rp "  Deletar todos? [s/N] " confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "s" ]] || { echo "Cancelado."; return; }

  echo "$orphans" | python3 -c "
import json,sys
for ip in json.load(sys.stdin):
    print(ip['id'])
" | while read -r ip_id; do
    mgcj mgc network public-ips delete --public-ip-id "$ip_id" --no-confirm >/dev/null 2>&1 \
      && ok "Deletado: ${ip_id}" \
      || warn "Não foi possível deletar ${ip_id}"
  done
}

# ─── Help ─────────────────────────────────────────────────────────────────────
cmd_help() {
  echo ""
  echo -e "${B}k3s.sh${N} — Kubernetes local via K3s na Magalu Cloud"
  echo ""
  echo "Uso:"
  echo -e "  ${C}./k3s.sh kubernetes cluster create              --name NOME${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster start               --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster stop                --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster kubeconfig          --cluster-id ID --raw > arquivo.yaml${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster list${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster get                 --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster delete              --cluster-id ID${N}"
  echo -e "  ${C}./k3s.sh kubernetes cluster configure-registry  --cluster-id ID${N}"
  echo ""
  echo -e "  ${C}./k3s.sh network ip-cleanup${N}   — lista e remove IPs públicos órfãos"
  echo ""
  echo "Equivalente aos comandos 'mgc kubernetes cluster ...' do MKS."
  echo "A região utilizada é a configurada no mgc CLI: mgc profile region set"
  echo ""
}

# ─── Router ───────────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { cmd_help; exit 0; }
check_update

case "${1:-} ${2:-} ${3:-}" in
  "kubernetes cluster create"*)              shift 3; cmd_create              "$@" ;;
  "kubernetes cluster start"*)               shift 3; cmd_start               "$@" ;;
  "kubernetes cluster stop"*)                shift 3; cmd_stop                "$@" ;;
  "kubernetes cluster kubeconfig"*)          shift 3; cmd_kubeconfig          "$@" ;;
  "kubernetes cluster list"*)                shift 3; cmd_list                     ;;
  "kubernetes cluster get"*)                 shift 3; cmd_get                 "$@" ;;
  "kubernetes cluster delete"*)              shift 3; cmd_delete              "$@" ;;
  "kubernetes cluster configure-registry"*)  shift 3; cmd_configure_registry  "$@" ;;
  "network ip-cleanup"*)                     shift 2; cmd_ip_cleanup               ;;
  *) cmd_help ;;
esac
