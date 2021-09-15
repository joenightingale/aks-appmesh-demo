#!/bin/bash
#
 
file="./input.properties"

if [ ! -f "$file" ]; then
  echo "$file not found."
  exit 1
fi

while IFS='=' read -r key value
do
  key=$(echo $key | tr '.' '_')
  eval "$key=$value"
done < "$file"

export CALLER_REF=$(date)

echo "RESOURCE_GROUP      = " ${RESOURCE_GROUP}
echo "AZURE_REGION        = " ${AZURE_REGION}

cat cluster-issuer.yaml | sed "s/ACME_EMAIL/$ACME_EMAIL/g" > cluster-issuer-$RESOURCE_GROUP.yaml
cat kubernetes-dashboard-ingress.yaml| sed "s/DNS_ZONE/$DNS_ZONE/g" >  kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
cat kiali-ingress.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  kiali-ingress-$RESOURCE_GROUP.yaml
cat api-gateway-deployment-external-elasticsearch.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
cat nodetours.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  nodetours-$RESOURCE_GROUP.yaml

function pause ()
{
        echo "$1"
        read x
}




if hash istioctl 2>/dev/null; then
  echo "****************************************************"
  echo "Please download the latest Istio Archive from: "
  echo "https://github.com/istio/istio/releases/download/1.6.3/istio-1.6.3-win.zip"
  echo "unzip it somewhere and add the bin folder to your path"
  echo ""
  echo "Rerun this command when done."
  echo "****************************************************"
  exit
fi
  
echo "Configuring AWS Connection properties"
aws configure

echo "Get AWS AIM ID"
export AWS_IAM_ID=`aws iam get-user | awk '/Arn/ { split ($2, a, ":"); print a[5]; }'`

echo "Checking that the API Gateway and Microgateway images are present"
if [ "`docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/microgateway-trial/ { print $2 }'`" != "10.5.0.2" ] ||
   [ "`docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/apigateway-trial/ { print $2 }'`" != "10.5.0.2" ] ; then

  if [ `ping -n 1 daerepository03.eur.ad.sag | awk '/Reply from/ { print $1 }'` -ne "Reply" ] ; then
    echo "******************************************************************************"
    echo "Please connect to the VPN to pull the API Gateway & Microgateway docker images"
    echo "******************************************************************************"
    exit
  fi
  echo "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2
  echo "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2
fi

echo "Getting HOSTED_ZONE_ID for DNS Zone: $DNS_ZONE in AWS, if it exists"
export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name=$DNS_ZONE --max-items=1 | awk '/\"\/hostedzone\// {split($2, a, "/"); print substr(a[3], 1, length(a[3])-2) }')
if [ "$HOSTED_ZONE_ID" = "" ]; then
  echo "Creating DNS Zone: $DNS_ZONE in AWS with caller-referece [$CALLER_REF]"
  aws route53 create-hosted-zone --name $DNS_ZONE --caller-reference=$CALLER_REF > dns-response-$RESOURCE_GROUP.json
  cat dns-response-$RESOURCE_GROUP.json
  export HOSTED_ZONE_ID=`cat dns-response-$RESOURCE_GROUP.json | awk '/\"\/hostedzone\// {split($2, a, "/"); print substr(a[3], 1, length(a[3])-2) }'`
fi
echo "HOSTED_ZONE_ID = $HOSTED_ZONE_ID"
echo "****************************************************"
echo "Please ensure your DNS registrar now points $DNS_ZONE to the NameServers above"
echo "****************************************************"
pause "Press any key to continue, when this is done"

echo "Creating cluster-issuer policy"
export AWS_POLICY_ARN=`aws iam list-policies | awk '/"PolicyName": "cert-manager"/ { thisone=1 } /Arn/ { split ($2, a, "\""); if (thisone==1) { print a[2]; thisone=0; }}'`
if [ "$AWS_POLICY_ARN" = "" ]; then
    export AWS_POLICY_ARN=`aws iam create-policy --policy-name cert-manager --policy-document file://cert-manager-aws-iam-policy.json | awk '/Arn/ { split ($2, a, "\""); print a[2] }'`
