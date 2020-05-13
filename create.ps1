$PropertyFilePath=".\input.properties"
$RawProperties=Get-Content $PropertyFilePath;
$PropertiesToConvert=($RawProperties -replace '\\','\\') -join [Environment]::NewLine;
$Properties=ConvertFrom-StringData $PropertiesToConvert;

Set-Variable -Name "RESOURCE_GROUP" -Value  $Properties["RESOURCE_GROUP"]
Set-Variable -Name "AZURE_REGION" -Value    $Properties["AZURE_REGION"]
Set-Variable -Name "CLUSTER_NAME" -Value    $Properties["CLUSTER_NAME"]
Set-Variable -Name "DNS_ZONE" -Value        $Properties["DNS_ZONE"]
Set-Variable -Name "ACME_EMAIL" -Value      $Properties["ACME_EMAIL"]

Get-Content cluster-issuer.yaml | sed "s/ACME_EMAIL/$ACME_EMAIL/g" > cluster-issuer-$RESOURCE_GROUP.yaml
Get-Content kubernetes-dashboard-ingress.yaml| sed "s/DNS_ZONE/$DNS_ZONE/g" >  kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
Get-Content kiali-ingress.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  kiali-ingress-$RESOURCE_GROUP.yaml
Get-Content api-gateway-deployment-external-elasticsearch.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
Get-Content nodetours.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  nodetours-$RESOURCE_GROUP.yaml

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

if ((Get-Command "az" -ErrorAction SilentlyContinue) -eq $null) 
{ 
  Write-Output "****************************************************"
  Write-Output "Please download and install the Azure CLI from: "
  Write-Output "https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest"
  Write-Output ""
  Write-Output "Rerun this command when done."
  Write-Output "****************************************************"
  exit
}
if ((Get-Command "istioctl" -ErrorAction SilentlyContinue) -eq $null) 
{ 
  Write-Output "****************************************************"
  Write-Output "Please download the latest Istio Archive from: "
  Write-Output "https://github.com/istio/istio/releases/download/1.5.2/istio-1.5.2-win.zip"
  Write-Output "unzip it somewhere and add the bin folder to your path"
  Write-Output ""
  Write-Output "Rerun this command when done."
  Write-Output "****************************************************"
  exit
}
  
Write-Output "Logging into Azure"
az login
if ((Get-Command "kubectl" -ErrorAction SilentlyContinue) -eq $null) 
{ 
  Write-Output "Installing kubectl"
  az aks install-cli
  Write-Output "Rerun this command when done."
  exit
}

