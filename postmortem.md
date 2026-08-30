**POSTMORTEM · HOMELAB-ANSIBLE · 2026-08-30**

# SQLite to Quorum

Converting a single k3s control-plane node into three embedded-etcd members, and the eleven things that had to be fixed along the way. No data was lost. The one irreversible step succeeded on the first attempt. Almost everything that went wrong afterwards, we wrote ourselves.

| Window         | API outage | Data loss | Rollback used | Members |
|----------------|------------|-----------|---------------|---------|
| 18:01 to 18:50 | ~20 min    | None      | No            | 1 to 3  |

## What happened

The cluster ran a single k3s server, `deus`, backed by the default embedded SQLite datastore, with two agents alongside it. We converted it to a three-member embedded-etcd control plane by adding `opus` and `sol`, and moved the API endpoint onto a kube-vip virtual address so that nothing depends on `deus` being alive.

The conversion itself worked. Immediately afterwards the k3s service entered a restart loop and stayed there for roughly twenty minutes across 54 restarts. The cause was a node label our own Ansible template passed to kubelet, which kubelet is not permitted to accept. Once removed, the cluster came back with its data intact. Both new servers then joined without incident, and the final test, which is stopping k3s on `deus` and confirming the API still answers, passed.

## Who felt it

The Kubernetes API was unavailable or intermittent for about twenty minutes. Workloads already running on the two agents kept running throughout, because kubelet does not need the API to keep existing pods alive. ArgoCD, Traefik and the CNPG-managed Postgres instance continued serving traffic. What stopped was scheduling, any use of `kubectl`, and anything that needed to reconcile. No persistent volume, secret or etcd key was lost, and the pre-migration SQLite tarball was never needed.

## Why this was a project and not a shell command

Adding an agent to k3s is one command. Adding the second and third server to a cluster that was built as a single server is not, and the design document written beforehand was explicit about why.

> **deus is on SQLite.** The K3s docs are explicit that an existing cluster on the default embedded SQLite database is converted to etcd by restarting the server with `--cluster-init`, after which additional servers can be added. The conversion is **one-way**. This is the only step that can lose the cluster. *Source: ha-control-plane-ansible.md, section 0*

> **Going 1 to 3 members means passing through 2.** Quorum in a two-member etcd cluster is two, so losing either wedges it. Strictly worse than where you are now, so the window must be short. *Source: ha-control-plane-ansible.md, section 0*

A third constraint is what made a templated configuration worth building rather than pasting flags per host:

> Some options must be identical on every server, or new servers fail to join when using embedded etcd. That is what makes the templated `config.yaml` worth building rather than pasting flags per host. *Source: ha-control-plane-ansible.md, section 0*

The repository is shaped around a single rule, which is also why it is a separate repository from the GitOps one. The boundary is physical rather than conventional:

> **Ansible, below K3s:** partitions, netplan, sysctl, packages, Tailscale, the K3s binary and version, `/etc/rancher/k3s/config.yaml`, static pods, systemd units.
> **ArgoCD, inside K3s:** everything with an `apiVersion`. *Source: ha-control-plane-ansible.md, layer boundary*

That boundary held for the whole migration. The k3s roles are allowed to assert their results with `kubectl` against the cluster itself, which is the only honest way for a role to know whether the thing it configured actually took effect. Finding 6 is what happens when a role has no such check available.

## 2026-08-30, Singapore time

| Time | Event |
|----|----|
| 18:01 | Phase 3 begins. The playbook stops k3s, tars the SQLite datastore, asserts the tarball is non-empty, and fetches it off the node. |
| 18:02 | Datastore converted. `state.db.migrated` written, etcd elects a leader, bootstrap data saved. |
| 18:02 | k3s begins restarting. The systemd counter climbs. The API returns 503. |
| 18:08 | The playbook fails waiting for the etcd role label, which cannot appear while kubelet is dying. |
| 18:12 | Investigation focuses on etcd, which is healthy on every cycle. This costs most of the outage. |
| 18:16 | kube-vip and the S3 drop-in are quarantined to isolate our own additions. No change. |
| 18:19 | k3s is run in the foreground. The fatal error is visible in one line: kubelet rejects `node-role.kubernetes.io/worker`. |
| 18:22 | Label removed, k3s starts, the node reports `control-plane,etcd,worker`. |
| 18:30 | kube-vip is found running but never claiming the address. The missing `hostAliases` entry is added. |
| 18:42 | The `opus` join fails before touching the node, on a version-parsing bug. Fixed and retried. |
| 18:50 | Three etcd members. Final test passes: k3s stopped on `deus`, API still answers. |

