# PostgreSQL HA Cluster — Ansible Automation

Automated deployment of a 3-node PostgreSQL High Availability cluster using **Patroni + Etcd + Keepalived** on Ubuntu 22.04/24.04.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Client Applications                        │
│                         (via VIP / port 5432)                     │
└────────────────────────────┬─────────────────────────────────────┘
                             │  Virtual IP (Keepalived VRRP)
                             ▼
        ┌────────────────────────────────────┐
        │              pg-node-01            │  ← Primary (leader)
        │   PostgreSQL + Patroni + Etcd      │  ← holds VIP
        └────────────┬───────────┬───────────┘
                     │           │  replication (streaming)
          ┌──────────┘           └──────────┐
          ▼                                 ▼
┌──────────────────┐             ┌──────────────────┐
│   pg-node-02     │             │   pg-node-03     │
│  Replica + Etcd  │             │  Replica + Etcd  │
└──────────────────┘             └──────────────────┘
           │                              │
           └──────────┬───────────────────┘
                      │  Etcd DCS (cluster state)
                      ▼
              Leader election + auto-failover (Patroni)
```

**Stack:**
- PostgreSQL (configurable version, default 17)
- Patroni — HA manager with automatic failover
- Etcd — distributed configuration store (DCS)
- Keepalived — Virtual IP (VRRP) floating between nodes

---

## Hardware Requirements

### Per Node — Disk Layout

Each node requires **2 disks**:

| Disk | Purpose | Minimum | Recommended |
|------|---------|---------|-------------|
| `/dev/sda` | OS (Ubuntu) — do not touch | 20 GB | 40 GB |
| `/dev/sdb` | All PostgreSQL data (VG `vg_postgres`) | **50 GB** | **100 GB** |

> **The automation detects `/dev/sdb` automatically.**
> If the disk was just attached to the VM and the OS has not scanned it yet,
> the playbook triggers a SCSI bus rescan (`/sys/class/scsi_host/host*/scan`)
> before attempting to create the VG.

### LVM Layout Inside `/dev/sdb` (single VG)

```
/dev/sdb  (100 GB example)
└── VG: vg_postgres  (100 GB — full disk, ~5% reserved by LVM)
    ├── lv_engine   (20 GB) → /var/lib/postgresql   (PG engine / data dir)
    ├── lv_logs     (10 GB) → /pgwal                (WAL / write-ahead logs)
    └── lv_<dbname> (5–50 GB each) → /pgdata/<dbname>  (tablespace per DB)
```

> **Free space in the VG is intentional (best practice).**
> Keep at least 15–20% of the VG unallocated to allow for:
> - Emergency `lvextend` without downtime
> - LVM snapshot for backups
> - Unexpected write bursts

### Minimum Sizing Guide (50 GB disk)

```
lv_engine   20 GB   → /var/lib/postgresql
lv_logs     10 GB   → /pgwal
lv_<db1>     5 GB   → /pgdata/<db1>
lv_<db2>     5 GB   → /pgdata/<db2>
─────────────────
Used:       40 GB
Free in VG: 10 GB   (20% — meets best-practice minimum)
```

### Recommended Sizing (100 GB disk)

```
lv_engine   20 GB   → /var/lib/postgresql
lv_logs     15 GB   → /pgwal
lv_<db1>    15 GB   → /pgdata/<db1>
lv_<db2>    15 GB   → /pgdata/<db2>
lv_<db3>    10 GB   → /pgdata/<db3>
─────────────────
Used:       75 GB
Free in VG: 25 GB   (25% — comfortable buffer)
```

### Other Requirements

| Resource | Minimum              | Recommended  |
|----------|----------------------|--------------|
| RAM      | 4 GB                 | 8 GB+        |
| vCPU     | 2                    | 4+           |
| OS       | Ubuntu 22.04         | Ubuntu 24.04 |
| Network  | 1 Gbps between nodes | 10 Gbps      |

---

## Prerequisites on the Control Node

The control node is the machine where you run Ansible (not the cluster nodes themselves).

```bash
# Install Ansible
pip3 install ansible --break-system-packages