Write-Output "Checking that the API Gateway and Microgateway images are present"
if (($(docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/microgateway-trial/ { print $2 }') -ne "10.5.0.2") -or
    ($(docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/apigateway-trial/ { print $2 }') -ne "10.5.0.2"))
{
  if ($(ping -n 1 daerepository03.eur.ad.sag | awk '/Reply from/ { print $1 }') -ne "Reply")
  {
    Write-Output "******************************************************************************"
    Write-Output "Please connect to the VPN to pull the API Gateway & Microgateway docker images"
    Write-Output "******************************************************************************"
    exit
  }
  Write-Output "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2
  Write-Output "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2
}

Write-Output "Creating Azure Resource Group: $RESOURCE_GROUP"
az group create --name $RESOURCE_GROUP --location $AZURE_REGION
Write-Output "Creating DNS Zone: $DNS_ZONE in Azure"
az network dns zone create --resource-group $RESOURCE_GROUP --name $DNS_ZONE
Write-Output "****************************************************"
Write-Output "Please ensure your DNS registrar now points $DNS_ZONE to the Azure NameServers above"
Write-Output "****************************************************"
pause "Press any key to continue, when this is done"
Write-Output "Creating AZK Cluster: $CLUSTER_NAME"
az aks create --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --node-count 2 --enable-addons monitoring --generate-ssh-keys
Write-Output "Adding AZK Cluster credentials to Kube Config"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing
kubectl config use-context $CLUSTER_NAME
Write-Output "Listing AZK Cluster nodes"
kubectl get nodes

Write-Output "Creating nginx-ingress namespace"
kubectl create namespace nginx-ingress
kubectl config set-context --current --namespace=nginx-ingress
Write-Output "Adding nginx-ingress repoo to helm"
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
Write-Output "Refreshing helm repoos"
helm repo update
Write-Output "Installing nginx-ingress using helm"
helm install nginx-ingress stable/nginx-ingress  -n nginx-ingress --wait
Write-Output "Getting nginx-ingress IP Address"
Set-Variable -Name "IP_INGRESS" -Value $(kubectl get service -l app=nginx-ingress -n nginx-ingress | grep nginx-ingress-controller | awk '{print $4}')
Write-Output "Removing any old DNS references from Azure DNS Zone"
az network dns record-set a delete --yes --resource-group $RESOURCE_GROUP --zone-name $DNS_ZONE --name '*'
Write-Output "Pointing *.$DNS_ZONE to nginx-ingress: $IP_INGRESS"
az network dns record-set a add-record --resource-group $RESOURCE_GROUP --zone-name $DNS_ZONE --record-set-name '*'  --ipv4-address $IP_INGRESS
do
{
  Set-Variable -Name "IP_CURRENT" -Value $(ping -n 1 harbor.$DNS_ZONE | grep harbor.$DNS_ZONE | sed 's/^[^[]*\\[\\([^\\]\*\\)\\].*$/\\1/')
  Start-Sleep 30
  Write-Output "Waiting for DNS names to progagate... ($IP_INGRESS - $IP_CURRENT)"  
} While ($IP_INGRESS -ne $IP_CURRENT)
Write-Output "DNS names progagated..."
kubectl label namespace nginx-ingress cert-manager.io/disable-validation=true
Write-Output "Adding cert-manager repoo to helm"
helm repo add jetstack https://charts.jetstack.io
Write-Output "Refreshing helm repoos"
helm repo update
Write-Output "Installing cert-manager using helm"
helm install cert-manager --version v0.13.0  jetstack/cert-manager --wait
Write-Output "Wait for cert-manager to be ready..."
Start-Sleep 60
Write-Output "Creating letsencrypt ClusterIssuer"
kubectl apply -f cluster-issuer-$RESOURCE_GROUP.yaml
Write-Output "Install kubernetes-dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml
kubectl config set-context --current --namespace=kubernetes-dashboard
Write-Output "Create admin-sa service account"
kubectl create serviceaccount dashboard-admin-sa
Write-Output "Bind admin-sa service account to cluster-admin ClusterRole"
kubectl create clusterrolebinding dashboard-admin-sa --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:dashboard-admin-sa
Write-Output "Get login token secret for admin-sa"
Set-Variable -Name "TOKEN_SECRET" -Value $(kubectl get secret | awk '/dashboard-admin-sa-token-/ { print $1 }')
Write-Output "Describe login token secret for admin-sa"
kubectl describe secret $TOKEN_SECRET
Write-Output "Create kubernetes-dashboard ingress on address: kubernetes-dashboard.$DNS_ZONE"
kubectl apply -f kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/kubernetes-dashboard-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for Kubernetes-Dashboard certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

Write-Output "Create registries namespace..."
kubectl create namespace registries
kubectl config set-context --current --namespace=registries
Write-Output "Install harbor using helm"
helm install harbor bitnami/harbor --set service.type=Ingress --set service.ingress.hosts.core=harbor.$DNS_ZONE --set service.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt --set service.ingress.annotations.'kubernetes\.io/ingress\.class'=nginx --set externalURL=https://harbor.$DNS_ZONE --set service.tls.secretName=bitnami-harbor-ingress-cert --set notary.enabled=false --wait
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/bitnami-harbor-ingress-cert/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for Harbor certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

Write-Output Password: $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -i -d)

Write-Output "Push API Gateway and API Microgateway to harbor"
Write-Output $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -i -d) | docker login -u admin --password-stdin harbor.$DNS_ZONE/library
docker tag daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker tag daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2

Write-Output "Install istio"
istioctl manifest apply --set profile=demo
Write-Output "Create Kiali ingress"
kubectl apply -f .\kiali-ingress-$RESOURCE_GROUP.yaml -n istio-system
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate -n istio-system | awk '/kiali-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for Kiali certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

Write-Output "Create registries namespace..."
kubectl create namespace monitoring
kubectl config set-context --current --namespace=monitoring
Write-Output "Installing Elastic DaemonSet to ensure ulimits increased"
kubectl apply -f .\es-sysctl-ds.yaml
Write-Output "Installing Elastic Search"
kubectl apply -f .\elasticsearch.yaml

Write-Output "Create nodetours namespace..."
kubectl create namespace nodetours
kubectl config set-context --current --namespace=nodetours
Write-Output "Disabling istio injection on the nodetours namespace before installing API Gateway installation"
kubectl label namespace nodetours istio-injection=disabled --overwrite=true
Write-Output "Installing API Gateway"
kubectl apply -f .\api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/api-gateway-tls-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for nodetours certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."
Write-Output "Checking status of API Gateway pods"
kubectl get pods

Write-Output "Enabling istio injection on nodetours namespace"
kubectl label namespace nodetours istio-injection=enabled --overwrite=true
Write-Output "Installing nodetours demo"
kubectl apply -f .\nodetours-$RESOURCE_GROUP.yaml
Write-Output "Checking status of Nodetours demo pods"
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/nodetours-tls-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for nodetours certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."
kubectl get pods