## Caught before the window

These never reached production. They are listed because the reason they did not is the interesting part: dry runs, a check run against the least important node, and one role that refused to proceed.

### 01. The repository could not have run at all \[Tooling\]

Roles were flat task files at paths Ansible never loads. Every host in the inventory used `ansible_host::` with two colons, so no host had a usable address. Variables lived in `hosts_vars/`, which Ansible ignores in favour of `host_vars/`.

**Fixed by** restructuring to the standard layout and rewriting the inventory.

### 02. Every run aborted before its first task \[Tooling\]

`ansible.cfg` set `stdout_callback = yaml`. That plugin was removed in community.general 12, and its absence is fatal rather than a warning.

**Fixed by** switching to the built-in callback with `result_format = yaml`.

### 03. The vault file was never read \[Config\]

Secrets lived in `group_vars/all.vault.yaml`. Ansible resolves group_vars by group name, so a file whose basename is `all.vault` matches no group and is skipped in silence. Encrypting it changed nothing, because nothing was reading it. The failure surfaced much later as an undefined variable inside a `no_log` task, with the cause censored along with the secret.

**Fixed by** moving to the directory form, `group_vars/all/`, and adding a preflight assert that the vault loaded and no longer holds the example placeholders.

### 04. The netplan role refused to apply, correctly \[Network\]

On `legion-1` the managed template rendered different systemd-networkd output than the live config. The role compared the two renders, refused to apply, restored `50-cloud-init.yaml` and removed its own file. The running network was never touched. The cause was one line: the live config had `dhcp4: true` alongside a static address, and the template hardcoded `false`.

**Fixed by** adopting the DHCP flags from the live config rather than asserting a guess. The role was later removed from the default path entirely, since adopting every node's hand-written network config is a project of its own and nothing downstream depends on it.

### 05. Two etcd devices pointed at disks already in use \[Storage\]

The design document specified `/dev/nvme0n1p3` for `sol`. That is the LVM physical volume holding the root filesystem. It carries a valid filesystem signature, so a naive do-not-format guard would have passed it, and the role would then have written an fstab entry mounting the root volume at the etcd directory. The device named for `opus` did not exist at all.

**Fixed by** checking `findmnt` for the device being mounted elsewhere and `blkid` for LVM, RAID and LUKS membership, then refusing either. Both nodes now keep etcd on the OS disk, which is cached NVMe on all three servers and satisfies the actual requirement.

### 06. The Tailscale role could not verify what it claimed \[Design\]

The role checked that the package installed, that the daemon ran, and that the CLI exited zero. None of that establishes what matters: whether the machine is in the tailnet, whether its tags were accepted, whether its routes were approved. All three live in Tailscale's control plane. A run went green against a node that was not in the machine list.

**Fixed by** removing it from the default playbooks. The rule it produced: a role that manages state in someone else's control plane must verify against that control plane, or it must not report success.

## Found inside the window

### 07. Node role labels crashed kubelet, and k3s with it \[Root cause\]

We read the live cluster's node labels and wrote them back into `config.yaml`, from where k3s passes them to kubelet as `--node-labels`. kubelet refuses labels in the `kubernetes.io` namespace outside a small permitted set, as a privilege-escalation guard, and the refusal is fatal rather than a warning:

``` bad
Error: failed to validate kubelet flags: unknown 'kubernetes.io' or
'k8s.io' labels specified with --node-labels:
[node-role.kubernetes.io/worker]
```

kubelet exited, k3s shut down with it, systemd restarted, 54 times. Those labels are genuinely present on every node, but they were applied with `kubectl label`, which is privileged. Reading state from a system does not tell you the interface it was written through, and we treated the two as interchangeable.

Diagnosis was slow because etcd came up healthy on every single cycle. The symptom pointed at the datastore we had just converted, which was the one thing that was fine.

**Fixed by** splitting node labels into those kubelet accepts and those it does not, passing only the former, and applying the rest with `kubectl label` once the node has registered.

### 08. kube-vip ran perfectly and did nothing \[Config\]

The static pod reported `1/1 Running` with zero restarts, and the virtual address never came up. Its own logs said why:

``` bad
error retrieving resource lock kube-system/plndr-cp-lock:
Get "https://kubernetes:6443/...": dial tcp: lookup kubernetes
on 1.1.1.1:53: no such host
```