# Install required Ansible collections
ansible-galaxy collection install community.general community.postgresql ansible.posix

# Install sshpass
sudo apt install sshpass
```

---

## Step-by-Step Deployment

### Step 1 — Run the configuration wizard

```bash
bash setup.sh
```

The wizard will interactively ask for:

| Prompt | Example |
|--------|---------|
| Hostname / IP of each node | `pg-node-01` / `10.10.1.11` |
| Virtual IP (VIP) | `10.10.1.10` |
| SSH user | `ubuntu` |
| PostgreSQL version | `17` (Enter = use default) |
| Cluster name | `pg-prod-01` |
| Passwords (Enter = auto-generate) | superuser, replicator, admin, keepalived |
| SSH public key for `postgres` user | optional, press Enter to skip |
| LV sizes in GB: engine, logs | `20`, `10` |
| Database names (comma-separated) | `crm,erp,portal` |
| LV size per database in GB | `15`, `10`, `5` |
| Frontend networks (CIDR, comma-separated) | `10.10.2.0/24,10.10.3.0/24` |

**Output:** three generated files:
- `inventory/hosts.ini` — cluster node inventory
- `group_vars/all.yml` — all variables, passwords, DB definitions
- `key.recap.txt` — credential summary (passwords + access info, `chmod 600`)

> `key.recap.txt` is a plain-text backup of all generated passwords.
> Keep it in a safe place and delete it from disk once stored securely
> (password manager, vault, etc.). It is excluded from git.

> After the wizard completes, verify the generated files before proceeding.

---

### Step 2 — Test SSH connectivity

```bash
ansible -i inventory/hosts.ini all -m ping
```

Expected output: all 3 nodes reply with `pong`.

---

### Step 3 — Preflight check

Validates OS version, RAM, CPU, and detects available disks.
The SCSI bus is rescanned automatically at this step.

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags preflight
```

Check the output for the **DISK RECOMMENDATION** section — it shows the exact LVM layout that will be created and the minimum disk size required.

> If the disk check fails (no free disk found), power off the VM, attach the
> additional disk via your hypervisor, power on, and re-run preflight.
> The playbook will trigger the SCSI rescan automatically.

---

### Step 4 — Full deployment

Once preflight passes and the additional disk is present on all nodes:

```bash
ansible-playbook -i inventory/hosts.ini site.yml
```

This runs all stages in sequence:

| Tag | What it does |
|-----|-------------|
| `preflight` | OS/hardware validation + SCSI rescan |
| `lvm` | Create `vg_postgres` + all LVs + mount |
| `install` | Install PostgreSQL, Patroni, Etcd, Keepalived |
| `configure` | Deploy Patroni, Etcd, Keepalived, UFW configs |
| `services` | Enable and start all services |
| `databases` | Create tablespaces, databases, users, grants |
| `validate` | Health check — cluster status + VIP check |

You can also run individual stages:

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags lvm
ansible-playbook -i inventory/hosts.ini site.yml --tags install
ansible-playbook -i inventory/hosts.ini site.yml --tags configure
ansible-playbook -i inventory/hosts.ini site.yml --tags databases
ansible-playbook -i inventory/hosts.ini site.yml --tags validate
```

---

### Step 5 — Verify the cluster

Run from any cluster node (or from the primary):

```bash
# Check cluster topology (leader + replicas)
patronictl -c /etc/patroni/patroni.yml list

# Check which node holds the VIP
ip addr show | grep <vip-address>

