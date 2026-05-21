# Hub-Spoke Lab — Build Log

## Session 1 — VM deployment + verification (2026-05-20 → 2026-05-21)

### Goal
Stand up the three lab VMs (vm-jump, vm-spoke1, vm-spoke2) on the
already-scaffolded hub-and-spoke network, then build a reproducible
verification suite.

### Blocker: VM deployment hit a core-quota wall
`az vm create` failed with `QuotaExceeded`. The real error was buried under
an Azure CLI bug — the visible traceback was
`RuntimeError: The content for this response was already consumed` plus
`AttributeError: 'NoneType' object has no attribute 'error'`. Ignore that
noise; the actual cause underneath it:

- The subscription has a hard **4-core "Total Regional vCPUs" quota** — and
  it is 4 in westus2, westus3, centralus, and westus alike. It is a
  subscription-wide cap, so **changing region does not help**.
- `Standard_B2ts_v2` is 2 vCPU. Three VMs = 6 cores > 4.
- First fix attempt, `Standard_B1s`, failed too: the legacy B-series 1-vCPU
  sizes are **not offered in westus2 at all** (`SkuNotAvailable` / capacity
  restriction). Every B-series *v2* size has a 2-vCPU minimum.

### Fix
Switched all three VMs to **`Standard_F1als_v7`** (1 vCPU) — the cheapest
unrestricted 1-vCPU size available in westus2. Three VMs = 3 cores, which
fits the quota with one core of headroom.

### Cost note
`F1als_v7` is $0.0605/hr each → $0.18/hr for all three. A ~3-hour test
session is roughly $0.55. Left running 24/7 it is ~$132/mo — well over the
$25 budget — so deploy-test-destroy plus auto-shutdown is mandatory, not
optional.

### Deploy sequence used
1. `az group delete -n rg-hubspoke-lab --yes --no-wait` — wipe the partial deploy
2. Edit `scripts/deploy.sh`: VM size `Standard_B1s` → `Standard_F1als_v7`
3. `bash scripts/deploy.sh` — clean run, all three VMs created

### Deployed state
IPs are dynamic — re-query after any redeploy; values below are from the
2026-05-21 redeploy.

| VM        | Subnet          | Private IP | Public IP     |
|-----------|-----------------|------------|---------------|
| vm-jump   | snet-hub-mgmt   | 10.0.2.4   | 20.29.193.188 |
| vm-spoke1 | snet-spoke1-app | 10.1.1.4   | — (private)   |
| vm-spoke2 | snet-spoke2-app | 10.2.1.4   | — (private)   |

### Verification: scripts/verify.sh (new)
A 20-test suite in five sections, each mapped to a property of the
hub-and-spoke thesis:

1. Hub connectivity — every spoke peers with the hub (4 tests)
2. Spoke isolation — no spoke-to-spoke peering (2 tests)
3. Security boundary — NSG SSH ingress rules (7 tests)
4. No public exposure — only the jump host is internet-facing (3 tests)
5. Data-plane — live SSH/ICMP reachability and isolation (4 tests)

Sections 1-4 are control-plane (ARM queries, runnable any time, even with
VMs deallocated). Section 5 is data-plane and auto-skips — rather than
fails — when the VMs are off or the jump host is unreachable.
`./verify.sh` exits 0/1/2; `./verify.sh --no-ssh` runs config-only.

Two bugs found and fixed during the first live run:
- `az --query '[a,b,c]' -o tsv` prints one element per *line*, not
  tab-separated — the parser was reading only the first field.
- `ssh -J` does not pass `-i <key>` to the jump-host hop (only to the
  destination) — replaced with an explicit `ProxyCommand`.

Final result: **20 passed, 0 failed, 0 skipped.**

### Reference commands
```bash
# connect to the lab
export RG=rg-hubspoke-lab
export JUMP_IP=$(az vm show -d -g "$RG" -n vm-jump --query publicIps -o tsv)
ssh -i ~/.ssh/azure_lab azureuser@"$JUMP_IP"

# verify the topology
./scripts/verify.sh

# tear down (back to ~$0)
bash scripts/destroy.sh
```

### Open items
- `scripts/deploy.sh` and `scripts/verify.sh` changes are uncommitted.
- If `verify.sh` reports that `AllowSSHFromMyIP` no longer matches your
  current public IP, re-run `deploy.sh` or update the NSG rule — your home
  IP has drifted.
