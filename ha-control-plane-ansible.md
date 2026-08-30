# HA Control Plane via Ansible — Definitive Config + Runbook

Every section carries a **Read first** block pointing at upstream documentation, so
nothing here has to be taken on faith. Where this document departs from what a vendor
recommends, it says so and explains why.

## Cluster after this change

| Node | Hardware | IP | Role | Notes |
|---|---|---|---|---|
| `deus` | Lenovo M910q, i7-6700T, 16 GB | `192.168.1.250` | server (etcd) | cluster-init node |
| `opus` | HP EliteDesk 800 G4 Mini, i5-8500, 16 GB | `192.168.1.252` | server (etcd) | 2 × 256 GB cached NVMe. **BIOS password-locked** — §1 |
| `sol` | i5-10210U, 16 GB | `192.168.1.251` | server (etcd) | 500 GB cached NVMe + 1 TB DRAM-less SATA |
| `nebula` | i7-6700K, 24 GB, GTX 1080 | `192.168.1.248` | agent | ZFS `tank`, Docker Compose stack |
| `legion` | laptop | `192.168.1.249` | agent | Longhorn |
| — | kube-vip VIP | **`192.168.1.247`** | — | API endpoint, static zone (DHCP pool ends at `.240`) |

All addresses static, set in the installer, enforced by the `netplan` role.

---

## 0. Why this is a project and not a `curl | sh`

> **Read first**
> - K3s HA with embedded etcd — https://docs.k3s.io/datastore/ha-embedded
> - `k3s server` flags, incl. which must match on every server — https://docs.k3s.io/cli/server

Adding an *agent* is trivial. Adding the second and third *server* to a cluster built
as a single server is not, for three one-time reasons:

**1. `deus` is on SQLite.** The K3s docs are explicit that an existing cluster on the
default embedded SQLite database is converted to etcd by restarting the server with
`--cluster-init`, after which additional servers can be added. The conversion is
**one-way**. This is the only step that can lose the cluster.

**2. Going 1 → 3 members means passing through 2.** Quorum in a two-member etcd cluster
is two — losing *either* wedges it. Strictly worse than where you are now, so the
window must be short.

**3. The API endpoint has to stop being `deus`.** The docs list "a fixed registration
address for agent nodes" as an optional component of an HA cluster; for you it isn't
optional, because agents and your kubeconfig currently point at `.250`.

Also from `docs.k3s.io/cli/server`: **some options must be identical on every server**,
or new servers fail to join when using embedded etcd. That's what makes the templated
`config.yaml` in §5 worth building rather than pasting flags per host.

### Layer boundary

**Ansible (below K3s):** partitions, netplan, sysctl, packages, Tailscale, the K3s
binary and version, `/etc/rancher/k3s/config.yaml`, static pods, systemd units.

**ArgoCD (inside K3s):** everything with an `apiVersion`.

kube-vip is the one genuinely contested case — see §5.6, where the recommendation
knowingly departs from kube-vip's own K3s page.

---

## 1. `opus` BIOS lock — resolve before anything else

HP's G4 BIOS password lives in NVRAM; the CMOS battery trick doesn't clear it and there
is no backdoor code. Plan around it.

**Sleep on AC** — controllable from Linux, handled by the `base` role.

**AC power recovery** — not controllable from the OS. Test rather than assume:

```bash
sudo poweroff
# full power-down, pull the plug at the wall, wait 10s, plug back in,
# do NOT touch the power button
```

- **Comes back by itself** → nothing changes; `opus` is your best etcd host.
- **Stays dark** → still make it a server. Three members where one needs a button press
  after a power cut still beats one member, because power loss isn't the common failure
  — panics, kured reboots, OOM and disk-full all self-recover. Compensate with a
  `KubeNodeNotReady` alert that stays loud.

---

## 2. Ubuntu install — what to set by hand

> **Read first**
> - Netplan configuration reference — https://netplan.readthedocs.io/en/stable/netplan-yaml/
> - Disabling cloud-init network config — https://cloudinit.readthedocs.io/en/latest/reference/datasources.html#disabling-network-configuration

Per node:

- **SSH server: checked**, public key imported. No key, no Ansible.
- **User `leifsen`** — must match `admin_user`.
- **Static IPv4** (`.251` = `sol`, `.252` = `opus`), since both are outside the DHCP pool.
- **Install to the cached NVMe only.** Decline LVM. On `opus`, leave `nvme1` untouched.
- Nothing else. No snaps, no Docker, no k3s.

Then, **before K3s ever starts**:

```bash
sudo hostnamectl set-hostname opus     # and: sol
```

`node-name` comes from the inventory key, and node names are fixed at registration —
renaming later means deleting the node object and re-joining, which on an etcd member is
genuinely unpleasant.

Passwordless sudo is optional; `--ask-become-pass` prompts once per run and reuses the
answer across hosts, so either keep the sudo password identical on both new nodes or
always use `--limit`.

---

## 3. Repo layout

> **Read first**
> - Ansible best practices / directory layout — https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html
> - Roles — https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html
> - Vault — https://docs.ansible.com/ansible/latest/vault_guide/index.html

Separate repo, so the Ansible/ArgoCD boundary is physical rather than conventional.

```
homelab-ansible/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml
│   ├── group_vars/{all.yml,all.vault.yml,k3s_servers.yml,k3s_agents.yml}
│   └── host_vars/{deus,opus,sol,nebula,legion}.yml
├── playbooks/
│   ├── site.yml                   # everything, safe to re-run
│   ├── provision-node.yml         # OS-level only, no k3s
│   ├── k3s-server-init.yml        # deus: sqlite -> etcd (one-shot, guarded)
│   ├── k3s-server-join.yml        # opus/sol, serial:1 with etcd health gate
│   ├── repoint-agents.yml         # nebula/legion -> VIP
│   └── node-updates.yml
└── roles/
    ├── base/          netplan/        multipath/
    ├── longhorn_disk/ node_updates/
    ├── nvim/          tailscale/      node_health/
    └── k3s_common/    k3s_server/     k3s_agent/
```