kube-vip reaches the API server by the name `kubernetes`. As a host-network static pod it uses the host resolver, which has never heard of that name, and it starts before cluster DNS exists in any case. kube-vip's own documented manifest carries a `hostAliases` entry mapping that name to loopback. Ours, copied from the design document, did not.

**Fixed by** adding the alias. Separately, the manifest carried no pod labels, so the runbook's own verification step returned "No resources found" whether kube-vip was working or absent.

### 09. Version parsing had only ever run where k3s was already installed \[Tooling\]

The join failed on `opus` before touching it. `regex_search` returns nothing when it does not match, and the result was piped into `first` before the default that was meant to handle the empty case. It worked on `deus`, where the regex matched. Every genuinely new node, which is the case the repository exists to serve, hit the one path never exercised.

**Fixed by** matching without a capture group, then verifying against five cases including a fresh node and a node running ahead of the pin.

### 10. etcd snapshots to S3 failed on one word \[Backup\]

`k3s etcd-snapshot` returned `failed to test for existence of bucket k3s-etcd: 400 Bad Request`. The region was set to `garage`. The Garage instance is deliberately configured as `us-east-1`, to resolve an unrelated conflict with a Postgres backup client. SigV4 signs over the region, so a mismatch fails signature validation and surfaces as a malformed request rather than as a wrong region.

**Fixed by** reading the region straight off the endpoint, which returns it in the body of an anonymous error response, and recording why it holds that value so nobody corrects it back.

### 11. A restart handler fired seconds after the one-way conversion \[Design\]

The config template and the S3 drop-in both notified a restart handler, and handlers flush at the end of the roles section. The role had already started k3s with the correct configuration, so the handler contributed nothing and bounced the service moments after the datastore conversion completed. It did not cause the crash loop, but the same sequence during the join would have fired inside the two-member window.

**Fixed by** disarming the handler in the init and join playbooks. Steady-state runs keep it, because there it is the mechanism that loads a changed config, paced one server at a time.

## Reading the day back

### What went well

- The irreversible step worked first time and never needed its rollback.
- The netplan role's write, verify, restore sequence caught a real mismatch and put the node back untouched.
- Guards that refused to proceed did so before doing damage, not after.
- Both new servers joined in the same sitting, keeping the two-member window to a few minutes.

### What went badly

- Nine of eleven findings were defects in our own automation, not in k3s.
- Twenty minutes went into investigating etcd, which was healthy the entire time.
- Two checks reported success without establishing anything: a selector that matched no labels, and a config file written but not honoured.
- `no_log` hid the cause along with the secret, twice.

### Where we got lucky

- The crash loop happened with one etcd member. With two, a restarting member would have meant no quorum.
- The misconfigured etcd device on `sol` would have written a bad fstab entry, discovered at the next reboot.
- k3s agents load-balance across all servers on their own, so the agents were resilient earlier than we had assumed.

## Three that generalise

**Reading state does not tell you the interface it was written through.** Finding 7 is the whole day in one sentence. The labels were real, visible and correct. They simply could not be set the way we tried to set them.

**A check that cannot fail is not a check.** The kube-vip selector returned nothing whether the pod was healthy or missing. The netplan assert passed trivially in check mode because nothing had been written yet. Both read as verification and provided none.

**Run the thing in the foreground.** Twenty minutes of log archaeology ended the moment we stopped the service and started it by hand. The fatal line had been there all along, buried between restarts.

## Still open

| Item | Why | State |
|----|----|----|
| Test kube-vip reboot survival | Upstream issue 909 reports a static-pod kube-vip not restarting after a node reboot. Never exercised here. | Open |
| Test AC power recovery on `opus` | The BIOS is password-locked and cannot be inspected. Only a real power cut answers it. | Open |
| Move the join token to its own drop-in | `config.yaml` is mode 0600 because it holds the token, which makes the k3s CLI warn on every invocation. | Open |
| Enable the node-exporter textfile collector | The health role writes SMART metrics on all five nodes and nothing scrapes them. A GitOps-side change. | Open |
| Refresh the design document | Materially stale on host addresses, the virtual address, etcd devices, the S3 region, and the node-label trap. | Open |
| Rotate the join token | Exposed during diagnosis. Now a rolling operation across three servers rather than a single-node outage. | Open |

## Where it landed

Three etcd members on `deus`, `opus` and `sol`. A virtual address on `192.168.1.241` serving the API, with a certificate that covers it. Agents load-balancing across all three servers. Snapshots reaching Garage every six hours. Stopping k3s on the node that used to be the entire control plane now changes nothing anyone notices, which was the point of the exercise and is the only test that ever mattered.
