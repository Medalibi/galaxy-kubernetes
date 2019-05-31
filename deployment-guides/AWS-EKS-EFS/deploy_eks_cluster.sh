#!/usr/bin/env bash

checkExecutableInPath() {
  [[ $(type -P $1) ]] || (echo "$1 binaries not in the path." && exit 1)
  [[ -x $(type -P $1) ]] || (echo "$1 is not executable." && exit 1)
}

# TODO make the name of the cluster configurable, as well as the settings of the
# cluster

checkExecutableInPath eksctl
checkExecutableInPath aws
checkExecutableInPath kubectl
checkExecutableInPath aws-iam-authenticator

export AWS_REGION=${1:-$AWS_REGION}
export DEPLOYMENT_FOLDER=${2:-$DEPLOYMENT_FOLDER}

[ ! -z ${AWS_REGION+x} ] || ( echo "Env var AWS_REGION with a valid region needs to be set." && exit 1 )
[ ! -z ${DEPLOYMENT_FOLDER+x} ] || ( echo "Env var DEPLOYMENT_FOLDER with a valid folder to store deploy needs to be set." && exit 1 )

# Setup config for EKS
eks_config=$DEPLOYMENT_FOLDER/cluster.yaml
cat >$eks_config <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME 
  region: $AWS_REGION
  version: "1.12"

nodeGroups:
  - name: ng-1
    desiredCapacity: 2
EOF

# Create cluster
echo "Creating EKS k8s cluster... 10 to 15 minutes..."
eksctl create cluster -f $eks_config

if [ $? -ne 0 ]; then
    echo "Failed to create cluster" 1>&2
    exit 1
fi

# Create policy
policy=$DEPLOYMENT_FOLDER/policy.json
cat >$policy <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateServiceLinkedRole",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy"
       ],
      "Resource": "arn:aws:iam::*:role/aws-service-role/efs.amazonaws.com/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "efs:*"
      ],
      "Resource": ["*"]
  }]
}
EOF

# create the IAM policy using the aws command line interface
POLICY_ARN=$(aws iam create-policy --policy-name efs-csi --policy-document file://$policy --query "Policy.Arn" --output text)

# add this policy to your worker node IAM role:
INSTANCE_ROLE_NAME=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-nodegroup-ng-1 --output text --query "Stacks[0].Outputs[1].OutputValue" --region $AWS_REGION | sed -e 's/.*\///g')
aws iam attach-role-policy --policy-arn ${POLICY_ARN} --role-name ${INSTANCE_ROLE_NAME}

if [ $? -ne 0 ]; then
    echo "Failed to attach policy" 1>&2
    exit 2
fi

# Install the FSx CSI Driver
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-fsx-csi-driver/master/deploy/kubernetes/manifest.yaml

# verify that the efs-csi-controller-0 and efs-csi-node-* pods are Running in kube-system
kubectl get pods -n kube-system

echo "Check that all efs-csi-controller and efs-csi-node-* pods are running above. You can re-check by issueing:"
echo "kubectl get pods -n kube-system"

echo "If all looks fine, proceed with deploy_efs_shared_fs.sh"