# Check service status
systemctl status patroni etcd keepalived
```

Expected healthy output from `patronictl list`:

```
+ Cluster: postgres-prod ----+----+-----------+
| Member     | Host         | Role    | State   | TL | Lag in MB |
+------------+--------------+---------+---------+----+-----------+
| node1      | 10.10.1.11   | Leader  | running |  1 |           |
| node2      | 10.10.1.12   | Replica | running |  1 |         0 |
| node3      | 10.10.1.13   | Replica | running |  1 |         0 |
+------------+--------------+---------+---------+----+-----------+
```

---

## Connecting to the Cluster

Always connect through the **VIP** to be routed to the current primary automatically:

```
Host:     <vip-address>
Port:     5432
User:     <dbname>_adm  (admin), <dbname>_rw (readwrite), <dbname>_ro (readonly)
Database: <dbname>
```

Example with psql:

```bash
psql -h <vip> -U crm_adm -d crm
```

---

## Security

### Encrypt secrets with ansible-vault

```bash
# Encrypt (recommended for production)
ansible-vault encrypt group_vars/all.yml

# Run playbook with vault
ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass
# or
ansible-playbook -i inventory/hosts.ini site.yml --vault-password-file ~/.vault_pass
```

### Access control

Client network access is controlled at two levels:

1. **UFW firewall** — port 5432 allowed only from declared CIDRs
2. **pg_hba.conf** — per-database, per-user, per-network rules generated from `client_networks`

The cluster internal subnet (replication, Patroni API, Etcd) is always isolated.

---

## Day-2 Operations

### Extending a database LV (online, no downtime)

```bash
# 1. Check current VG free space
vgs vg_postgres

# 2. Extend the logical volume
lvextend -L +20G /dev/vg_postgres/lv_<dbname>

# 3. Resize the filesystem (online)
resize2fs /dev/vg_postgres/lv_<dbname>

# 4. Verify
df -h /pgdata/<dbname>
```

### Adding a second disk to extend the VG

```bash
# 1. Attach new disk via hypervisor, then rescan SCSI on the node
for host in /sys/class/scsi_host/host*; do echo "- - -" > "$host/scan"; done

# 2. Confirm new disk is visible
lsblk

# 3. Add to VG
pvcreate /dev/sdc
vgextend vg_postgres /dev/sdc

# 4. Now extend any LV as shown above
```

### Manual failover (planned maintenance)

```bash
# Switchover to another node (graceful)
patronictl -c /etc/patroni/patroni.yml switchover --master node1 --candidate node2

# Or let Patroni choose the best replica
patronictl -c /etc/patroni/patroni.yml switchover --master node1
```

### Reinitializing a replica after data divergence

```bash
patronictl -c /etc/patroni/patroni.yml reinit <cluster-scope> <node-name>
```

---

## Project Structure

```
pg-cluster-ansible/
├── setup.sh                          # Interactive configuration wizard
├── site.yml                          # Main deployment playbook
├── check.yml                         # Cluster health check (+ optional repair)
├── recover.yml                       # Full cluster reset and rebuild
├── ansible.cfg                       # Ansible defaults (SSH tuning, callbacks)
├── key.recap.txt                     # Generated by setup.sh — all passwords (git-ignored)
├── inventory/
│   └── hosts.ini                     # Generated by setup.sh (git-ignored)
├── group_vars/
│   └── all.yml                       # Generated by setup.sh (git-ignored)
└── roles/
    ├── preflight/                    # OS/hardware validation + SCSI rescan
    ├── lvm_setup/                    # Create vg_postgres + all LVs
    ├── install_pg_stack/             # Install PG, Patroni, Etcd, Keepalived
    ├── configure_cluster/            # Deploy configs + UFW rules
    │   └── templates/
    │       ├── patroni.yml.j2
    │       ├── patroni.service.j2
    │       ├── etcd.j2
    │       ├── keepalived.conf.j2
    │       └── check_patroni_leader.sh.j2
    ├── databases/                    # Create tablespaces, DBs, users, grants
    └── validate/                     # Post-deploy health checks
