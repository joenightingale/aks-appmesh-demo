#!/bin/bash
#
file="./input.properties"

if [  ! -f "$file" ]
then
  echo "$file not found."
  exit 1
fi

while IFS='=' read -r key value
do
  key=$(echo $key | tr '.' '_')
  eval ${key}=\${value}
done < "$file"

echo "RESOURCE_GROUP      = " ${RESOURCE_GROUP}
echo "AZURE_REGION        = " ${AZURE_REGION}

if ! type "az" > /dev/null; then
  echo "****************************************************"
  echo "Please download and install the Azure CLI from: "
  echo "https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest"
  echo ""
  echo "Rerun this command when done."
  echo "****************************************************"
  exit
fi

if ! type "istioctl" > /dev/null; then
  echo "****************************************************"
  echo "Please download the latest Istio Archive from: "
  echo "https://github.com/istio/istio/releases/download/1.5.2/istio-1.5.2-win.zip"
  echo "unzip it somewhere and add the bin folder to your path"
  echo ""
  echo "Rerun this command when done."
  echo "****************************************************"
  exit
fi

if ! type "helm" > /dev/null; then
  echo "****************************************************"
  echo "Please download the latest version of helm from: "
  echo "https://helm.sh/docs/intro/quickstart/"
  echo "and add the bin folder to your path"
  echo ""
  echo "Rerun this command when done."
  echo "****************************************************"
  exit
fi

echo "Logging into Azure"
az login --tenant $AZURE_TENANT

if ! type "kubectl" > /dev/null; then
  Write-Output "Installing kubectl"
  az aks install-cli
fi