### `ansible.cfg`

```ini
[defaults]
inventory          = inventory/hosts.yml
roles_path         = roles
host_key_checking  = True
interpreter_python = /usr/bin/python3
stdout_callback    = yaml
callbacks_enabled  = profile_tasks
retry_files_enabled = False
vault_identity_list = homelab@~/.ansible/homelab-vault-pass

[ssh_connection]
pipelining = True
```

### `inventory/hosts.yml`

```yaml
all:
  children:
    k3s_cluster:
      children:
        k3s_servers:
          hosts:
            deus:   { ansible_host: 192.168.1.250 }
            opus:   { ansible_host: 192.168.1.252 }
            sol:    { ansible_host: 192.168.1.251 }
        k3s_agents:
          hosts:
            nebula: { ansible_host: 192.168.1.248 }
            legion: { ansible_host: 192.168.1.249 }
```

Order is load-bearing: `deus` first so `groups['k3s_servers'][0]` identifies the
cluster-init node; `opus` before `sol` matches the join order in §6.

---

## 4. Variables

### `group_vars/all.yml`

```yaml
admin_user: leifsen
timezone: Asia/Singapore
lan_cidr: 192.168.1.0/24

# Pin to whatever `k3s --version` prints on deus RIGHT NOW. See F3.
k3s_version: "v1.33.4+k3s1"        # <-- VERIFY ON DEUS BEFORE FIRST RUN

k3s_vip: 192.168.1.247             # static zone; DHCP pool ends at .240
kube_vip_version: "v0.8.9"
kube_vip_interface: "{{ ansible_default_ipv4.interface }}"

nvim_version: "v0.11.3"
```

### `group_vars/all.vault.yml` (ansible-vault encrypted)

```yaml
vault_k3s_token: "<value of /var/lib/rancher/k3s/server/token on deus>"
vault_tailscale_authkey: "tskey-auth-..."
vault_etcd_s3_access_key: "GK..."
vault_etcd_s3_secret_key: "..."
```

> `vault_k3s_token` is **copied from deus**, not generated (F2).

### `group_vars/k3s_servers.yml`

```yaml
k3s_role: server
k3s_bootstrap_complete: false      # flip to true after Phase 5

k3s_tls_sans:
  - "{{ k3s_vip }}"
  - "{{ ansible_host }}"
  - "{{ inventory_hostname }}"
  - "{{ inventory_hostname }}.lab.packetcraft.dev"

etcd_s3_endpoint: "nebula.lab.packetcraft.dev:3900"
etcd_s3_bucket: k3s-etcd
etcd_s3_region: garage
etcd_snapshot_cron: "0 */6 * * *"
etcd_snapshot_retention: 20

kubelet_reserved:
  system_reserved: "cpu=500m,memory=512Mi"
  kube_reserved: "cpu=500m,memory=512Mi"

tailscale_advertise_routes: "{{ lan_cidr }}"
tailscale_accept_routes: false     # see §5.3 — deliberate
```

### `host_vars/opus.yml`

```yaml
# Both NVMe cached. nvme1 is a dedicated etcd mount so etcd fsyncs don't queue
# behind container image writes on the OS disk.
etcd_data_device: /dev/nvme1n1p1     # verify with lsblk
longhorn_disk_device: null
longhorn_enabled: false              # deferred, §7
```

### `host_vars/sol.yml`

```yaml
# 500 GB cached NVMe -> OS + etcd.
# 1 TB SATA is DRAM-less: fine for Longhorn replicas, never for etcd.
etcd_data_device: /dev/nvme0n1p3     # verify with lsblk
longhorn_disk_device: /dev/sda
longhorn_enabled: false              # deferred, §7
```

### `host_vars/deus.yml`

```yaml
k3s_cluster_init: true      # ONLY on deus. Triggers the sqlite -> etcd migration.
etcd_data_device: null
```

---

## 5. Roles

### 5.1 `roles/base`

> **Read first**
> - kubelet swap behaviour — https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory
> - `ansible.posix.sysctl` — https://docs.ansible.com/ansible/latest/collections/ansible/posix/sysctl_module.html
> - sudoers drop-ins — `man 5 sudoers`, and https://docs.ansible.com/ansible/latest/collections/ansible/builtin/copy_module.html for `validate`

