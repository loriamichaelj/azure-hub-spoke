# Hub-and-Spoke Virtual Network Lab

A reproducible Azure hub-and-spoke network topology, deployed entirely from
Azure CLI scripts. Three VNets — one hub, two spokes — peered so that spokes
reach the hub but never each other. A single jump host in the hub is the only
internet-facing machine; every spoke VM is private-only and reachable solely
through it. The lab exists to demonstrate VNet peering, network segmentation,
NSG-based access control, and cost-disciplined cloud operation, and to leave
behind a verification suite that proves the topology behaves as designed.

## Architecture

[Hub and Spoke Network Topology Architecture Diagram](./assets/img/architecture.pdf)


```
                              Internet
                                 │
                          SSH, your IP /32 only
                                 │
                                 ▼
   ┌──────────────────────────────────────────────────────┐
   │  vnet-hub                              10.0.0.0/16    │
   │                                                       │
   │   ┌───────────────────────────────────────┐           │
   │   │ snet-hub-mgmt          10.0.2.0/24     │           │
   │   │   ┌───────────┐   nsg-hub-mgmt         │           │
   │   │   │  vm-jump   │  public IP (static)   │           │
   │   │   └─────┬─────┘                        │           │
   │   └─────────┼─────────────────────────────┘            │
   │   GatewaySubnet  10.0.255.0/27  (reserved, empty)      │
   └─────────────┼──────────────────────┬───────────────────┘
         peering  │                      │  peering
   ┌──────────────▼──────────┐  ┌────────▼─────────────────┐
   │ vnet-spoke-1 10.1.0.0/16│  │ vnet-spoke-2 10.2.0.0/16 │
   │  ┌────────────────────┐ │  │  ┌────────────────────┐  │
   │  │ snet-spoke1-app    │ │  │  │ snet-spoke2-app    │  │
   │  │ 10.1.1.0/24        │ │  │  │ 10.2.1.0/24        │  │
   │  │  ┌──────────────┐  │ │  │  │  ┌──────────────┐  │  │
   │  │  │  vm-spoke1   │  │ │  │  │  │  vm-spoke2   │  │  │
   │  │  │  private IP  │  │ │  │  │  │  private IP  │  │  │
   │  │  └──────────────┘  │ │  │  │  └──────────────┘  │  │
   │  └────────────────────┘ │  │  └────────────────────┘  │
   │  snet-spoke1-data       │  │  snet-spoke2-data        │
   │  10.1.2.0/24 (empty)    │  │  10.2.2.0/24 (empty)     │
   └─────────────┬───────────┘  └──────────┬───────────────┘
                 │     no peering, no route │
                 └────────────  ✗  ─────────┘
```

Traffic flows one way in: from the operator's machine, over SSH, to the jump
host's public IP — and nowhere else from the internet. To reach a spoke VM you
SSH to the jump host first, then hop to the spoke's private IP. The hub peers
with each spoke, so the jump host can reach both; the spokes are **not** peered
with each other, so a compromised spoke VM has no network path to its sibling.
GatewaySubnet and the two `*-data` subnets are carved out in the IP plan but
left empty — they reserve address space for later projects without costing
anything now.

## Design decisions

**Hub-and-spoke, not mesh or flat.** A flat network puts every VM in one
broadcast/trust domain; a full mesh means N×(N−1) peerings and no central
choke point. Hub-and-spoke gives a single, auditable place to put shared
services (here, the jump host) and a topology that scales by adding spokes
without touching existing ones.

**Jump host, not Azure Bastion.** Bastion Basic runs roughly $140/month —
5–6× this lab's entire budget. A single 1-vCPU jump-host VM teaches the same
concept (one hardened ingress point, no public IPs on workload VMs) for a few
dollars of running time. Bastion would be the right call in production; for a
learning lab it is pure cost with no extra lesson.

**No spoke-to-spoke peering.** This is a deliberate isolation boundary, not an
omission. The two spokes model separate workloads that should not be able to
reach each other; routing all legitimate cross-traffic through the hub is the
segmentation pattern the lab is meant to demonstrate. `verify.sh` asserts the
isolation in both the control plane (no peering) and the data plane (ping and
SSH between spokes fail).

