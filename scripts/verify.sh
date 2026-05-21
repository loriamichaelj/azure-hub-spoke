#!/bin/bash
# verify.sh — proves the deployed lab actually behaves as a hub-and-spoke topology.
#
# Each section asserts one property from the project thesis:
#   [1] Hub connectivity   — every spoke VNet peers with the hub
#   [2] Spoke isolation    — spokes have NO direct path to each other
#   [3] Security boundary  — NSGs restrict SSH ingress to known sources
#   [4] No public exposure — only the jump host is internet-facing
#   [5] Data-plane         — live traffic confirms the above end to end
#
# Sections 1-4 are control-plane checks (ARM queries): fast, deterministic,
# runnable any time. Section 5 needs the VMs running and SSH reachable; it is
# skipped (not failed) when the environment can't support it.
#
# Usage: ./verify.sh [--no-ssh]
# Exit:  0 = all passed, 1 = one or more failed, 2 = preconditions not met.

set -uo pipefail

RG=rg-hubspoke-lab
HUB_MGMT_CIDR=10.0.2.0/24
KEY="${SSH_KEY:-$HOME/.ssh/azure_lab}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

RUN_SSH=yes
case "${1:-}" in
  --no-ssh)  RUN_SSH=no ;;
  -h|--help) echo "usage: $0 [--no-ssh]"; exit 0 ;;
  "")        ;;
  *)         echo "unknown option: $1" >&2; exit 2 ;;
esac

if [ -t 1 ]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_SKIP=$'\033[33m'; C_NOTE=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_PASS=; C_FAIL=; C_SKIP=; C_NOTE=; C_OFF=
fi

PASS=0; FAIL=0; SKIP=0

report() {  # desc, ok(0|1), detail-on-fail
  if [ "$2" = 0 ]; then
    printf "  ${C_PASS}PASS${C_OFF}  %s\n" "$1"; PASS=$((PASS+1))
  else
    printf "  ${C_FAIL}FAIL${C_OFF}  %s\n" "$1"; PASS=$PASS
    [ -n "${3:-}" ] && printf "        %s\n" "$3"
    FAIL=$((FAIL+1))
  fi
}
expect()        { if [ "$2" = "$3" ]; then report "$1" 0; else report "$1" 1 "expected '$2', got '$3'"; fi; }
assert_empty()    { if [ -z "$2" ]; then report "$1" 0; else report "$1" 1 "expected empty, got '$2'"; fi; }
assert_nonempty() { if [ -n "$2" ]; then report "$1" 0; else report "$1" 1 "value was empty"; fi; }
skip()          { printf "  ${C_SKIP}SKIP${C_OFF}  %s\n" "$1"; SKIP=$((SKIP+1)); }
note()          { printf "  ${C_NOTE}note${C_OFF}  %s\n" "$1"; }

peering_state() {  # vnet, peering-name
  az network vnet peering show -g "$RG" --vnet-name "$1" -n "$2" --query peeringState -o tsv 2>/dev/null
}
nsg_of_subnet() {  # vnet, subnet -> short NSG name
  local id
  id=$(az network vnet subnet show -g "$RG" --vnet-name "$1" -n "$2" --query networkSecurityGroup.id -o tsv 2>/dev/null)
  printf '%s' "${id##*/}"
}
load_rule() {  # nsg, rule -> sets r_access r_dir r_port r_src r_prio
  # `-o tsv` of a JSON array prints one element per line, so read line by line.
  local out
  out=$(az network nsg rule show -g "$RG" --nsg-name "$1" -n "$2" \
        --query '[access,direction,destinationPortRange,sourceAddressPrefix,priority]' -o tsv 2>/dev/null)
  { read -r r_access; read -r r_dir; read -r r_port; read -r r_src; read -r r_prio; } <<<"$out"
}
ssh_jump() {  # target-ip, command... — runs command on target via the jump host
  # Explicit ProxyCommand so the jump-host hop also uses $KEY; -J only keys the destination.
  local target=$1; shift
  ssh $SSH_OPTS -i "$KEY" \
    -o ProxyCommand="ssh $SSH_OPTS -i $KEY -W %h:%p azureuser@$JUMP_IP" \
    "azureuser@$target" "$@"
}

