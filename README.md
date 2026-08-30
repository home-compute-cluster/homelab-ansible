# homelab-ansible

Ansible below K3s, ArgoCD inside it. This repo owns partitions, netplan,
sysctl, packages, Tailscale, the K3s binary and version,
`/etc/rancher/k3s/config.yaml`, static pods and systemd units. Anything with an
`apiVersion` belongs to ArgoCD instead.

The design and the reasoning behind it live in
[`ha-control-plane-ansible.md`](ha-control-plane-ansible.md). This file is the
operating manual.

## Setup

```bash
ansible-galaxy collection install -r requirements.yml
echo '<vault password>' > ~/.ansible/homelab-vault-pass && chmod 600 ~/.ansible/homelab-vault-pass
cp inventory/group_vars/all.vault.yaml.example inventory/group_vars/all.vault.yaml
# fill it in, then:
ansible-vault encrypt --encrypt-vault-id homelab inventory/group_vars/all.vault.yaml
```

`all.vault.yaml` is gitignored because it is currently plaintext. Once it is
encrypted, drop that line from `.gitignore` — an encrypted vault file belongs
in the repo.

`vault_k3s_token` is **copied** from `/var/lib/rancher/k3s/server/token` on
`deus`, never generated. A generated token produces a TLS/token error on join
(F2).

## Layout

| Path | What it is |
|---|---|
| `playbooks/site.yaml` | Everything, safe to re-run. Servers `serial: 1`. |
| `playbooks/provision-node.yaml` | OS-level only, touches nothing K3s owns. |
| `playbooks/netplan.yaml` | Opt-in. Network config is managed by hand — see below. |
| `playbooks/tailscale.yaml` | Opt-in. Installs the package; does not claim tailnet membership. |
| `playbooks/k3s-server-init.yaml` | `deus`: SQLite → etcd. One-way, heavily guarded. |
| `playbooks/k3s-server-join.yaml` | `opus`/`sol`, `serial: 1` behind an etcd health gate. |
| `playbooks/repoint-agents.yaml` | Agents → VIP, after the bootstrap flag flips. |
| `playbooks/node-updates.yaml` | Patch, cordon, drain, reboot, uncordon. |

## Adding a node later

The point of the repo. Adding a sixth node is inventory, not playbook work:

1. Add it to `inventory/hosts.yaml` under `k3s_servers` or `k3s_agents`.
2. Add `inventory/host_vars/<name>.yaml` with `etcd_data_device`,
   `longhorn_disk_device` and the `k3s_node_labels` it should register with.
3. `hostnamectl set-hostname <name>` on the box, matching the inventory key.
   Node names are fixed at registration and the `preflight` role refuses to
   continue if they disagree.
4. `ansible-playbook playbooks/provision-node.yaml --limit <name> --check --diff`
   then without `--check`.
5. Agents: `ansible-playbook playbooks/site.yaml --limit <name>`.
   Servers: `ansible-playbook playbooks/k3s-server-join.yaml --limit <name>`.

`k3s_node_labels` are applied at registration **only** (F8). Getting them into
`host_vars` before the first join is the difference between a node that comes
up correct and one that needs `kubectl label` afterwards.

## The HA migration

Phases match `ha-control-plane-ansible.md` §6. Notes where reality differs from
what that document assumed, all verified against the live cluster on
2026-08-30:

- **kured is not deployed.** Phase 0's `scale deployment kured --replicas=0`
  has nothing to scale. The two-member window is still real (F1) — just do not
  reboot anything yourself.
- **`nebula` runs `v1.35.5+k3s1`**, one patch ahead of `deus` and of the pin.
  `k3s_allow_downgrade: false` leaves it alone. `k3s-server-join.yaml` asserts
  the pin matches `deus` before any join, because a member joining on a
  different version upgrades the bundled Traefik cluster-wide (F3).
