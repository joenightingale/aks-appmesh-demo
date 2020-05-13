$PropertyFilePath=".\input.properties"
$RawProperties=Get-Content $PropertyFilePath;
$PropertiesToConvert=($RawProperties -replace '\\','\\') -join [Environment]::NewLine;
$Properties=ConvertFrom-StringData $PropertiesToConvert;

az aks delete --resource-group $Properties["RESOURCE_GROUP"] --name  $Properties["CLUSTER_NAME"] --yes
az network dns zone delete --resource-group $Properties["RESOURCE_GROUP"] --name $Properties["DNS_ZONE"] --yes
az group delete --name $Properties["RESOURCE_GROUP"] --yes