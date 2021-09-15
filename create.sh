#!/bin/zsh
#
 
file="./input.properties"

if [  -f "$file" ]
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
exit 1

cat cluster-issuer.yaml | sed "s/ACME_EMAIL/$ACME_EMAIL/g" > cluster-issuer-$RESOURCE_GROUP.yaml
cat kubernetes-dashboard-ingress.yaml| sed "s/DNS_ZONE/$DNS_ZONE/g" >  kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
cat kiali-ingress.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  kiali-ingress-$RESOURCE_GROUP.yaml
cat api-gateway-deployment-external-elasticsearch.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
cat nodetours.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  nodetours-$RESOURCE_GROUP.yaml

Function pause ($message)
{
    # Check if running Powershell ISE
    if ($psISE)
    {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$message")
    }
    else
    {
        Write-Host "$message" -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

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
  
echo "Logging into Azure"
az login
if ((Get-Command "kubectl" -ErrorAction SilentlyContinue) -eq $null) 
{ 
  echo "Installing kubectl"
  az aks install-cli
  echo "Rerun this command when done."
  exit
}

echo "Checking that the API Gateway and Microgateway images are present"
if (($(docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/microgateway-trial/ { print $2 }') -ne "10.5.0.2") -or
    ($(docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/apigateway-trial/ { print $2 }') -ne "10.5.0.2"))
{
  if ($(ping -n 1 daerepository03.eur.ad.sag | awk '/Reply from/ { print $1 }') -ne "Reply")
  {
    echo "******************************************************************************"
    echo "Please connect to the VPN to pull the API Gateway & Microgateway docker images"
    echo "******************************************************************************"
    exit
  }
  echo "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2
  echo "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2
}

echo "Creating Azure Resource Group: $RESOURCE_GROUP"
az group create --name $RESOURCE_GROUP --location $AZURE_REGION
echo "Creating DNS Zone: $DNS_ZONE in Azure"
az network dns zone create --resource-group $RESOURCE_GROUP --name $DNS_ZONE
echo "****************************************************"
echo "Please ensure your DNS registrar now points $DNS_ZONE to the Azure NameServers above"
echo "****************************************************"
pause "Press any key to continue, when this is done"
echo "Creating AZK Cluster: $CLUSTER_NAME"
az aks create --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --node-count 2 --enable-addons monitoring --generate-ssh-keys
echo "Adding AZK Cluster credentials to Kube Config"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing
kubectl config use-context $CLUSTER_NAME
echo "Listing AZK Cluster nodes"
kubectl get nodes

echo "Creating nginx-ingress namespace"
kubectl create namespace nginx-ingress
kubectl config set-context --current --namespace=nginx-ingress
echo "Adding nginx-ingress repoo to helm"
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
echo "Refreshing helm repoos"
helm repo update
echo "Installing nginx-ingress using helm"
helm install nginx-ingress stable/nginx-ingress  -n nginx-ingress --wait
echo "Getting nginx-ingress IP Address"
Set-Variable -Name "IP_INGRESS" -Value $(kubectl get service -l app=nginx-ingress -n nginx-ingress | grep nginx-ingress-controller | awk '{print $4}')
echo "Removing any old DNS references from Azure DNS Zone"
az network dns record-set a delete --yes --resource-group $RESOURCE_GROUP --zone-name $DNS_ZONE --name '*'
echo "Pointing *.$DNS_ZONE to nginx-ingress: $IP_INGRESS"
az network dns record-set a add-record --resource-group $RESOURCE_GROUP --zone-name $DNS_ZONE --record-set-name '*'  --ipv4-address $IP_INGRESS
do
{
  Set-Variable -Name "IP_CURRENT" -Value $(ping -n 1 harbor.$DNS_ZONE | grep harbor.$DNS_ZONE | sed 's/^[^[]*\\[\\([^\\]\*\\)\\].*$/\\1/')
  Start-Sleep 30
  echo "Waiting for DNS names to progagate... ($IP_INGRESS - $IP_CURRENT)"  
} While ($IP_INGRESS -ne $IP_CURRENT)
echo "DNS names progagated..."
kubectl label namespace nginx-ingress cert-manager.io/disable-validation=true
echo "Adding cert-manager repoo to helm"
helm repo add jetstack https://charts.jetstack.io
echo "Refreshing helm repoos"
helm repo update
echo "Installing cert-manager using helm"
helm install cert-manager  jetstack/cert-manager --wait
echo "Wait for cert-manager to be ready..."
Start-Sleep 60
echo "Creating letsencrypt ClusterIssuer"
kubectl apply -f cluster-issuer-$RESOURCE_GROUP.yaml
echo "Install kubernetes-dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml
kubectl config set-context --current --namespace=kubernetes-dashboard
echo "Create admin-sa service account"
kubectl create serviceaccount dashboard-admin-sa
echo "Bind admin-sa service account to cluster-admin ClusterRole"
kubectl create clusterrolebinding dashboard-admin-sa --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:dashboard-admin-sa
echo "Get login token secret for admin-sa"
Set-Variable -Name "TOKEN_SECRET" -Value $(kubectl get secret | awk '/dashboard-admin-sa-token-/ { print $1 }')
echo "Describe login token secret for admin-sa"
kubectl describe secret $TOKEN_SECRET
echo "Create kubernetes-dashboard ingress on address: kubernetes-dashboard.$DNS_ZONE"
kubectl apply -f kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/kubernetes-dashboard-secret/ { print $2 }')
  Start-Sleep 30
  echo "Waiting for Kubernetes-Dashboard certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
echo "Certificate ready..."

echo "Create registries namespace..."
kubectl create namespace registries
kubectl config set-context --current --namespace=registries
echo "Install harbor using helm"
helm install harbor bitnami/harbor --set service.type=Ingress --set service.ingress.hosts.core=harbor.$DNS_ZONE --set service.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt --set service.ingress.annotations.'kubernetes\.io/ingress\.class'=nginx --set externalURL=https://harbor.$DNS_ZONE --set service.tls.secretName=bitnami-harbor-ingress-cert --set notary.enabled=false --wait
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/bitnami-harbor-ingress-cert/ { print $2 }')
  Start-Sleep 30
  echo "Waiting for Harbor certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
echo "Certificate ready..."

echo Password: $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -i -d)

echo "Push API Gateway and API Microgateway to harbor"
echo $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -i -d) | docker login -u admin --password-stdin harbor.$DNS_ZONE/library
docker tag daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker tag daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2

echo "Install istio"
istioctl manifest apply --set profile=demo
echo "Create Kiali ingress"
kubectl apply -f .\kiali-ingress-$RESOURCE_GROUP.yaml -n istio-system
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate -n istio-system | awk '/kiali-secret/ { print $2 }')
  Start-Sleep 30
  echo "Waiting for Kiali certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
echo "Certificate ready..."

echo "Create registries namespace..."
kubectl create namespace monitor
kubectl config set-context --current --namespace=monitor
echo "Installing Elastic DaemonSet to ensure ulimits increased"
kubectl apply -f .\es-sysctl-ds.yaml
echo "Installing Elastic Search"
kubectl apply -f .\elasticsearch.yaml

echo "Create nodetours namespace..."
kubectl create namespace nodetours
kubectl config set-context --current --namespace=nodetours
echo "Disabling istio injection on the nodetours namespace before installing API Gateway installation"
kubectl label namespace nodetours istio-injection=disabled --overwrite=true
echo "Installing API Gateway"
kubectl apply -f .\api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/api-gateway-tls-secret/ { print $2 }')
  Start-Sleep 30
  echo "Waiting for nodetours certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
echo "Certificate ready..."
echo "Checking status of API Gateway pods"
kubectl get pods

echo "Enabling istio injection on nodetours namespace"
kubectl label namespace nodetours istio-injection=enabled --overwrite=true
echo "Installing nodetours demo"
kubectl apply -f .\nodetours-$RESOURCE_GROUP.yaml
echo "Checking status of Nodetours demo pods"
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/nodetours-tls-secret/ { print $2 }')
  Start-Sleep 30
  echo "Waiting for nodetours certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
echo "Certificate ready..."
kubectl get pods