- **ServiceLB is not scoped.** `penny-dev-db-lb` is annotated
  `lbpool: penny-dev-db` but no node carries that label, so Postgres on 5432
  already answers on all three nodes and will answer on five after the joins
  (F6). `k3s-server-join.yaml` reports this before each join. Fixing it is a
  GitOps change: either annotate the Service with a pool that exists, or label
  the intended nodes with `penny-dev-db`.
- **Longhorn creates a default disk on every new node.**
  `create-default-disk-labeled-nodes` is `false` cluster-wide, so `opus` and
  `sol` become storage nodes on their OS disks the moment they join, regardless
  of `longhorn_enabled: false`. To actually defer §7, flip that setting to
  `true` on the ArgoCD side first — the
  `node.longhorn.io/create-default-disk=false` label in their `host_vars` only
  bites once it is.
- **node-exporter has no textfile collector.** The `node_health` role writes
  `smart.prom` every 15 minutes, but the kube-prom DaemonSet has no
  `--collector.textfile.directory` and no hostPath mount, so nothing scrapes it
  (F11's sibling). That values change is on ArgoCD's side.

Phase 5 is a variable, not a procedure: set `k3s_bootstrap_complete: true` in
`inventory/group_vars/all.yaml` and re-run. Before the flip every node points
at `deus`; after it, at the VIP. This is why `site.yaml` is safe to run today.

## Deliberately not automated

Two roles were built, proven, and then taken off the default path. Both are
still runnable on their own; neither is on the way to a HA control plane.

**Networking (`netplan`).** The role works — it renders a template, diffs the
generated systemd-networkd output against the live config, applies only if
they match, and rolls back without touching the running network if they
don't. That was demonstrated end to end on `legion-1`. But adopting each
node's hand-written config into a template that reproduces it byte for byte
is a project of its own. The addresses are static and set in the installer
regardless, so nothing downstream depends on it.

**Tailscale.** The deeper problem, and the more instructive one. The role can
only observe the node: package installed, daemon running, CLI exited zero.
None of that is the thing that matters — whether the machine is in the
tailnet, whether its tags were accepted, whether its routes were approved.
All three live in Tailscale's control plane, and every one can be false while
every task reports success. A run that goes green while the node never
appears in the machine list is worse than no automation, because it spends
trust it has not earned.

Making it honest means querying the Tailscale API for device state and
asserting on that, with its own API credential to manage. That is a real
piece of work, not a `tailscale up` wrapper. Until it exists, enrolment is
manual — and it is a short manual step.

The general rule this leaves: **a role that manages state in someone else's
control plane must verify against that control plane, or it must not claim
success.** The `k3s_*` roles satisfy this — they assert with `kubectl`
against the cluster itself. `base`, `nvim`, `node_health`, `multipath` and
`longhorn_disk` satisfy it trivially, since everything they touch is local
and observable on the node.

## Still manual

- Tailscale enrolment, tag acceptance, and subnet-route approval, per node
  (F9). `--accept-routes` must stay **off** on the servers.
- The `opus` AC power-recovery test (§1). BIOS is password-locked.
- Backing up the Sealed Secrets keyring off-cluster before Phase 3.
- kube-vip static-pod reboot survival in the VM lab (F14).

## Checks that run before anything is touched

`preflight` asserts the remote hostname matches the inventory key, the OS is
Ubuntu 24.04+, `admin_user` exists, and `ansible_host` is actually configured
on the node. The hostname assert is also what catches a swapped IP-to-host
mapping, while catching it is still free.

`netplan` writes → `netplan generate` → diffs the rendered output → removes
`50-cloud-init.yaml` → asserts nothing moved → applies. If any of that fails it
restores the cloud-init file and removes its own, so a failed run leaves the
node exactly as it was found. On the existing nodes `50-cloud-init.yaml` is the
live static config, not a leftover (F12).

Both `etcd_data_device` and `longhorn_disk_device` refuse to `mkfs` anything
that was not explicitly opted in per host.