fi

echo "Creating dns-manager role"
cat cert-manager-aws-iam-trust-policy.json | sed "s/AWS_IAM_ID/$AWS_IAM_ID/g" > cert-manager-aws-iam-trust-policy-$RESOURCE_GROUP.json
export AWS_ROLE_ARN=`aws iam list-roles | awk '/"RoleName": "dns-manager"/ { thisone=1 } /Arn/ { split ($2, a, "\""); if (thisone==1) { print a[2]; thisone=0; }}'`
if [ "$AWS_ROLE_ARN" = "" ]; then
    export AWS_ROLE_ARN=`aws iam create-role --role-name dns-manager --assume-role-policy-document file://cert-manager-aws-iam-trust-policy-$RESOURCE_GROUP.json | awk '/Arn/ { split ($2, a, "\""); print a[2]; }'`
    aws iam attach-role-policy --role-name dns-manager --policy-arn "$AWS_POLICY_ARN"
fi

echo "Creating EKS Cluster: $CLUSTER_NAME"
eksctl create cluster --name $CLUSTER_NAME --region $AWS_REGION

echo "Creating route53 cluster-issuer role"
cat cluster-issuer-Route53.yaml | sed "s/AWS_IAM_ID/$AWS_IAM_ID/g" | sed "s/AWS_IAM_ID/$AWS_IAM_ID/g" | sed "s/AWS_ACCESS_KEY/$AWS_ACCESS_KEY/g"  | sed "s/DNS_ZONE/$DNS_ZONE/g" > cluster-issuer-Route53-$RESOURCE_GROUP.yaml
kubectl apply -f cluster-issuer-Route53-$RESOURCE_GROUP.yaml -n nginx-ingress

echo "Listing EKS Cluster nodes"
kubectl get nodes

echo "Creating nginx-ingress namespace"
kubectl create namespace nginx-ingress
kubectl config set-context --current --namespace=nginx-ingress

echo "Adding nginx-ingress repoo to helm"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
echo "Refreshing helm repoos"
helm repo update
echo "Installing nginx-ingress using helm"
helm install nginx-ingress ingress-nginx/ingress-nginx  -n nginx-ingress --wait
echo "Getting nginx-ingress IP Address"
export NGINX_INGRESS=`kubectl get service -n nginx-ingress nginx-ingress-ingress-nginx-controller | awk '/nginx-ingress-ingress-nginx-controller/ {print $4}'`

while export NGINX_INGRESS_IP=`ping -c 1 -t 1 $NGINX_INGRESS | awk '/PING / { split ($3,a,"[()]"); print a[2]; }' 2>/dev/null` &&  [ "$NGINX_INGRESS_IP" = "" ]; do
  echo "Waiting for DNS names to progagate... ($NGINX_INGRESS)"
  sleep 30
done
echo "Pointing *.$DNS_ZONE to nginx-ingress: $NGINX_INGRESS, NGINX_INGRESS_IP: $NGINX_INGRESS_IP"
cat aws_dns_record.json | sed "s/DNS_ZONE/$DNS_ZONE/g" | sed "s/NGINX_INGRESS/$NGINX_INGRESS/g" > aws_dns_record-$RESOURCE_GROUP.json
aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID  --change-batch file://aws_dns_record-$RESOURCE_GROUP.json

while export IP_CURRENT=`ping -c 1 -t 1 harbor.$DNS_ZONE | awk '/PING / { split ($3,a,"[()]"); print a[2]; }' 2>/dev/null`  &&  [ "$NGINX_INGRESS_IP" != "$IP_CURRENT" ]; do
  echo "Waiting for DNS names to progagate... harbor.$DNS_ZONE ($NGINX_INGRESS_IP - $IP_CURRENT)"
  sleep 30
