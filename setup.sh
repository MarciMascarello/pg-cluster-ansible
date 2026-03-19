#!/usr/bin/env bash
# =============================================================================
# setup.sh — Interactive configuration wizard for PostgreSQL HA Cluster
#            Patroni + Etcd + Keepalived
#
# Automatically generates:
#   - inventory/hosts.ini
#   - group_vars/all.yml
#
# Usage: bash setup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${SCRIPT_DIR}/inventory/hosts.ini"
VARS_FILE="${SCRIPT_DIR}/group_vars/all.yml"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --- Helper functions (all display output goes to stderr to avoid polluting $(...) captures) ---
header() { echo -e "\n${BLUE}${BOLD}╔══ $1 ══╗${NC}\n" >&2; }
info()   { echo -e "${CYAN}  $1${NC}" >&2; }
ok()     { echo -e "${GREEN}  ✓ $1${NC}" >&2; }
warn()   { echo -e "${YELLOW}  ⚠ $1${NC}" >&2; }
error()  { echo -e "${RED}  ✗ $1${NC}" >&2; }
sep()    { echo -e "${BLUE}  ─────────────────────────────────────────${NC}" >&2; }

ask() {
    local prompt="$1" default="${2:-}" result
    if [[ -n "$default" ]]; then
        read -rp "  ${prompt} [${default}]: " result
        echo "${result:-$default}"
    else
        while true; do
            read -rp "  ${prompt}: " result
            [[ -n "$result" ]] && break
            error "Required field."
        done
        echo "$result"
    fi
}

ask_optional() {
    local prompt="$1" default="${2:-}"
    read -rp "  ${prompt}${default:+ [${default}]}: " result
    echo "${result:-$default}"
}

ask_password() {
    local prompt="$1" value confirm
    while true; do
        read -rsp "  ${prompt} [Enter=auto-generate]: " value; echo >&2
        if [[ -z "$value" ]]; then
            value=$(gen_pass)
            echo -e "  ${GREEN}  → Generated: ${BOLD}${value}${NC}" >&2
            echo "$value"; return
        fi
        read -rsp "  Confirm password: " confirm; echo >&2
        [[ "$value" == "$confirm" ]] && break
        error "Passwords do not match. Try again."
    done
    echo "$value"
}

gen_pass() {
    python3 -c \
        "import secrets,string; a=string.ascii_letters+string.digits; \
         print(''.join(secrets.choice(a) for _ in range(20)))" 2>/dev/null || \
    openssl rand -base64 15 | tr -d '+/= \n'
}

ask_ip() {
    local prompt="$1" value
    while true; do
        read -rp "  ${prompt}: " value
        if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            IFS='.' read -ra p <<< "$value"
            valid=true
            for oct in "${p[@]}"; do [[ "$oct" -gt 255 ]] && valid=false; done
            $valid && break
        fi
        error "Invalid IP: '${value}'. Expected format: 192.168.1.10"
    done
    echo "$value"
}

validate_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}

# =========================================================
#  START
# =========================================================
clear
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║      PostgreSQL HA Cluster — Configuration Wizard            ║"
echo "  ║      Patroni + Etcd + Keepalived                             ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  This wizard generates ${CYAN}inventory/hosts.ini${NC} and ${CYAN}group_vars/all.yml${NC}."
echo -e "  Once complete, run:"
echo -e "    ${BOLD}ansible-playbook -i inventory/hosts.ini site.yml${NC}"
echo ""

# =========================================================
#  [1] CLUSTER NODES
# =========================================================
header "1. CLUSTER NODES"

