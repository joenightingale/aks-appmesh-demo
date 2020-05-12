kubectl delete  ingress kubernetes-dashboard
kubectl delete clusterrolebinding dashboard-admin-sa
kubectl delete serviceaccount dashboard-admin-sa
kubectl config set-context --current --namespace=nginx-ingress
helm delete -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml
kubectl  delete -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml
kubectl delete -f helm install cert-manager --version v0.13.0  jetstack/cert-manager
kubectl delete -f cluster-issuer.yaml
helm delete cert-manager