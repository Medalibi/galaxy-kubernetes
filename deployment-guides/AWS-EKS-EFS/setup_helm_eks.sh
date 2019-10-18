

# from https://docs.aws.amazon.com/eks/latest/userguide/helm.html
# Create a namespace called tiller with the following command
# kubectl create namespace tiller

# TODO check versions of kubectl and helm that are compatible with IAM authenticator

helm_rbac_config=$DEPLOYMENT_FOLDER/helm_rbac.yaml
cat >$helm_rbac_config <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tiller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: tiller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tiller
    namespace: kube-system
EOF

kubectl apply -f $helm_rbac_config

helm init --service-account tiller