info "Configure the 3 nodes (hostnames and IPs)."
echo ""
NODE1_HOST=$(ask "Node 1 hostname" "pg-node-01")
NODE1_IP=$(ask_ip   "Node 1 IP       ")
NODE1_ETCD=$(ask "Node 1 Etcd name" "etcd-01")
echo ""
NODE2_HOST=$(ask "Node 2 hostname" "pg-node-02")
NODE2_IP=$(ask_ip   "Node 2 IP       ")
NODE2_ETCD=$(ask "Node 2 Etcd name" "etcd-02")
echo ""
NODE3_HOST=$(ask "Node 3 hostname" "pg-node-03")
NODE3_IP=$(ask_ip   "Node 3 IP       ")
NODE3_ETCD=$(ask "Node 3 Etcd name" "etcd-03")

# Replication subnet derived from node 1
CLUSTER_SUBNET="${NODE1_IP%.*}.0/24"
info "Cluster/replication subnet: ${CLUSTER_SUBNET}"

# =========================================================
#  [2] VIRTUAL IP (VIP)
# =========================================================
header "2. VIRTUAL IP — Keepalived"

PG_VIP=$(ask_ip "Cluster Virtual IP (VIP)")
VIP_PREFIX=$(ask "VIP CIDR prefix" "24")
PG_VIP_CIDR="${PG_VIP}/${VIP_PREFIX}"
ok "VIP: ${PG_VIP_CIDR}"

# =========================================================
#  [3] SSH ACCESS
# =========================================================
header "3. SSH ACCESS TO NODES"

info "Enter the SSH credentials used to access the cluster nodes."
info "A keypair will be generated and distributed automatically."
echo ""
ANSIBLE_USER=$(ask "SSH user" "ubuntu")
read -rsp "  SSH password (for initial key distribution): " SSH_PASS; echo >&2

# Generate SSH keypair if it doesn't exist
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    info "Generating SSH keypair at ${SSH_KEY_PATH} ..."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" >/dev/null 2>&1
    ok "SSH keypair generated: ${SSH_KEY_PATH}"
else
    ok "SSH keypair already exists: ${SSH_KEY_PATH}"
fi
ANSIBLE_SSH_KEY="$SSH_KEY_PATH"

# Distribute key and configure NOPASSWD sudoers on each node
NODES_INFO=(
    "${NODE1_HOST}:${NODE1_IP}"
    "${NODE2_HOST}:${NODE2_IP}"
    "${NODE3_HOST}:${NODE3_IP}"
)

if ! command -v sshpass &>/dev/null; then
    warn "sshpass is not installed — skipping automatic key distribution."
    warn "Install it with: apt install sshpass"
    warn "Then manually run: ssh-copy-id -i ${SSH_KEY_PATH}.pub ${ANSIBLE_USER}@<node-ip>"
else
    info "Scanning host keys and distributing SSH key to all nodes..."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/known_hosts" && chmod 600 "$HOME/.ssh/known_hosts"

    for node_info in "${NODES_INFO[@]}"; do
        node_host="${node_info%%:*}"
        node_ip="${node_info##*:}"
        info "  → ${node_host} (${node_ip})"

        # Register host key in known_hosts so Ansible doesn't ask later
        ssh-keyscan -H "$node_ip" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
            && ok "    Host key registered for ${node_host}" \
            || warn "    Could not scan host key for ${node_host} — check network connectivity."

        # Copy SSH public key (uses known_hosts populated above)
        if sshpass -p "$SSH_PASS" ssh-copy-id \
            -i "${SSH_KEY_PATH}.pub" \
            -o StrictHostKeyChecking=yes \
            "${ANSIBLE_USER}@${node_ip}" >/dev/null 2>&1; then
            ok "    SSH key distributed to ${node_host}"
        else
            warn "    Failed to copy SSH key to ${node_host} — check IP and password."
        fi

        # Add temporary NOPASSWD sudoers entry (removed at end of playbook)
        SUDOERS_FILE="/etc/sudoers.d/${ANSIBLE_USER}_ansible"
        SUDOERS_CMD="echo '${ANSIBLE_USER} ALL=(ALL) NOPASSWD:ALL' > ${SUDOERS_FILE} && chmod 440 ${SUDOERS_FILE}"
        if sshpass -p "$SSH_PASS" ssh \
            -o StrictHostKeyChecking=yes \
            "${ANSIBLE_USER}@${node_ip}" \
            "echo '${SSH_PASS}' | sudo -S bash -c \"${SUDOERS_CMD}\"" >/dev/null 2>&1; then
            ok "    NOPASSWD sudoers configured on ${node_host}"
        else
            warn "    Failed to configure sudoers on ${node_host} — may need manual setup."
        fi
    done
    info "Note: NOPASSWD sudoers entries will be removed at the end of the playbook."