```yaml
- name: Install base packages
  ansible.builtin.apt:
    name:
      - python3
      - python3-apt          # without this, Ansible's apt module doesn't work at all
      - python3-pip
      - python3-venv
      - curl
      - wget
      - git
      - jq
      - unzip
      - ca-certificates
      - gnupg
      - openssh-server
      - chrony               # etcd is wall-clock sensitive; do not skip
      - htop
      - iotop
      - sysstat
      - tcpdump
      - iproute2
      - ethtool
      - dnsutils
      - iperf3
      - ripgrep
      - fd-find
      - build-essential      # LazyVim compiles treesitter parsers
      - bash-completion
      - vim
      - rsync
      - tmux
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Never sleep (covers opus, whose BIOS we can't reach)
  ansible.builtin.systemd:
    name: "{{ item }}"
    masked: true
  loop: [sleep.target, suspend.target, hibernate.target, hybrid-sleep.target]

- name: Disable swap
  ansible.builtin.command: swapoff -a
  when: ansible_swaptotal_mb > 0
  changed_when: true

- name: Remove swap from fstab
  ansible.posix.mount: { path: none, fstype: swap, state: absent }

- name: Kernel tunables
  ansible.posix.sysctl:
    name: "{{ item.k }}"
    value: "{{ item.v }}"
    sysctl_file: /etc/sysctl.d/99-k3s.conf
    reload: true
  loop:
    - { k: net.ipv4.ip_forward,                v: "1" }
    - { k: net.bridge.bridge-nf-call-iptables, v: "1" }
    - { k: fs.inotify.max_user_instances,      v: "1024" }
    - { k: fs.inotify.max_user_watches,        v: "524288" }

- name: Set timezone
  community.general.timezone: { name: "{{ timezone }}" }

- name: Passwordless sudo for the admin user
  ansible.builtin.copy:
    dest: "/etc/sudoers.d/90-{{ admin_user }}"
    content: "{{ admin_user }} ALL=(ALL) NOPASSWD:ALL\n"
    mode: "0440"
    validate: "visudo -cf %s"
  when: passwordless_sudo | default(false)
```

`fs.inotify.*` is the commonly skipped one — the default instance limit is what makes
pods fail with `too many open files` months later, looking like an application bug.

`validate: visudo -cf %s` is load-bearing: a malformed sudoers drop-in breaks sudo
entirely, and on `opus` you'd be recovering on a box whose BIOS you can't enter.

### 5.2 `roles/netplan`

**On the existing nodes, `50-cloud-init.yaml` is not a leftover — it is the only netplan
file, and it holds the hand-edited static addresses.** Deleting it before a working
replacement is in place takes the node off the network, and if that happens during
`netplan apply` over SSH you lose the session that would let you fix it.

Two consequences for the role:

**Filename must sort *after* `50-`.** Netplan reads files in lexicographic order and later
files override earlier ones for the same key, so `10-homelab.yaml` would *lose* to
`50-cloud-init.yaml` during any window where both exist. Use `90-homelab.yaml`.

**Write, verify, then remove — never remove first.** Because the addresses aren't
changing, a correct migration is a file reorganisation with no effect on the wire.
`netplan generate` renders to `/run/systemd/network/`, so you can diff the rendered output
before and after and refuse to apply if anything moved.

```yaml
- name: Stop cloud-init managing the network
  ansible.builtin.copy:
    dest: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: "network: {config: disabled}\n"
    mode: "0644"

- name: Keep a copy of the pre-existing config
  ansible.builtin.copy:
    src: /etc/netplan/50-cloud-init.yaml
    dest: /root/50-cloud-init.yaml.pre-ansible
    remote_src: true
    force: false                     # never overwrite the original snapshot
  ignore_errors: true                # absent on a freshly templated node

- name: Capture currently rendered network config
  ansible.builtin.shell: |
    netplan generate && cat /run/systemd/network/* 2>/dev/null | sort
  register: netplan_before
  changed_when: false

- name: Managed netplan config
  ansible.builtin.template:
    src: 90-homelab.yaml.j2
    dest: /etc/netplan/90-homelab.yaml
    mode: "0600"          # netplan warns loudly about world-readable configs

- name: Remove the cloud-init file now that ours exists
  ansible.builtin.file:
    path: /etc/netplan/50-cloud-init.yaml
    state: absent

- name: Re-render and compare
  ansible.builtin.shell: |
    netplan generate && cat /run/systemd/network/* 2>/dev/null | sort
  register: netplan_after
  changed_when: false

- name: Refuse to apply if the rendered config changed
  ansible.builtin.assert:
    that: netplan_after.stdout == netplan_before.stdout
    fail_msg: >-
      Rendered netplan output differs. The template does not reproduce the live
      config. Restore /root/50-cloud-init.yaml.pre-ansible and fix the template
      before applying.

- name: Apply
  ansible.builtin.command: netplan apply
  when: netplan_after.stdout != netplan_before.stdout
```

The assert makes the role fail *before* touching the running network whenever the template
and the live config disagree — which is the only case that can lock you out. On the two
new nodes there is nothing to lose, so run it there first and let it prove the template
reproduces a working config before it ever touches `deus`.

Order of hosts for this role: `sol`, `opus`, `legion`, `nebula`, `deus`.

### 5.3 `roles/tailscale` — **corrected**

> **Read first**
> - Subnet routers — https://tailscale.com/docs/features/subnet-routers
> - HA setup — https://tailscale.com/docs/how-to/set-up-high-availability
> - Overlapping-route failover behaviour — https://tailscale.com/docs/reference/troubleshooting/network-configuration/overlapping-subnet-route-failover

Two facts from those pages shape this role:

**Failover is automatic but not instant, and not configurable.** With regional routing
off (the default), all traffic for a route goes to one primary router, chosen by *the
date it was added to the tailnet, oldest first*. Others are passive standbys, and
failover takes about 15 seconds after the primary goes offline. Tailscale does not
support designating a preferred router. Practically: `deus` stays primary because it was
added first, and `opus`/`sol` are standbys — which is exactly what you want.

**`--accept-routes` must come off the subnet routers.** The docs warn that if HA subnet
routers sharing the same routes also accept routes, a standby will accept its own
advertised prefix from the primary and send traffic for its own directly-connected
subnet the long way round. Their guidance for most HA setups is `--advertise-routes`
alone. My earlier draft had both flags on all three servers — that was wrong.

