#!/bin/bash
set -euo pipefail

# Variables — edit these
LOCATION=westus2             # B1s capacity-restricted in eastus
RG=rg-hubspoke-lab
MY_IP=$(curl -4 -s ifconfig.me)/32
ADMIN_USER=azureuser
SSH_KEY_PATH=~/.ssh/azure_lab.pub  # generate with: ssh-keygen -t ed25519 -f ~/.ssh/azure_lab

# Resource group (single RG per brief)
az group create -n $RG -l $LOCATION --tags project=hubspoke-lab env=lab owner=$USER

# VNets and subnets
az network vnet create -g $RG -n vnet-hub --address-prefix 10.0.0.0/16 \
  --subnet-name snet-hub-mgmt --subnet-prefix 10.0.2.0/24
az network vnet subnet create -g $RG --vnet-name vnet-hub -n GatewaySubnet --address-prefix 10.0.255.0/27

az network vnet create -g $RG -n vnet-spoke-1 --address-prefix 10.1.0.0/16 \
  --subnet-name snet-spoke1-app --subnet-prefix 10.1.1.0/24
az network vnet subnet create -g $RG --vnet-name vnet-spoke-1 -n snet-spoke1-data --address-prefix 10.1.2.0/24

az network vnet create -g $RG -n vnet-spoke-2 --address-prefix 10.2.0.0/16 \
  --subnet-name snet-spoke2-app --subnet-prefix 10.2.1.0/24
az network vnet subnet create -g $RG --vnet-name vnet-spoke-2 -n snet-spoke2-data --address-prefix 10.2.2.0/24

# Peerings — both directions, explicitly
az network vnet peering create -g $RG -n hub-to-spoke1 --vnet-name vnet-hub \
  --remote-vnet vnet-spoke-1 --allow-vnet-access
az network vnet peering create -g $RG -n spoke1-to-hub --vnet-name vnet-spoke-1 \
  --remote-vnet vnet-hub --allow-vnet-access

az network vnet peering create -g $RG -n hub-to-spoke2 --vnet-name vnet-hub \
  --remote-vnet vnet-spoke-2 --allow-vnet-access
az network vnet peering create -g $RG -n spoke2-to-hub --vnet-name vnet-spoke-2 \
  --remote-vnet vnet-hub --allow-vnet-access

# NSGs
az network nsg create -g $RG -n nsg-hub-mgmt
az network nsg rule create -g $RG --nsg-name nsg-hub-mgmt -n AllowSSHFromMyIP \
  --priority 100 --source-address-prefixes $MY_IP --destination-port-ranges 22 \
  --access Allow --protocol Tcp --direction Inbound
az network nsg rule create -g $RG --nsg-name nsg-hub-mgmt -n DenySSHFromInternet \
  --priority 200 --source-address-prefixes Internet --destination-port-ranges 22 \
  --access Deny --protocol Tcp --direction Inbound

az network nsg create -g $RG -n nsg-spoke1-app
az network nsg rule create -g $RG --nsg-name nsg-spoke1-app -n AllowSSHFromHub \
  --priority 100 --source-address-prefixes 10.0.2.0/24 --destination-port-ranges 22 \
  --access Allow --protocol Tcp --direction Inbound

az network nsg create -g $RG -n nsg-spoke2-app
az network nsg rule create -g $RG --nsg-name nsg-spoke2-app -n AllowSSHFromHub \
  --priority 100 --source-address-prefixes 10.0.2.0/24 --destination-port-ranges 22 \
  --access Allow --protocol Tcp --direction Inbound

# Associate NSGs to subnets
az network vnet subnet update -g $RG --vnet-name vnet-hub -n snet-hub-mgmt --nsg nsg-hub-mgmt
az network vnet subnet update -g $RG --vnet-name vnet-spoke-1 -n snet-spoke1-app --nsg nsg-spoke1-app
az network vnet subnet update -g $RG --vnet-name vnet-spoke-2 -n snet-spoke2-app --nsg nsg-spoke2-app

# Jump host (B1s, Ubuntu, SSH key auth, public IP)
az vm create -g $RG -n vm-jump --image Ubuntu2204 --size Standard_B1s \
  --vnet-name vnet-hub --subnet snet-hub-mgmt \
  --admin-username $ADMIN_USER --ssh-key-values $SSH_KEY_PATH \
  --public-ip-sku Standard --public-ip-address-allocation Static \
  --os-disk-size-gb 30 --storage-sku StandardSSD_LRS

# Spoke test VMs (no public IP)
az vm create -g $RG -n vm-spoke1 --image Ubuntu2204 --size Standard_B1s \
  --vnet-name vnet-spoke-1 --subnet snet-spoke1-app \
  --admin-username $ADMIN_USER --ssh-key-values $SSH_KEY_PATH \
  --public-ip-address "" --os-disk-size-gb 30 --storage-sku StandardSSD_LRS

az vm create -g $RG -n vm-spoke2 --image Ubuntu2204 --size Standard_B1s \
  --vnet-name vnet-spoke-2 --subnet snet-spoke2-app \
  --admin-username $ADMIN_USER --ssh-key-values $SSH_KEY_PATH \
  --public-ip-address "" --os-disk-size-gb 30 --storage-sku StandardSSD_LRS

# Auto-shutdown — saves money, set for all three
for VM in vm-jump vm-spoke1 vm-spoke2; do
  az vm auto-shutdown -g $RG -n $VM --time 0200  # UTC 02:00 = US Pacific 18:00/19:00
done