**No Azure Firewall, no VPN/ExpressRoute gateway.** Azure Firewall is ~$900/mo;
a gateway is out of scope for a self-contained lab. GatewaySubnet is reserved
so the IP plan is gateway-ready, but nothing is deployed into it.

**IP plan.** Each VNet gets a clean /16 (`10.0`, `10.1`, `10.2`) so spaces
never overlap — overlapping ranges make peering impossible. Subnets are /24s
with an obvious role-based name (`-mgmt`, `-app`, `-data`). The third octet
is left sparse on purpose: `snet-hub-mgmt` is `10.0.2.0/24`, leaving `10.0.0`
and `10.0.1` free for future hub subnets (e.g. a Bastion subnet) without
renumbering.

## NSG rules

NSGs are associated at the **subnet** level. Lower priority numbers are
evaluated first; the first matching rule wins, and Azure's built-in default
rules (deny inbound from internet, allow intra-VNet) sit below everything here.

### `nsg-hub-mgmt` — on `snet-hub-mgmt`

| Pri | Name | Dir | Access | Proto | Source | Dest port | Why |
|-----|------|-----|--------|-------|--------|-----------|-----|
| 100 | AllowSSHFromMyIP | Inbound | Allow | TCP | *your public IP* `/32` | 22 | Only the operator's current machine can open SSH to the jump host. The `/32` is filled in at deploy time from `curl ifconfig.me`. |
| 200 | DenySSHFromInternet | Inbound | Deny | TCP | Internet | 22 | Explicit backstop directly below the allow. Azure's defaults would already deny this, but stating it makes the "deny by default" intent visible and auditable. |

### `nsg-spoke1-app` — on `snet-spoke1-app`  ·  `nsg-spoke2-app` — on `snet-spoke2-app`

| Pri | Name | Dir | Access | Proto | Source | Dest port | Why |
|-----|------|-----|--------|-------|--------|-----------|-----|
| 100 | AllowSSHFromHub | Inbound | Allow | TCP | `10.0.2.0/24` | 22 | SSH to a spoke VM is permitted **only** from the hub management subnet. This forces every admin session through the jump host — there is no other path in. |

Everything not matched falls through to Azure's implicit deny-all inbound. The
`*-data` subnets have no NSG and no VMs; they sit at VNet defaults, reserved
for future use.

## Deploy

```sh
# Prereqs (one time)
az login                                          # Azure CLI authenticated
ssh-keygen -t ed25519 -f ~/.ssh/azure_lab         # lab-dedicated keypair

# Deploy
bash scripts/deploy.sh
```

`scripts/deploy.sh` creates everything in resource group `rg-hubspoke-lab` in
`westus2`: three VNets and their subnets, four peerings (both directions), three
NSGs, three `Standard_F1als_v7` Ubuntu 22.04 VMs, and a static public IP on the
jump host. It reads your current public IP at runtime for the NSG allow rule
(nothing is hardcoded into git) and sets auto-shutdown at 02:00 UTC on all three
VMs as a billing safety net.

VM private/public IPs are assigned dynamically — re-query them after any
deploy rather than assuming last run's values:

```sh
export RG=rg-hubspoke-lab
az vm show -d -g "$RG" -n vm-jump --query publicIps -o tsv
```

## Verify

`scripts/verify.sh` is a 20-test suite in five sections, each asserting one
property of the hub-and-spoke thesis:

```sh
./scripts/verify.sh            # full run, including live data-plane SSH/ICMP tests
./scripts/verify.sh --no-ssh   # control-plane only (runs even with VMs deallocated)
```

| Section | Asserts | Plane |
|---------|---------|-------|
| 1. Hub connectivity | every spoke VNet peering is `Connected` | control |
| 2. Spoke isolation | no spoke-to-spoke peering exists | control |
| 3. Security boundary | NSG SSH rules match the design above | control |
| 4. No public exposure | only `vm-jump` has a public IP | control |
| 5. Data-plane | jump→spoke SSH works; spoke→spoke ping/SSH fails | data |