```yaml
- name: Add Tailscale apt key
  ansible.builtin.get_url:
    url: https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
    dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
    mode: "0644"

- name: Add Tailscale repo
  ansible.builtin.apt_repository:
    repo: >-
      deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg]
      https://pkgs.tailscale.com/stable/ubuntu noble main
    filename: tailscale
    state: present

- name: Install tailscale
  ansible.builtin.apt: { name: tailscale, state: present, update_cache: true }

- name: Enable forwarding for subnet routing
  ansible.posix.sysctl:
    name: "{{ item }}"
    value: "1"
    sysctl_file: /etc/sysctl.d/99-tailscale.conf
    reload: true
  loop: [net.ipv4.ip_forward, net.ipv6.conf.all.forwarding]
  when: tailscale_advertise_routes is defined

- name: Check tailscale state
  ansible.builtin.command: tailscale status --json
  register: ts_status
  changed_when: false
  failed_when: false

- name: Bring tailscale up
  ansible.builtin.command: >-
    tailscale up
      --authkey={{ vault_tailscale_authkey }}
      --hostname={{ inventory_hostname }}
      --advertise-tags=tag:homelab
      {% if tailscale_advertise_routes is defined %}
      --advertise-routes={{ tailscale_advertise_routes }}
      {% endif %}
      {% if tailscale_accept_routes | default(true) %}
      --accept-routes
      {% endif %}
  when: >-
    ts_status.rc != 0 or
    (ts_status.stdout | from_json).BackendState != 'Running'
  no_log: true
```

`tailscale_accept_routes: false` in `k3s_servers.yml`; agents and workstations keep the
default `true`.

**Routes must be approved per node in the admin console.** Ansible reports success; the
route stays inert until approved. No playbook can assert this (F9).

### 5.4 `roles/nvim`

> **Read first**
> - LazyVim installation + requirements — https://www.lazyvim.org/installation
> - Neovim releases — https://github.com/neovim/neovim/releases

Ubuntu 24.04 ships Neovim 0.9.5; LazyVim wants newer. Pinned tarball, so every node runs
a byte-identical editor.

```yaml
- name: Create install dir
  ansible.builtin.file: { path: /opt/nvim, state: directory, mode: "0755" }

- name: Install Neovim {{ nvim_version }}
  ansible.builtin.unarchive:
    src: "https://github.com/neovim/neovim/releases/download/{{ nvim_version }}/nvim-linux-x86_64.tar.gz"
    dest: /opt/nvim
    remote_src: true
    extra_opts: [--strip-components=1]
    creates: /opt/nvim/bin/nvim

- name: Symlink onto PATH
  ansible.builtin.file:
    src: /opt/nvim/bin/nvim
    dest: /usr/local/bin/nvim
    state: link

- name: Default editor
  ansible.builtin.copy:
    dest: /etc/profile.d/99-editor.sh
    content: "export EDITOR=nvim\nexport VISUAL=nvim\n"
    mode: "0644"

- name: Clone LazyVim starter
  ansible.builtin.git:
    repo: https://github.com/LazyVim/starter
    dest: "/home/{{ admin_user }}/.config/nvim"
    depth: 1
  become_user: "{{ admin_user }}"
  args: { creates: "/home/{{ admin_user }}/.config/nvim/init.lua" }

- name: Drop starter git history so the config is yours
  ansible.builtin.file:
    path: "/home/{{ admin_user }}/.config/nvim/.git"
    state: absent

- name: Headless plugin sync
  ansible.builtin.command: nvim --headless "+Lazy! sync" +qa
  become_user: "{{ admin_user }}"
  args: { creates: "/home/{{ admin_user }}/.local/share/nvim/lazy/lazy.nvim" }
```

The asset is **`nvim-linux-x86_64.tar.gz`** — it was `nvim-linux64.tar.gz` until v0.10.4,
so 2024-era playbooks 404 here. The Nerd Font is a terminal concern: install it on the
WSL/Windows side.

### 5.5 `roles/node_health`

> **Read first**
> - node_exporter textfile collector — https://github.com/prometheus/node_exporter#textfile-collector
> - `smartctl` JSON output — https://www.smartmontools.org/browser/trunk/smartmontools/smartctl.8.in
> - kube-prometheus-stack values — https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml

kube-prom already runs node-exporter with `--collector.hwmon`, `--collector.thermal_zone`
and `--collector.rapl`. Those read sysfs and produce nothing until `lm-sensors` has run
`sensors-detect` and loaded the right modules — so empty thermal panels on a new node are
an OS gap, not a Prometheus one (F10).

