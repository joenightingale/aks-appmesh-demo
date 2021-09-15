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

echo "Configuring AWS Connection properties"
aws configure

echo "Get AWS AIM ID"
export AWS_IAM_ID=`aws iam get-user | awk '/Arn/ { split ($2, a, ":"); print a[5]; }'`

echo "Getting HOSTED_ZONE_ID for DNS Zone: $DNS_ZONE in AWS, if it exists"
export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name=$DNS_ZONE --max-items=1 | awk '/\"\/hostedzone\// {split($2, a, "/"); print substr(a[3], 1, length(a[3])-2) }')

echo "Getting cluster-issuer policy"
export AWS_POLICY_ARN=`aws iam list-policies | awk '/"PolicyName": "cert-manager"/ { thisone=1 } /Arn/ { split ($2, a, "\""); if (thisone==1) { print a[2]; thisone=0; }}'`

echo "Getting dns-manager role"
cat cert-manager-aws-iam-trust-policy.json | sed "s/AWS_IAM_ID/$AWS_IAM_ID/g" > cert-manager-aws-iam-trust-policy-$RESOURCE_GROUP.json
export AWS_ROLE_ARN=`aws iam list-roles | awk '/"RoleName": "dns-manager"/ { thisone=1 } /Arn/ { split ($2, a, "\""); if (thisone==1) { print a[2]; thisone=0; }}'`

echo "Update kube config context for cluster $CLUSTER_NAME"
eksctl utils write-kubeconfig --cluster $CLUSTER_NAME

cat istio-gateway.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  istio-gateway-$RESOURCE_GROUP.yaml
kubectl delete -f ./istio-gateway-$RESOURCE_GROUP.yaml -n istio-system

kubectl create secret generic route53-credentials-secret --from-file=secret-access-key=./secret-key.txt -n nginx-ingress
cat cluster-issuer-Route53.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" | sed "s/ACME_EMAIL/$ACME_EMAIL/g" | sed "s/AWS_REGION/$AWS_REGION/g" | sed "s/AWS_ACCESS_KEY/$AWS_ACCESS_KEY/g" >  cluster-issuer-Route53-$RESOURCE_GROUP.yaml
kubectl delete -f ./cluster-issuer-Route53-$RESOURCE_GROUP.yaml -n nginx-ingress

