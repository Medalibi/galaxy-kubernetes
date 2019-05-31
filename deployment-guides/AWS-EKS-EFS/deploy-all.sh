#!/usr/bin/env bash

export PATH=$(pwd):$PATH

export AWS_REGION=us-west-2
export CLUSTER_NAME=efs-csi-driver
export SECURITY_GROUP_NAME=eks_efs_security_group
export FILESYSTEM_NAME=eks_efs_fs
export DEPLOYMENT_FOLDER=$(pwd)/deploy

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
helm install -f helm-hinxton-single-cell-aws.yaml galaxy-helm-repo/galaxy-stable
