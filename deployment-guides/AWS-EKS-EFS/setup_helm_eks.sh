

# from https://docs.aws.amazon.com/eks/latest/userguide/helm.html
# Create a namespace called tiller with the following command
# kubectl create namespace tiller

# TODO check versions of kubectl and helm that are compatible with IAM authenticator

helm init

kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
kubectl patch deploy --namespace kube-system tiller-deploy --patch '{"spec": {"template": {"spec": {"serviceAccount": "tiller"} } } }'

helm init --service-account tiller --upgrade
helm init --service-account tiller

git clone https://github.com/galaxyproject/galaxy-helm.git
cd galaxy-helm/galaxy
helm dependency update