done
echo "DNS names progagated..."
kubectl label namespace nginx-ingress cert-manager.io/disable-validation=true
echo "Adding cert-manager repoo to helm"
helm repo add jetstack https://charts.jetstack.io
echo "Refreshing helm repoos"
helm repo update
echo "Installing cert-manager using helm"
helm install cert-manager --version v0.13.0  jetstack/cert-manager --wait
echo "Wait for cert-manager to be ready..."
sleep 60
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
export TOKEN_SECRET=`kubectl get secret -n kubernetes-dashboard | awk '/dashboard-admin-sa-token-/ { print $1 }'`
export TOKEN=`kubectl describe secret $TOKEN_SECRET -n kubernetes-dashboard | awk '/token:/ { print $2 }'`
kubectl config set-credentials $KUBE_USER --token=$TOKEN
echo "Kubernetes-dashboard login token: TOKEN: $TOKEN"
kubectl describe secret $TOKEN_SECRET
echo "Create kubernetes-dashboard ingress on address: kubernetes-dashboard.$DNS_ZONE"
kubectl apply -f kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml

while export CERT_READY=`kubectl get certificate | awk '/kubernetes-dashboard-secret/ { print $2 }'` && [ "$CERT_READY" != "True" ]; do
  echo "Waiting for Kubernetes-Dashboard certificate to be generated... ($CERT_READY)"  
  sleep 30
done
echo "Certificate ready..."

echo "Create registries namespace..."
kubectl create namespace registries
kubectl config set-context --current --namespace=registries
echo "Install harbor using helm"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install harbor bitnami/harbor --version 5.4.0 --set service.type=Ingress --set service.ingress.hosts.core=harbor.$DNS_ZONE --set service.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt --set service.ingress.annotations.'kubernetes\.io/ingress\.class'=nginx --set externalURL=https://harbor.$DNS_ZONE --set service.tls.secretName=bitnami-harbor-ingress-cert --set notary.enabled=false --set persistence.persistentVolumeClaim.registry.size=20Gi --wait

while export CERT_READY=`kubectl get certificate | awk '/bitnami-harbor-ingress-cert/ { print $2 }'` && [ "$CERT_READY" != "True" ]; do
  echo "Waiting for harbor ingress certificate to be generated... ($CERT_READY)"  
  sleep 30
done
echo "Certificate ready..."

echo Password: $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -d)

echo "Push API Gateway and API Microgateway to harbor"
echo $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -d) | docker login -u admin --password-stdin harbor.$DNS_ZONE/library
docker tag daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker tag daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2

echo "Install istio"
istioctl manifest apply --set profile=demo -y

echo "Install Kiali"
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.10/samples/addons/kiali.yaml 2>&1 >/dev/null
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.10/samples/addons/kiali.yaml

echo "Create Kiali ingress"
kubectl apply -f ./kiali-ingress-$RESOURCE_GROUP.yaml -n istio-system
while export CERT_READY=`kubectl get certificate -n istio-system | awk '/kiali-secret/ { print $2 }'` && [ "$CERT_READY" != "True" ]; do
  echo "Waiting for kiali ingress certificate to be generated... ($CERT_READY)"  
  sleep 30
done
echo "Certificate ready..."

echo "Install Jaeger"
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.10/samples/addons/jaeger.yaml

echo "Install Zipkin"
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.10/samples/addons/extras/zipkin.yaml

echo "Install Prometheus"
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.10/samples/addons/prometheus.yaml

echo "Install Grafana"
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.10/samples/addons/grafana.yaml

echo "Create monitor namespace..."
kubectl create namespace monitor
kubectl config set-context --current --namespace=monitor
echo "Installing Elastic DaemonSet to ensure ulimits increased"
kubectl apply -f ./es-sysctl-ds.yaml
echo "Povision elast data pvc"
kubectl apply -f elastic-data-pvc.yaml
echo "Installing Elastic Search"
kubectl apply -f ./elasticsearch.yaml

