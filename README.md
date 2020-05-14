This sample automated the creation of an Azure AKS Cluster installed with all of the necessary components to demo the AppMesh API Gateway capability.

# Prerequisites
You will need the following:
* Docker Desktop
* An Azure account
* Azure Command Line Interface installed
* Istioctl exe in the path
* helm exe in the path
* A domain name so that a subdomain can be redirected to the Azure name servers

# Instructions
clone this repo
Edit the input.properties file for your configuration
Run the .\create.ps1

If you do nor already have the API Gateway and API Microgateway docker images pulled, you will need to be on the corporate network or VPN for the script to be able to pull them:
```daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2```
```daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2```

If you have not done so, it will ask you to install the Azure CLI and download the Istio archive

As listed above, you will also need access to a DNS Domain so that you can point a subdomain at the Azure DNS Zone for handling access to the ingess.
e.g. if you have a domain: mydomain.com, you might choose the subdomain aks.mydomain.com This will be the DNS_ZONE in the runsheet.ps1
You will need to configure your DNS provider and point aks to the Azure DNS Zone Name Servers which will be displayed during the execution.
This should look something like:
```NS	aks	ns1-08.azure-dns.com	1 Hour	Edit
NS	aks	ns2-08.azure-dns.net	1 Hour	Edit
NS	aks	ns3-08.azure-dns.org	1 Hour	Edit
NS	aks	ns4-08.azure-dns.info	1 Hour  Edit```
With the exact ns addresses being those displayed during the execution of the runsheet.ps1

To delete everything created from Azure run .\cleanup.ps1
