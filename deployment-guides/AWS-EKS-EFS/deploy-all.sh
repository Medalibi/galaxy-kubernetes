#!/usr/bin/env bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
export PATH=$(pwd):$SCRIPT_DIR:$PATH

source $SCRIPT_DIR/env.sh

# Deploy the base kubernetes cluster

deploy_eks_cluster.sh

if [ $? -ne 0 ]; then
    echo "Unable to create cluster" 1>&2
    exit 1
fi

# Setup Helm

setup_helm_eks.sh

# Deploy the EFS provisioner

deploy_efs_shared_fs.sh

# Do the Galaxy setup

helm repo add galaxy-helm-repo https://pcm32.github.io/galaxy-helm-charts
helm install -f $SCRIPT_DIR/helm-hinxton-single-cell-aws.yaml galaxy-helm-repo/galaxy-stable

# Print application URI

ip=$(aws ec2 describe-instances --region $AWS_REGION --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --query "Reservations[0].Instances[].NetworkInterfaces[].Association.PublicIp" --output text)
port=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services flailing-lionfish-galaxy-stable)

echo "Startup may take some time. Galaxy application will eventually be available at http://$ip:$port"