```yaml
- name: Install health/power tooling
  ansible.builtin.apt:
    name:
      - lm-sensors        # populates hwmon
      - smartmontools     # the actual disk-failure early warning
      - nvme-cli          # NVMe wear + temp that smartctl can miss
      - powertop
      - linux-tools-common
      - linux-tools-generic
    state: present

- name: Detect sensors non-interactively
  ansible.builtin.command: sensors-detect --auto
  args: { creates: /etc/modules-load.d/lm-sensors.conf }

- name: Enable smartd
  ansible.builtin.systemd: { name: smartd, enabled: true, state: started }

- name: Textfile collector directory
  ansible.builtin.file:
    path: /var/lib/node_exporter/textfile_collector
    state: directory
    mode: "0755"

- name: SMART exporter script
  ansible.builtin.copy:
    dest: /usr/local/bin/smart-textfile.sh
    mode: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      OUT=/var/lib/node_exporter/textfile_collector/smart.prom
      TMP="${OUT}.$$"
      {
        echo "# HELP smart_device_health 1 = PASSED, 0 = FAILED"
        echo "# TYPE smart_device_health gauge"
        echo "# HELP smart_device_temp_celsius Drive temperature"
        echo "# TYPE smart_device_temp_celsius gauge"
        echo "# HELP smart_device_percentage_used NVMe endurance consumed (percent)"
        echo "# TYPE smart_device_percentage_used gauge"
        for d in $(lsblk -dno PATH,TYPE | awk '$2=="disk"{print $1}'); do
          j=$(smartctl -a -j "$d" 2>/dev/null) || continue
          ok=$(echo "$j"  | jq -r '.smart_status.passed // empty')
          tmp=$(echo "$j" | jq -r '.temperature.current // empty')
          pct=$(echo "$j" | jq -r '.nvme_smart_health_information_log.percentage_used // empty')
          [ -n "$ok" ]  && echo "smart_device_health{device=\"$d\"} $([ "$ok" = true ] && echo 1 || echo 0)"
          [ -n "$tmp" ] && echo "smart_device_temp_celsius{device=\"$d\"} $tmp"
          [ -n "$pct" ] && echo "smart_device_percentage_used{device=\"$d\"} $pct"
        done
      } > "$TMP"
      mv "$TMP" "$OUT"

- name: SMART collector units
  ansible.builtin.copy:
    dest: "/etc/systemd/system/{{ item.n }}"
    mode: "0644"
    content: "{{ item.c }}"
  loop:
    - n: smart-textfile.service
      c: |
        [Unit]
        Description=Write SMART metrics for node-exporter
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/smart-textfile.sh
    - n: smart-textfile.timer
      c: |
        [Unit]
        Description=Run SMART textfile collector every 15m
        [Timer]
        OnBootSec=5min
        OnUnitActiveSec=15min
        [Install]
        WantedBy=timers.target

- name: Enable timer
  ansible.builtin.systemd:
    name: smart-textfile.timer
    enabled: true
    state: started
    daemon_reload: true
```

Write to `$TMP` then `mv` — the upstream textfile-collector docs call out that files must
be written atomically, and node-exporter will otherwise scrape a half-written `.prom` and
emit a parse error that looks like an intermittent scrape failure (F11).