fi

# =========================================================
#  [4] POSTGRESQL
# =========================================================
header "4. POSTGRESQL"

PG_DEFAULT="17"
read -rp "  PostgreSQL version [Enter = ${PG_DEFAULT} (latest)]: " PG_VERSION
PG_VERSION="${PG_VERSION:-$PG_DEFAULT}"
if ! [[ "$PG_VERSION" =~ ^[0-9]+$ ]]; then
    warn "Invalid version, using ${PG_DEFAULT}"
    PG_VERSION="$PG_DEFAULT"
fi
ok "PostgreSQL ${PG_VERSION} selected."

CLUSTER_NAME=$(ask "Cluster name" "pg-cluster-01")
CLUSTER_SCOPE=$(ask "Patroni scope" "postgres-prod")

# =========================================================
#  [5] CLUSTER PASSWORDS
# =========================================================
header "5. CLUSTER PASSWORDS"

info "Press Enter on any password to auto-generate a secure one."
echo ""
PG_SUPERUSER_PASS=$(ask_password "Superuser password (postgres)")
PG_REPLICATOR_PASS=$(ask_password "Replicator password          ")
PG_ADMIN_PASS=$(ask_password      "Admin password               ")
KEEPALIVED_PASS=$(ask_password    "VRRP password (keepalived)   ")
# Keepalived auth password: max 8 characters
KEEPALIVED_PASS="${KEEPALIVED_PASS:0:8}"

# =========================================================
#  [6] POSTGRES USER SSH KEY
# =========================================================
header "6. POSTGRES USER SSH KEY (optional)"

info "Used for internal node communication (pg_rewind, backups, etc.)."
info "Leave blank to skip."
echo ""
POSTGRES_SSH_KEY=$(ask_optional "Postgres user public SSH key (Enter=skip)")

# =========================================================
#  [7] LVM — ADDITIONAL DISK
# =========================================================
header "7. LVM — ADDITIONAL DISK PER NODE"

info "1 additional virtual disk per node → 1 VG: vg_postgres"
info "Internal LVs: lv_engine (PG data), lv_logs (WAL), lv_<dbname> (tablespace)"
info "The VG is created using the full disk. Keep some free space for best practices."
echo ""
LV_ENGINE_GB=$(ask "LV engine size  /var/lib/postgresql (GB)" "20")
LV_LOGS_GB=$(ask   "LV logs size    /pgwal               (GB)" "10")

# =========================================================
#  [8] DATABASES
# =========================================================
header "8. DATABASES"

info "Enter database names separated by commas."
info "Example: crm,erp,portal,datawarehouse"
echo ""

while true; do
    read -rp "  Database names: " DB_LIST_RAW
    [[ -n "$DB_LIST_RAW" ]] && break
    error "At least one database name is required."
done