if [ "$(az group exists -n "$RG" 2>/dev/null)" != "true" ]; then
  echo "ERROR: resource group '$RG' not found — run scripts/deploy.sh first." >&2
  exit 2
fi

echo "=================================================================="
echo "  Hub-and-spoke verification — $RG"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=================================================================="

echo
echo "[1/5] Hub connectivity — every spoke peers with the hub"
expect "hub  -> spoke-1 peering is Connected" Connected "$(peering_state vnet-hub hub-to-spoke1)"
expect "spoke-1 -> hub  peering is Connected" Connected "$(peering_state vnet-spoke-1 spoke1-to-hub)"
expect "hub  -> spoke-2 peering is Connected" Connected "$(peering_state vnet-hub hub-to-spoke2)"
expect "spoke-2 -> hub  peering is Connected" Connected "$(peering_state vnet-spoke-2 spoke2-to-hub)"

echo
echo "[2/5] Spoke isolation — spokes have no direct peering"
s2s1=$(az network vnet peering list -g "$RG" --vnet-name vnet-spoke-1 \
  --query "length([?contains(remoteVirtualNetwork.id, 'vnet-spoke-2')])" -o tsv 2>/dev/null)
expect "spoke-1 has no peering to spoke-2 (deliberate isolation)" 0 "${s2s1:-ERR}"
s2s2=$(az network vnet peering list -g "$RG" --vnet-name vnet-spoke-2 \
  --query "length([?contains(remoteVirtualNetwork.id, 'vnet-spoke-1')])" -o tsv 2>/dev/null)
expect "spoke-2 has no peering to spoke-1 (deliberate isolation)" 0 "${s2s2:-ERR}"

echo
echo "[3/5] Security boundary — NSGs restrict SSH ingress"
load_rule nsg-hub-mgmt AllowSSHFromMyIP
allow_src=$r_src; allow_prio=$r_prio
ok=1
if [ "$r_access" = Allow ] && [ "$r_port" = 22 ]; then
  case "$r_src" in */32) ok=0 ;; esac
fi
report "nsg-hub-mgmt: SSH allowed only from a single host (/32)" "$ok" "access=$r_access port=$r_port src=$r_src"

load_rule nsg-hub-mgmt DenySSHFromInternet
ok=1
if [ "$r_access" = Deny ] && [ "$r_port" = 22 ] && [ "$r_src" = Internet ] \
   && [ -n "${r_prio:-}" ] && [ -n "${allow_prio:-}" ] && [ "$r_prio" -gt "$allow_prio" ] 2>/dev/null; then
  ok=0
fi
report "nsg-hub-mgmt: SSH from the Internet denied below the /32 allow" "$ok" \
  "access=$r_access port=$r_port src=$r_src priority=$r_prio (allow=$allow_prio)"
expect "snet-hub-mgmt is protected by nsg-hub-mgmt" nsg-hub-mgmt "$(nsg_of_subnet vnet-hub snet-hub-mgmt)"

check_spoke() {  # vnet, subnet, nsg
  load_rule "$3" AllowSSHFromHub
  local ok=1
  if [ "$r_access" = Allow ] && [ "$r_port" = 22 ] && [ "$r_src" = "$HUB_MGMT_CIDR" ]; then ok=0; fi
  report "$3: SSH allowed only from the hub mgmt subnet ($HUB_MGMT_CIDR)" "$ok" \
    "access=$r_access port=$r_port src=$r_src"
  expect "$2 is protected by $3" "$3" "$(nsg_of_subnet "$1" "$2")"
}
check_spoke vnet-spoke-1 snet-spoke1-app nsg-spoke1-app
check_spoke vnet-spoke-2 snet-spoke2-app nsg-spoke2-app

my_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
if [ -n "$my_ip" ] && [ -n "${allow_src:-}" ]; then
  if [ "$allow_src" = "$my_ip/32" ]; then
    note "AllowSSHFromMyIP matches your current public IP ($my_ip)"
  else
    note "AllowSSHFromMyIP=$allow_src but your current IP is $my_ip — SSH from here will be denied"
  fi