```

---

## Health Check Playbook (`check.yml`)

Run from the control node at any time to get a full picture of cluster health.

```bash
# Read-only check — reports service state, LVM mounts, topology, databases
ansible-playbook -i inventory/hosts.ini check.yml

# Check and auto-repair (restart failed services, remount missing volumes, fix ownership)
ansible-playbook -i inventory/hosts.ini check.yml -e repair=true
```

The playbook reports:

| Check | What it verifies |
|-------|-----------------|
| Services | `etcd`, `patroni`, `keepalived` — active / inactive |
| LVM | `vg_postgres` exists, `/var/lib/postgresql` and `/pgwal` mounted |
| Ownership | `postgres` user owns all data directories |
| Topology | 1 leader + 2 replicas, replication lag per node |
| VIP | Virtual IP is held by the current primary |
| Databases | All expected databases and users are present |

When run with `-e repair=true`, it automatically:
- Restarts any service that is not `active`
- Remounts missing LVM volumes
- Fixes directory ownership
- Recreates missing databases (if any)

---

## Recovery Playbook (`recover.yml`)

> **WARNING — DATA LOSS RISK**
>
> `recover.yml` **destroys all PostgreSQL data** on every cluster node.
> It wipes the PostgreSQL data directory, Etcd state, and all tablespaces,
> then rebuilds the cluster from scratch.
>
> **Never run this on a production cluster with live data unless you have a
> verified backup and have exhausted all other recovery options.**
> Always try `check.yml -e repair=true` and the manual repair steps in the
> Troubleshooting section first.

Use `recover.yml` only when the cluster is in an unrecoverable state:
- Partial or aborted first-time deployment
- Etcd / PostgreSQL system ID mismatch after VM cloning
- Stale cluster state that cannot be cleared incrementally

### Phases

| Phase | Tag | What it does |
|-------|-----|-------------|
| 1 — Stop & wipe | `reset` | Stops all services, clears Etcd and PostgreSQL data |
| 2 — Reconfigure | `rebuild` | Redeploys Patroni, Etcd, Keepalived and UFW configs |
| 3 — Start | `rebuild` | Starts services, waits for leader election |
| 4 — Databases | `databases` | Ensures pg_primary is leader, recreates databases and users |

### Usage

```bash
# Full reset and rebuild (equivalent to a fresh deployment)
ansible-playbook -i inventory/hosts.ini recover.yml

# Only stop services and wipe state (Phase 1)
ansible-playbook -i inventory/hosts.ini recover.yml --tags reset

# Only restart services and reconfigure (Phases 2 + 3)
ansible-playbook -i inventory/hosts.ini recover.yml --tags rebuild

# Only recreate databases and users (Phase 4)
ansible-playbook -i inventory/hosts.ini recover.yml --tags databases
```

> After recovery, the cluster starts fresh with the databases and users
> defined in `group_vars/all.yml`. Any data that existed before the recovery
> will be permanently lost.

---

## Troubleshooting

### Disk not found during preflight

The disk may not have been scanned by the OS after being attached to the VM.
The playbook performs an automatic SCSI rescan, but if the issue persists:

```bash
# Manual rescan on the affected node
for host in /sys/class/scsi_host/host*; do echo "- - -" > "$host/scan"; done
lsblk   # confirm the disk appears (e.g. /dev/sdb)
```

### Patroni fails to start

```bash
# Check Patroni logs
journalctl -u patroni -f

# Common causes:
# - pg_data_dir not empty and not initialized by Patroni
# - Etcd not running (check: systemctl status etcd)
# - Wrong password in patroni.yml
```

### VIP not assigned to any node

```bash
# Check Keepalived logs
journalctl -u keepalived -f

# Verify the health check script works
bash /etc/keepalived/check_patroni_leader.sh
echo $?  # should be 0 on primary, 1 on replicas
```

### Etcd cluster not healthy

```bash
# Check etcd member list
etcdctl --endpoints=http://localhost:2379 member list

# Check etcd logs
journalctl -u etcd -f
```