# Parse and normalize names
IFS=',' read -ra DB_NAMES_RAW <<< "$DB_LIST_RAW"
DB_NAMES=()
for db in "${DB_NAMES_RAW[@]}"; do
    clean=$(echo "$db" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
    [[ -n "$clean" ]] && DB_NAMES+=("$clean")
done

if [[ ${#DB_NAMES[@]} -eq 0 ]]; then
    error "No valid database names provided."
    exit 1
fi

echo ""
declare -A DB_LV_SIZES
declare -A DB_PASS_ADM
declare -A DB_PASS_RW
declare -A DB_PASS_RO

TOTAL_DB_GB=0
for db in "${DB_NAMES[@]}"; do
    sep
    echo -e "  ${BOLD}${CYAN}Database: ${db}${NC}"
    sep
    DB_LV_SIZES[$db]=$(ask "  LV size for /pgdata/${db} (GB)" "10")
    TOTAL_DB_GB=$((TOTAL_DB_GB + DB_LV_SIZES[$db]))
    echo ""
    DB_PASS_ADM[$db]=$(ask_password "  Password for ${db}_adm (admin)    ")
    DB_PASS_RW[$db]=$(ask_password  "  Password for ${db}_rw  (readwrite)")
    DB_PASS_RO[$db]=$(ask_password  "  Password for ${db}_ro  (readonly) ")
    echo ""
done

TOTAL_LVM_GB=$((LV_ENGINE_GB + LV_LOGS_GB + TOTAL_DB_GB))

# =========================================================
#  [9] FRONTEND ACCESS NETWORKS
# =========================================================
header "9. FRONTEND ACCESS NETWORKS"

info "Networks allowed to connect to PostgreSQL (pg_hba + UFW)."
info "CIDR format, comma-separated."
info "Example: 10.110.41.0/24,10.110.11.0/24,192.168.1.0/24"
echo ""

CLIENT_NETS=()
while true; do
    read -rp "  Networks: " NETS_RAW
    [[ -n "$NETS_RAW" ]] && break
    error "At least one network is required."
done

IFS=',' read -ra NETS_ARRAY <<< "$NETS_RAW"
for net in "${NETS_ARRAY[@]}"; do
    net=$(echo "$net" | tr -d '[:space:]')
    if validate_cidr "$net"; then
        CLIENT_NETS+=("$net")
    else
        warn "Invalid CIDR skipped: '${net}'"
    fi
done

if [[ ${#CLIENT_NETS[@]} -eq 0 ]]; then
    error "No valid CIDR networks provided."
    exit 1
fi

# =========================================================
#  GENERATE FILES
# =========================================================
header "GENERATING FILES"

mkdir -p "${SCRIPT_DIR}/inventory" "${SCRIPT_DIR}/group_vars"

# --- inventory/hosts.ini ---
{
    echo "[pg_cluster]"
    echo "${NODE1_HOST} ansible_host=${NODE1_IP} pg_node_name=node1 etcd_name=${NODE1_ETCD}"
    echo "${NODE2_HOST} ansible_host=${NODE2_IP} pg_node_name=node2 etcd_name=${NODE2_ETCD}"
    echo "${NODE3_HOST} ansible_host=${NODE3_IP} pg_node_name=node3 etcd_name=${NODE3_ETCD}"
    echo ""
    echo "[pg_primary]"
    echo "${NODE1_HOST}"
    echo ""
    echo "[pg_replicas]"
    echo "${NODE2_HOST}"
    echo "${NODE3_HOST}"
    echo ""
    echo "[pg_cluster:vars]"
    echo "ansible_user=${ANSIBLE_USER}"
    echo "ansible_become=true"
    echo "ansible_ssh_private_key_file=${ANSIBLE_SSH_KEY}"
} > "${INVENTORY_FILE}"

ok "inventory/hosts.ini created."

# --- group_vars/all.yml ---
{
    cat << HEADER
---
# =============================================================================
# group_vars/all.yml — Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# WARNING: contains passwords in plain text.
#          Protect with: ansible-vault encrypt group_vars/all.yml
# =============================================================================

# --- Cluster Identity ---
cluster_name: "${CLUSTER_NAME}"
cluster_scope: "${CLUSTER_SCOPE}"
pg_version: "${PG_VERSION}"
pg_vip: "${PG_VIP}"
pg_vip_cidr: "${PG_VIP_CIDR}"
patroni_port: 8008
pg_port: 5432
etcd_client_port: 2379
etcd_peer_port: 2380

# --- Passwords ---
pg_superuser_password: "${PG_SUPERUSER_PASS}"
pg_replicator_password: "${PG_REPLICATOR_PASS}"
pg_admin_password: "${PG_ADMIN_PASS}"
keepalived_auth_pass: "${KEEPALIVED_PASS}"

# --- SSH public key for postgres user (optional) ---
postgres_ssh_public_key: "${POSTGRES_SSH_KEY}"

# --- LVM: 1 additional disk per node → single VG ---
vg_name: "vg_postgres"
lv_engine_size_gb: ${LV_ENGINE_GB}
lv_logs_size_gb: ${LV_LOGS_GB}

# --- Frontend access networks (CIDR) — pg_hba + UFW ---
client_networks:
HEADER

    for net in "${CLIENT_NETS[@]}"; do
        echo "  - \"${net}\""
    done

    cat << REPL_SUBNET

# --- Cluster/replication subnet (internal) ---
cluster_subnet: "${CLUSTER_SUBNET}"

# --- Databases ---
databases:
REPL_SUBNET

    for db in "${DB_NAMES[@]}"; do
        cat << DBENTRY
  - name: ${db}
    lv_size_gb: ${DB_LV_SIZES[$db]}
    users:
      - { name: ${db}_adm, role: admin }
      - { name: ${db}_rw,  role: readwrite }
      - { name: ${db}_ro,  role: readonly }
    passwords:
      ${db}_adm: "${DB_PASS_ADM[$db]}"
      ${db}_rw:  "${DB_PASS_RW[$db]}"
      ${db}_ro:  "${DB_PASS_RO[$db]}"

DBENTRY
    done

    cat << FOOTER
# --- PostgreSQL paths (derived from version) ---
pg_data_dir: "/var/lib/postgresql/{{ pg_version }}/main"
pg_wal_dir: "/pgwal"
pg_bin_dir: "/usr/lib/postgresql/{{ pg_version }}/bin"
pg_tablespace_base: "/pgdata"

# --- Keepalived ---
vrrp_interface: "{{ ansible_default_ipv4.interface }}"
virtual_router_id: 51
keepalived_priority_base: 100
keepalived_weight: 50
FOOTER

} > "${VARS_FILE}"

ok "group_vars/all.yml created."

# =========================================================
#  FINAL SUMMARY
# =========================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║                    SETUP COMPLETE!                           ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Nodes:${NC}"
echo -e "    ${NODE1_HOST}  →  ${NODE1_IP}  (primary)"
echo -e "    ${NODE2_HOST}  →  ${NODE2_IP}  (replica)"
echo -e "    ${NODE3_HOST}  →  ${NODE3_IP}  (replica)"
echo -e "    VIP: ${PG_VIP_CIDR}"
echo ""
echo -e "  ${BOLD}PostgreSQL:${NC} ${PG_VERSION}   ${BOLD}Cluster:${NC} ${CLUSTER_NAME}"
echo ""
echo -e "  ${BOLD}LVM per node (1 disk, VG: vg_postgres):${NC}"
echo -e "    lv_engine   ${LV_ENGINE_GB}GB   → /var/lib/postgresql"
echo -e "    lv_logs     ${LV_LOGS_GB}GB   → /pgwal"
for db in "${DB_NAMES[@]}"; do
    printf "    %-12s %sGB   → /pgdata/%s\n" "lv_${db}" "${DB_LV_SIZES[$db]}" "${db}"
done
echo -e "    ${BOLD}Estimated total per node: ${TOTAL_LVM_GB}GB${NC}"
echo ""
echo -e "  ${BOLD}Databases:${NC}"
for db in "${DB_NAMES[@]}"; do
    echo -e "    ${db}  →  ${db}_adm / ${db}_rw / ${db}_ro"
done
echo ""
echo -e "  ${BOLD}Allowed networks (pg_hba + UFW):${NC}"
for net in "${CLIENT_NETS[@]}"; do
    echo -e "    ${net}"
done
echo ""
echo -e "  ${BOLD}${CYAN}Next steps:${NC}"
echo -e "  1. Test SSH connectivity:"
echo -e "     ${CYAN}ansible -i inventory/hosts.ini all -m ping${NC}"
echo ""
echo -e "  2. Run preflight checks (OS, RAM, CPU, disk detection):"
echo -e "     ${CYAN}ansible-playbook -i inventory/hosts.ini site.yml --tags preflight${NC}"
echo ""
echo -e "  3. Ensure each node has 1 additional virtual disk (≥${TOTAL_LVM_GB}GB)."
echo ""
echo -e "  4. Full deployment:"
echo -e "     ${CYAN}ansible-playbook -i inventory/hosts.ini site.yml${NC}"
echo ""
echo -e "  ${YELLOW}  WARNING: group_vars/all.yml contains passwords in plain text.${NC}"
echo -e "  ${YELLOW}  Secure it with: ${BOLD}ansible-vault encrypt group_vars/all.yml${NC}"
echo ""

# =========================================================
#  GENERATE key.recap.txt
# =========================================================
RECAP_FILE="${SCRIPT_DIR}/key.recap.txt"
{
    echo "============================================================="
    echo "  PostgreSQL HA Cluster — Credentials & Access Summary"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================="
    echo ""
    echo "CLUSTER NODES"
    echo "  ${NODE1_HOST}  →  ${NODE1_IP}  (primary)"
    echo "  ${NODE2_HOST}  →  ${NODE2_IP}  (replica)"
    echo "  ${NODE3_HOST}  →  ${NODE3_IP}  (replica)"
    echo "  Virtual IP (VIP): ${PG_VIP_CIDR}"
    echo ""
    echo "SSH ACCESS"
    echo "  User     : ${ANSIBLE_USER}"
    echo "  Key path : ${ANSIBLE_SSH_KEY}"
    echo "  Pub key  : ${ANSIBLE_SSH_KEY}.pub"
    echo ""
    echo "POSTGRESQL CLUSTER"
    echo "  Version      : ${PG_VERSION}"
    echo "  Cluster name : ${CLUSTER_NAME}"
    echo "  Patroni scope: ${CLUSTER_SCOPE}"
    echo ""
    echo "CLUSTER CREDENTIALS"
    echo "  Superuser  (postgres)   : ${PG_SUPERUSER_PASS}"
    echo "  Replicator (replicator) : ${PG_REPLICATOR_PASS}"
    echo "  Admin      (admin)      : ${PG_ADMIN_PASS}"
    echo "  VRRP auth  (keepalived) : ${KEEPALIVED_PASS}"
    echo ""
    echo "DATABASE CREDENTIALS"
    for db in "${DB_NAMES[@]}"; do
        echo "  --- ${db} ---"
        echo "    ${db}_adm (admin)     : ${DB_PASS_ADM[$db]}"
        echo "    ${db}_rw  (readwrite) : ${DB_PASS_RW[$db]}"
        echo "    ${db}_ro  (readonly)  : ${DB_PASS_RO[$db]}"
    done
    echo ""
    echo "============================================================="
    echo "  WARNING: This file contains sensitive credentials."
    echo "  Delete or encrypt it after noting the passwords:"
    echo "    rm ${RECAP_FILE}"
    echo "  Or encrypt with GPG:"
    echo "    gpg -c ${RECAP_FILE}"
    echo "============================================================="
} > "$RECAP_FILE"
chmod 600 "$RECAP_FILE"
ok "Credentials summary written to: key.recap.txt"
echo -e "  ${YELLOW}  WARNING: key.recap.txt contains all passwords — delete it after use.${NC}"
echo ""
