#!/bin/bash
RG=rg-hubspoke-lab
az group delete -n $RG --yes --no-wait
echo "Tear-down initiated. Check portal in ~5 min."