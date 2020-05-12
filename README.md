clone this repo

Edit the first four lines of the runsheet.ps1 for your configuration, then run it.

If you have not done so, it will ask you to install the Azure CLI and download the Istio archive

You will also need access to a DNS Domain so that you can point a subdomain at the Azure DNS Zone for handling access to the ingess.
e.g. if you have a domain: mydomain.com, you might choose the subdomain aks.mydomain.com This will be the DNS_ZONE in the runsheet.ps1
You will need to configure your DNS provider and point aks to the Azure DNS Zone Name Servers which will be displayed during the execution.
This should look something like:
  NS	aks	ns1-08.azure-dns.com	1 Hour	Edit
  NS	aks	ns2-08.azure-dns.net	1 Hour	Edit
  NS	aks	ns3-08.azure-dns.org	1 Hour	Edit
  NS	aks	ns4-08.azure-dns.info	1 Hour  Edit
With the exact ns addresses being those displayed during the execution of the runsheet.ps1