Sections 1–4 are ARM queries — fast, deterministic, runnable any time.
Section 5 needs the VMs running and the jump host reachable; it **skips**
(rather than fails) when those preconditions aren't met. Exit codes:
`0` all passed, `1` one or more failed, `2` preconditions not met
(e.g. resource group missing).

Expected output against a healthy, running lab:

```
  Result: 20 passed, 0 failed, 0 skipped
```

## Cost

The compute is cheap *per hour*; the discipline is destroying it when idle.

| State | What still bills | Approx cost |
|-------|------------------|-------------|
| Running | 3× `F1als_v7` compute + disks + public IP | ~$0.18/hr (≈ $132/mo if left on 24/7) |
| Deallocated (VMs stopped) | 3× 30 GB StandardSSD disks + static public IP | ~$10–12/mo |
| Destroyed (`destroy.sh`) | nothing | ~$0 |

A typical ~3-hour test session costs about **$0.55**. A budget alert is set at
**$25/month** in Azure Cost Management. The takeaway: auto-shutdown caps
runaway compute, but stopped VMs still bill for disks and the reserved public
IP — the only true all-stop is to tear the lab down:

```sh
bash scripts/destroy.sh        # az group delete — back to ~$0
```

## Known limitations

- **Home IP rotation breaks SSH access.** `nsg-hub-mgmt` allows SSH only from
  the public IP captured at deploy time. When your ISP rotates that address,
  the jump host becomes unreachable. `verify.sh` detects and reports the
  mismatch. Fix: update the rule in place —
  `az network nsg rule update -g rg-hubspoke-lab --nsg-name nsg-hub-mgmt -n AllowSSHFromMyIP --source-address-prefixes "$(curl -4 -s ifconfig.me)/32"` —
  or re-run `deploy.sh`.
- **No outbound internet on spoke VMs.** Spoke VMs have no public IP, NAT
  gateway, or load balancer, and Azure is retiring default outbound access for
  VMs created after 2025-09-30. A NAT gateway (~$32/mo) would fix this but
  blow the budget; for this lab, private-only outbound is accepted.
- **No HA, no backup, no monitoring.** Single VM per role, no availability
  zones, no Recovery Services vault, no alerting. Observability is the subject
  of a later project.
- **Single region.** Everything is in `westus2`; there is no geo-redundancy.

## Lessons learned

The hardest part of this project was not networking — it was capacity. The
first deploy failed with `QuotaExceeded`, and the instinctive fix, hop to
another region, was wrong: the subscription's "Total Regional vCPUs" quota is
**4 in every nearby region**, a subscription-wide cap. The second instinct,
fall back to the cheap default `B1s`, was also wrong: `B1s` isn't offered in
`westus2` at all, and every B-series *v2* size has a 2-vCPU floor, so three of
them need 6 cores. The topology had to be designed around a 1-vCPU SKU
(`Standard_F1als_v7`) from the start. The lesson: confirm SKU availability and
quota in the *actual target region* before committing to a VM size — capacity
is a design constraint, not a deployment detail.

Cloud CLIs lie about their own errors. The real `QuotaExceeded` was buried
under a Python traceback — `RuntimeError: The content for this response was
already consumed` and a `NoneType` attribute error — that had nothing to do
with the cause. Time was lost debugging the traceback instead of the API
response underneath it. The lesson: when a cloud CLI throws an internal
error, ignore the stack trace and dig for the underlying service error.

Verification turned out to be the most valuable deliverable. Writing
`verify.sh` forced vague claims into concrete assertions: "the spokes are
isolated" became four checks — no peering in either direction, plus ICMP and
SSH both failing across the data plane. Two genuine bugs surfaced only when
the script ran live: `az ... --query '[a,b,c]' -o tsv` prints one value *per
line*, not tab-separated, and `ssh -J` does not pass `-i <key>` to the
jump-host hop. Both would have gone unnoticed without an end-to-end test. And
the cost work made the budget real: this lab is genuinely cheap only with a
deploy-test-destroy rhythm — left running, it is 5× over budget. A topology
diagram proves you can draw it; a passing verification suite and a torn-down
resource group prove you can operate it.
```