fi

echo
echo "[4/5] No public exposure — only the jump host is internet-facing"
jump_pub=$(az vm show -d -g "$RG" -n vm-jump   --query publicIps  -o tsv 2>/dev/null)
sp1_pub=$( az vm show -d -g "$RG" -n vm-spoke1 --query publicIps  -o tsv 2>/dev/null)
sp2_pub=$( az vm show -d -g "$RG" -n vm-spoke2 --query publicIps  -o tsv 2>/dev/null)
SPOKE1_IP=$(az vm show -d -g "$RG" -n vm-spoke1 --query privateIps -o tsv 2>/dev/null)
SPOKE2_IP=$(az vm show -d -g "$RG" -n vm-spoke2 --query privateIps -o tsv 2>/dev/null)
JUMP_IP=$jump_pub
assert_nonempty "vm-jump has a public IP (the sole ingress point)" "$jump_pub"
assert_empty    "vm-spoke1 has no public IP (private-only)"        "$sp1_pub"
assert_empty    "vm-spoke2 has no public IP (private-only)"        "$sp2_pub"

echo
echo "[5/5] Data-plane — live traffic confirms reachability and isolation"
jump_power=$(az vm get-instance-view -g "$RG" -n vm-jump \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null)

if [ "$RUN_SSH" != yes ]; then
  skip "data-plane tests (--no-ssh specified)"
elif [ ! -f "$KEY" ]; then
  skip "data-plane tests (SSH key not found: $KEY)"
elif [ -z "$JUMP_IP" ]; then
  skip "data-plane tests (vm-jump has no public IP)"
elif [ "$jump_power" != "VM running" ]; then
  skip "data-plane tests (vm-jump is '${jump_power:-unknown}', not running)"
elif ! ssh $SSH_OPTS -i "$KEY" "azureuser@$JUMP_IP" true 2>/dev/null; then
  skip "data-plane tests (jump host $JUMP_IP unreachable on SSH — check NSG vs your current IP, and key $KEY)"
else
  if ssh_jump "$SPOKE1_IP" true 2>/dev/null; then
    report "jump host -> spoke-1 SSH works (centralized management)" 0; reach1=yes
  else
    report "jump host -> spoke-1 SSH works (centralized management)" 1 "SSH via jump failed"; reach1=no
  fi
  if ssh_jump "$SPOKE2_IP" true 2>/dev/null; then
    report "jump host -> spoke-2 SSH works (centralized management)" 0
  else
    report "jump host -> spoke-2 SSH works (centralized management)" 1 "SSH via jump failed"
  fi

  if [ "$reach1" = yes ]; then
    if ssh_jump "$SPOKE1_IP" "ping -c 2 -W 2 $SPOKE2_IP" >/dev/null 2>&1; then
      report "spoke-1 -> spoke-2 ICMP is blocked (spoke isolation)" 1 \
        "ping SUCCEEDED — spokes can reach each other, isolation is broken"
    else
      report "spoke-1 -> spoke-2 ICMP is blocked (spoke isolation)" 0
    fi
    if ssh_jump "$SPOKE1_IP" "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no azureuser@$SPOKE2_IP true" >/dev/null 2>&1; then
      report "spoke-1 -> spoke-2 SSH is blocked (spoke isolation)" 1 \
        "SSH SUCCEEDED — spokes can reach each other, isolation is broken"
    else
      report "spoke-1 -> spoke-2 SSH is blocked (spoke isolation)" 0
    fi
  else
    skip "spoke-1 -> spoke-2 ICMP isolation (spoke-1 not reachable to test from)"
    skip "spoke-1 -> spoke-2 SSH isolation (spoke-1 not reachable to test from)"
  fi
fi

echo
echo "=================================================================="
printf "  Result: ${C_PASS}%d passed${C_OFF}, ${C_FAIL}%d failed${C_OFF}, ${C_SKIP}%d skipped${C_OFF}\n" \
  "$PASS" "$FAIL" "$SKIP"
echo "=================================================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