while export PODS_READY=$(kubectl get pods | awk '/elasticsearch-deployment-/ { print $2 }') && [ "$PODS_READY" != "1/1" ]; do
  echo "Waiting for pods to be ready... ($PODS_READY)"  
  sleep 10
done
echo "Pods ready..."

echo "Create nodetours development namespace..."
kubectl create namespace development
kubectl config set-context --current --namespace=development
echo "Installing API Gateway"
kubectl apply -f ./api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml

while export CERT_READY=`kubectl get certificate | awk '/api-gateway-tls-secret/ { print $2 }'` && [ "$CERT_READY" != "True" ]; do
  echo "Waiting for api-gateway ingress certificate to be generated... ($CERT_READY)"  
  sleep 30
done
echo "Certificate ready..."

echo "Checking status of API Gateway pods"
while export PODS_READY=$(kubectl get pods | awk '/api-gateway-deployment-/ { print $2 }') && [ "$PODS_READY" != "1/1" ]; do
  echo "Waiting for pods to be ready... ($PODS_READY)"  
  sleep 10
done
echo "Pods ready..."


kubectl get pods

echo "Enabling Istio Ingress Gateway on *.ig.$DNS_ZONE"

echo "Need to create a user in IAM with the role cert-manager"

export ISTIO_INGRESSGATEWAY=$(kubectl get service istio-ingressgateway -n istio-system | awk '/istio-ingressgateway/ { print $4} ')
while ! export ISTIO_INGRESSGATEWAY_IP=$(ping -c 1 -t 1 $ISTIO_INGRESSGATEWAY | awk '/PING / { split ($3,a,"[()]"); print a[2]; }' 2>/dev/null)  && [ "$ISTIO_INGRESSGATEWAY_IP" != "" ]; do
  echo "Waiting for DNS names to progagate... ($ISTIO_INGRESSGATEWAY_IP)"
  sleep 30
done


echo "Pointing *.ig.$DNS_ZONE to istio-ingressgateway: $ISTIO_INGRESSGATEWAY, NGINX_INGRESS_IP: $ISTIO_INGRESSGATEWAY_IP"
cat aws_dns_record-ig.json | sed "s/DNS_ZONE/$DNS_ZONE/g" | sed "s/ISTIO_INGRESSGATEWAY/$ISTIO_INGRESSGATEWAY/g" > aws_dns_record-ig-$RESOURCE_GROUP.json
aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID  --change-batch file://aws_dns_record-ig-$RESOURCE_GROUP.json
while export IP_CURRENT=`ping -c 1 -t 1 kiali.ig.$DNS_ZONE | awk '/PING / { split ($3,a,"[()]"); print a[2]; }' 2>/dev/null`  &&  [ "$ISTIO_INGRESSGATEWAY_IP" != "$IP_CURRENT" ]; do
  echo "Waiting for DNS names to progagate... ($ISTIO_INGRESSGATEWAY_IP - $IP_CURRENT)" 
  sleep 30
done
echo "DNS names progagated..."
 
kubectl create secret generic route53-credentials-secret --from-file=secret-access-key=./secret-key.txt -n nginx-ingress
cat cluster-issuer-Route53.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" | sed "s/ACME_EMAIL/$ACME_EMAIL/g" | sed "s/AWS_REGION/$AWS_REGION/g" | sed "s/AWS_ACCESS_KEY/$AWS_ACCESS_KEY/g" >  cluster-issuer-Route53-$RESOURCE_GROUP.yaml
kubectl apply -f ./cluster-issuer-Route53-$RESOURCE_GROUP.yaml -n nginx-ingress
cat istio-gateway.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  istio-gateway-$RESOURCE_GROUP.yaml
kubectl apply -f ./istio-gateway-$RESOURCE_GROUP.yaml -n istio-system