**Matching GitOps change** (`apps/monitoring/values-monitoring.yaml` — ArgoCD's side):

```yaml
prometheus-node-exporter:
  extraArgs:
    - --collector.hwmon
    - --collector.thermal_zone
    - --collector.rapl
    - --collector.textfile.directory=/host/textfile
  extraHostVolumeMounts:
    - name: textfile
      hostPath: /var/lib/node_exporter/textfile_collector
      mountPath: /host/textfile
      readOnly: true
  securityContext:
    runAsNonRoot: false
```

Then a PrometheusRule (namespace `monitoring`, label `release: kube-prom`) on
`smart_device_health == 0` and `smart_device_percentage_used > 80`. `sol`'s DRAM-less
1 TB SSD is exactly the drive that wants an endurance alert.

### 5.6 kube-vip — the one place this document overrides the vendor

> **Read first**
> - kube-vip on K3s (vendor's recommended path) — https://kube-vip.io/docs/usage/k3s/
> - Static-pod install — https://kube-vip.io/docs/installation/static/
> - DaemonSet install — https://kube-vip.io/docs/installation/daemonset/
> - K3s auto-deploying manifests — https://docs.k3s.io/installation/packaged-components
> - Known static-pod restart issue — https://github.com/kube-vip/kube-vip/issues/909
> - Static pod + ServiceAccount token issue — https://github.com/kube-vip/kube-vip/issues/830

**kube-vip's K3s page says to run it as a DaemonSet, not a static pod**, and to place the
RBAC manifest plus the DaemonSet into `/var/lib/rancher/k3s/server/manifests/` — K3s's
auto-deploy directory, where anything found is applied like `kubectl apply`.

That path is well-trodden and vendor-supported. Its cost here is that Ansible would be
writing *cluster resources* (a ServiceAccount, ClusterRole, and DaemonSet) onto disk,
which is the layer-boundary violation this whole design exists to avoid, and it makes
kube-vip's availability depend on the API server it is meant to front.

**Recommendation: static pod in `/var/lib/rancher/k3s/agent/pod-manifests/`, and treat
this as the single highest-priority item in the VM rehearsal.** The static-pod path works
on K3s and is widely used, but it is not what the vendor documents, and there are two
known sharp edges worth reading before you commit:

- Issue #830: a static-pod kube-vip has no ServiceAccount token, so it must authenticate
  via a kubeconfig. The manifest below mounts `/etc/rancher/k3s/k3s.yaml` at
  `/etc/kubernetes/admin.conf`, where kube-vip looks by default.
- Issue #909: a static-pod kube-vip on RKE2 was reported not restarting after a node
  reboot. **Test reboot survival explicitly in the VM lab.** If it fails, fall back to the
  vendor's DaemonSet path and accept the boundary compromise — a working VIP beats a tidy
  diagram.

Rendered to `/var/lib/rancher/k3s/agent/pod-manifests/kube-vip.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:{{ kube_vip_version }}
      imagePullPolicy: IfNotPresent
      args: ["manager"]
      env:
        - { name: vip_arp,            value: "true" }
        - { name: port,               value: "6443" }
        - { name: vip_interface,      value: "{{ kube_vip_interface }}" }
        - { name: vip_cidr,           value: "32" }
        - { name: cp_enable,          value: "true" }
        - { name: cp_namespace,       value: "kube-system" }
        - { name: vip_ddns,           value: "false" }
        - { name: svc_enable,         value: "false" }   # ServiceLB keeps owning Services
        - { name: vip_leaderelection, value: "true" }
        - { name: vip_leaseduration,  value: "15" }
        - { name: vip_renewdeadline,  value: "10" }
        - { name: vip_retryperiod,    value: "2" }
        - { name: address,            value: "{{ k3s_vip }}" }
        - { name: prometheus_server,  value: ":2112" }
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW", "SYS_TIME"]
      volumeMounts:
        - { name: kubeconfig, mountPath: /etc/kubernetes/admin.conf }
  volumes:
    - name: kubeconfig
      hostPath: { path: /etc/rancher/k3s/k3s.yaml }
```

`svc_enable: false` is deliberate. K3s's ServiceLB already handles your LoadBalancer
Services including penny-dev's Postgres on 5432; kube-vip's `--services` equivalent would
give you two controllers fighting over the same objects.

In ARP mode kube-vip runs leader election, the leader binds the VIP to its interface and
broadcasts a gratuitous ARP so switches update their MAC tables, and another node takes
the lease if the leader fails.

### 5.7 `roles/k3s_common` — `config.yaml.j2`

> **Read first**
> - Configuration file + `config.yaml.d` drop-ins — https://docs.k3s.io/installation/configuration
> - Full server flag reference — https://docs.k3s.io/cli/server

K3s loads `/etc/rancher/k3s/config.yaml` and then `/etc/rancher/k3s/config.yaml.d/*.yaml`
in alphabetical order; CLI arguments take precedence over both, and for repeatable keys
the last file wins unless you use the `+` append suffix. That's what makes a templated
file plus a mode-`0600` drop-in for credentials work cleanly.

```yaml
# {{ ansible_managed }}
# /etc/rancher/k3s/config.yaml — Ansible owns this file. Do not hand-edit.
token: "{{ vault_k3s_token }}"
node-ip: "{{ ansible_host }}"
node-name: "{{ inventory_hostname }}"

{% if k3s_role == 'server' %}
{% if k3s_cluster_init | default(false) %}
cluster-init: true
{% elif not k3s_bootstrap_complete | default(false) %}
server: "https://{{ hostvars[groups['k3s_servers'][0]].ansible_host }}:6443"
{% else %}
server: "https://{{ k3s_vip }}:6443"
{% endif %}

tls-san:
{% for san in k3s_tls_sans %}
  - "{{ san }}"
{% endfor %}

write-kubeconfig-mode: "0644"

etcd-snapshot-schedule-cron: "{{ etcd_snapshot_cron }}"
etcd-snapshot-retention: {{ etcd_snapshot_retention }}

kubelet-arg:
  - "system-reserved={{ kubelet_reserved.system_reserved }}"
  - "kube-reserved={{ kubelet_reserved.kube_reserved }}"
{% else %}
server: "https://{{ k3s_vip }}:6443"
{% endif %}
```

Three-way branch on the server URL: a joining server points at `deus` (the VIP may not
have elected a leader yet); once `k3s_bootstrap_complete` flips, it points at the VIP and
never depends on `deus` again.

### 5.8 etcd snapshots to Garage — `config.yaml.d/etcd-s3.yaml`, mode `0600`

> **Read first**
> - `k3s etcd-snapshot`, S3 config and restore — https://docs.k3s.io/cli/etcd-snapshot
> - Backup/restore overview — https://docs.k3s.io/datastore/backup-restore

```yaml
etcd-s3: true
etcd-s3-endpoint: "{{ etcd_s3_endpoint }}"
etcd-s3-bucket: "{{ etcd_s3_bucket }}"
etcd-s3-region: "{{ etcd_s3_region }}"
etcd-s3-access-key: "{{ vault_etcd_s3_access_key }}"
etcd-s3-secret-key: "{{ vault_etcd_s3_secret_key }}"
etcd-s3-skip-ssl-verify: true      # Garage on the LAN over plain HTTP
```

Worth knowing before you need it: **S3 configuration must come from CLI flags or the
config file during a restore, not from a config Secret**, because Secrets aren't
available before the cluster is running. Putting the credentials in this drop-in rather
than using `etcd-s3-config-secret` is what keeps disaster recovery possible.

Restore shape, for when you're reading this at 2am: stop K3s on all servers, then on one
server run `k3s server --cluster-reset --cluster-reset-restore-path=<SNAPSHOT>` with the
`--etcd-s3` flags, passing only the filename if the snapshot is in S3. K3s prints that
membership has been reset and asks you to restart without the flag. The other members'
`${datadir}/server/db` must then be deleted and the nodes rejoined. K3s writes
`/var/lib/rancher/k3s/server/db/reset-flag` to stop you doing this twice by accident.

### 5.9 K3s install task

```yaml
- name: Check installed k3s version
  ansible.builtin.command: k3s --version
  register: k3s_installed
  changed_when: false
  failed_when: false

- name: Install/upgrade k3s
  ansible.builtin.shell: |
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION={{ k3s_version }} \
      INSTALL_K3S_EXEC="{{ k3s_role }}" \
      INSTALL_K3S_SKIP_START=true \
      sh -
  when: k3s_version not in (k3s_installed.stdout | default(''))
  args: { executable: /bin/bash }
```

`INSTALL_K3S_SKIP_START=true` lets the config template land before the service starts, so
a node never boots once with the wrong identity.

### 5.10 `playbooks/k3s-server-join.yml` — the health gate

> **Read first**
> - `serial` / rolling updates — https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_strategies.html
> - `until` retries — https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_loops.html#retrying-a-task-until-a-condition-is-met

```yaml
- hosts: k3s_servers:!deus
  serial: 1
  become: true
  roles:
    - k3s_common
    - k3s_server
  post_tasks:
    - name: Wait for node Ready
      ansible.builtin.command: >-
        k3s kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=300s
      delegate_to: deus
      changed_when: false

    - name: Gate — all etcd members healthy before touching the next host
      ansible.builtin.shell: |
        set -o pipefail
        k3s kubectl get nodes -l node-role.kubernetes.io/etcd=true \
          -o jsonpath='{range .items[*]}{.metadata.name}={range .status.conditions[?(@.type=="Ready")]}{.status}{end} {end}'
      delegate_to: deus
      register: etcd_health
      until: "'False' not in etcd_health.stdout and 'Unknown' not in etcd_health.stdout"
      retries: 30
      delay: 10
      changed_when: false
```

`serial: 1` plus the gate is the whole reason to automate rather than paste commands.
Without it a fast run starts the second join while the first member is still catching up
on the Raft log — which is how a three-node build ends as a two-node cluster that won't
elect a leader.

---

## 6. Runbook

### Phase 0 — Backups

```bash
ssh deus 'k3s --version'        # -> k3s_version in group_vars/all.yml

kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-keys-$(date +%F).yaml

ssh deus 'sudo systemctl stop k3s && \
  sudo tar czf /root/k3s-sqlite-$(date +%F).tgz /var/lib/rancher/k3s/server/db && \
  sudo systemctl start k3s'
```

Copy both off `deus`. The tarball is the only artifact that can undo Phase 3.

```bash
kubectl -n kube-system scale deployment kured --replicas=0
```

A kured reboot inside the two-member window is F1, and `lockReleaseDelay: 25m` will not
save you — that delay paces reboots; it knows nothing about etcd quorum.

### Phase 1 — Provision new hardware (no K3s)

```bash
ansible-playbook playbooks/provision-node.yml --limit sol --check --diff
ansible-playbook playbooks/provision-node.yml --limit sol
ansible-playbook playbooks/provision-node.yml --limit opus
```

**Gate:** both reachable at static IPs *and* over the tailnet; routes approved in the
Tailscale console; `sensors` returns readings; `nvim` opens LazyVim clean; `opus`
power-recovery test done (§1).

### Phase 2 — Backfill existing nodes

```bash
ansible-playbook playbooks/provision-node.yml --limit legion --check --diff
ansible-playbook playbooks/provision-node.yml --limit legion
ansible-playbook playbooks/provision-node.yml --limit nebula
ansible-playbook playbooks/provision-node.yml --limit deus --check --diff
ansible-playbook playbooks/provision-node.yml --limit deus
```

`legion` first — the node whose loss matters least. The `deus --check --diff` is where you
find out what was hand-configured and never written down. Run it early, while a surprise
is just information.

### Phase 3 — The migration

```bash
ansible-playbook playbooks/k3s-server-init.yml --limit deus
```

**API server unavailable for roughly 30–90 seconds.** Workloads keep running; ArgoCD logs
connection errors through the window.

```bash
kubectl get nodes                                       # deus Ready
ssh deus 'sudo ls /var/lib/rancher/k3s/server/db/etcd'  # etcd dir exists
kubectl get node deus -o jsonpath='{.metadata.labels}' | tr , '\n' | grep etcd
ping -c1 192.168.1.247                                  # VIP up
kubectl --server=https://192.168.1.247:6443 get nodes   # VIP serves the API
```

**Stop if any of those fail.** Restoring from the Phase 0 tarball is possible now and much
harder once a second member joins.

### Phase 4 — Join members two and three, same sitting

```bash
ansible-playbook playbooks/k3s-server-join.yml --limit opus
ansible-playbook playbooks/k3s-server-join.yml --limit sol
```

Between these two commands you are in the **two-member window** — don't reboot anything.

```bash
kubectl get nodes -o wide
ssh opus 'sudo k3s etcd-snapshot ls'
kubectl -n kube-system get pods -l component=kube-vip -o wide   # 3 pods, 1 leader
```

### Phase 5 — Repoint agents, then servers

```bash
ansible-playbook playbooks/repoint-agents.yml --limit legion
ansible-playbook playbooks/repoint-agents.yml --limit nebula
```

Then set `k3s_bootstrap_complete: true`, re-run `site.yml`, and:

```bash
sed -i 's|192.168.1.250:6443|192.168.1.247:6443|' ~/.kube/config
```

### Phase 6 — Prove it

```bash
ssh deus 'sudo systemctl stop k3s'
kubectl get nodes                    # still answers, via the VIP on another member
kubectl -n argocd get applications
ssh deus 'sudo systemctl start k3s'
kubectl -n kube-system scale deployment kured --replicas=1
```

That first command is the entire point of the last two nodes.

---

## 7. Deferred — do not bundle into this window

- **Longhorn disks on `sol` and `opus`.** Adding storage nodes changes replica scheduling
  while `persistence.defaultClassReplicaCount: 2` stays at 2. Separate change, with
  `LonghornVolumeDegraded` quiet before and after.
  Read: https://longhorn.io/docs/latest/nodes-and-volumes/nodes/multidisk/
- **Unpinning workloads from `deus`.** ArgoCD, cloudflared, nginx, penny-dev backend and
  the CNPG operator all carry `nodeSelector: kubernetes.io/hostname: deus`. One
  Application at a time.
- **Tailscale Kubernetes Operator** for the `192.168.1.0/24` collision.
  Read: https://tailscale.com/docs/features/kubernetes-operator
- **kured `--alert-filter-regex`** with an etcd health alert in the blocking set.
  Read: https://kured.dev/docs/configuration/

---

## 8. Failure modes

| # | Symptom | Cause | Prevention / fix |
|---|---|---|---|
| F1 | Cluster wedges, no leader | Reboot during the two-member window | Join `sol` same sitting; kured masked in Phase 0 |
| F2 | New server won't join, TLS/token error | `vault_k3s_token` generated, not copied | Read `/var/lib/rancher/k3s/server/token` on deus |
| F3 | Traefik silently upgrades cluster-wide | Newer K3s on a new node writes a newer bundled `traefik.yaml` into the auto-deploy dir | Pin `k3s_version` to deus's exact version — verify **on deus** |
| F4 | `x509: certificate is valid for ...` via the VIP | VIP missing from `tls-san` | Add to `k3s_tls_sans`, restart k3s on all servers |
| F5 | VIP conflict | `.247` handed out by DHCP | Pool ends at `.240` — re-verify before Phase 3 |
| F6 | 5432 / 80 / 443 answering on new nodes | ServiceLB creates a DaemonSet across *all* nodes | Confirm penny-dev's LB still uses `svccontroller.k3s.cattle.io/nodeselector` scoped to deus |
| F7 | etcd `apply request took too long`, flapping leader | etcd on a DRAM-less or shared disk | `etcd_data_device` on cached NVMe only; alert on `etcd_disk_wal_fsync_duration_seconds` p99 > 100 ms |
| F8 | Node labels don't change on re-run | K3s applies `node-label` at registration only | Set at first join; later changes need `kubectl label` |
| F9 | Tailnet routing still fails when deus is down | Routes advertised but not approved | Manual console step, per node |
| F10 | Thermal/rapl panels empty on new nodes | `sensors-detect` never ran | `node_health` role; verify with `sensors` |
| F11 | Intermittent node-exporter scrape errors | Textfile read mid-write | `$TMP` then `mv` |
| F12 | Node drops off the network during the netplan role | `50-cloud-init.yaml` is the *live* static config on every existing node — deleting it first, or naming the replacement `10-` so it loses the merge, takes the node offline | Replacement is `90-homelab.yaml`; write → `netplan generate` → diff → remove → assert → apply; original snapshotted to `/root` |
| F13 | `opus` stays dark after a power cut | BIOS AC-recovery locked off | Test in §1; alert loudly on `KubeNodeNotReady` |
| F14 | kube-vip gone after a node reboot | Static-pod restart issue (kube-vip #909) | Test reboot survival in the VM lab; fall back to the DaemonSet path if it reproduces |

---

## 9. Pre-flight checklist

- [ ] `k3s --version` captured from deus, written into `k3s_version`
- [ ] `opus` AC power-recovery tested (§1), outcome recorded
- [ ] Static IPs set in installer: `sol` `.251`, `opus` `.252`
- [ ] `hostnamectl set-hostname` matches inventory keys on both
- [ ] DHCP pool confirmed to still end at `.240`; `.247` unused
- [ ] `vault_k3s_token` copied from deus, not generated
- [ ] Tailscale auth key reusable, pre-approved, tagged; `--accept-routes` **off** for servers
- [ ] Garage bucket `k3s-etcd` exists; creds in the `0600` drop-in, not a Secret
- [ ] Sealed Secrets keyring backed up **off** cluster
- [ ] SQLite datastore tarball copied off deus
- [ ] kured scaled to zero
- [ ] `lsblk` from both new nodes checked against `etcd_data_device`
- [ ] kube-vip static-pod reboot survival tested in the VM lab (F14)
- [ ] DNS A records for `opus.lab` / `sol.lab` (grey-cloud)
- [ ] Two to three uninterrupted hours

---

## 10. Reading list

**K3s**
- HA embedded etcd — https://docs.k3s.io/datastore/ha-embedded
- Configuration file and drop-ins — https://docs.k3s.io/installation/configuration
- Server flag reference — https://docs.k3s.io/cli/server
- Agent flag reference — https://docs.k3s.io/cli/agent
- Packaged components / auto-deploy manifests — https://docs.k3s.io/installation/packaged-components
- etcd snapshots, S3, restore — https://docs.k3s.io/cli/etcd-snapshot
- Backup and restore — https://docs.k3s.io/datastore/backup-restore
- Networking / ServiceLB — https://docs.k3s.io/networking/networking-services

**kube-vip**
- K3s usage (the vendor's DaemonSet recommendation) — https://kube-vip.io/docs/usage/k3s/
- Static pod install — https://kube-vip.io/docs/installation/static/
- DaemonSet install — https://kube-vip.io/docs/installation/daemonset/
- Flags reference — https://kube-vip.io/docs/installation/flags/

**Tailscale**
- Subnet routers — https://tailscale.com/docs/features/subnet-routers
- HA setup — https://tailscale.com/docs/how-to/set-up-high-availability
- Overlapping-route failover — https://tailscale.com/docs/reference/troubleshooting/network-configuration/overlapping-subnet-route-failover
- ACL tags — https://tailscale.com/docs/features/tags

**Ansible**
- Directory layout / tips — https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html
- Roles — https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html
- Vault — https://docs.ansible.com/ansible/latest/vault_guide/index.html
- Strategies and `serial` — https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_strategies.html
- `ansible.posix.sysctl` — https://docs.ansible.com/ansible/latest/collections/ansible/posix/sysctl_module.html

**Ubuntu / OS**
- Netplan YAML reference — https://netplan.readthedocs.io/en/stable/netplan-yaml/
- cloud-init network disabling — https://cloudinit.readthedocs.io/en/latest/reference/datasources.html
- smartmontools — https://www.smartmontools.org/wiki/TocDoc

**Monitoring**
- node_exporter textfile collector — https://github.com/prometheus/node_exporter#textfile-collector
- kube-prometheus-stack values — https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

**Editor**
- LazyVim installation — https://www.lazyvim.org/installation
- Neovim releases — https://github.com/neovim/neovim/releases
