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

# Collecting the default VPC and subnets details to be used in the EKS cluster creation
vpc_id=$(aws ec2 describe-vpcs --output text --region $AWS_REGION --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --query "Vpcs[0].VpcId")
subnet_id=$(aws ec2 describe-subnets --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --region $AWS_REGION --query "Subnets[0].SubnetId" --output text)
availability_zone=$(aws ec2 describe-subnets --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)

#Create Galaxy system access security Groups
security_group_id=$(aws ec2 create-security-group --group-name galaxy-eks-access-sg --vpc-id ${vpc_id} --description "Galxy Cluster Security Group" --query "GroupId" --output text --region $AWS_REGION)
aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 30700 --cidr 0.0.0.0/0

# Export the EKS cluster security group ID to be addeded to the EFS seciryt group permissions
export GALAXY_EKS_SG_ID="$security_group_id"

# Setup config for EKS
eks_config=$DEPLOYMENT_FOLDER/cluster.yaml
cat >$eks_config <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $AWS_REGION
  version: "1.14"

#vpc:
#  id: $vpc_id
#  subnets:
#    public:
#      $availability_zone:
#        id: $subnet_id

nodeGroups:
  - name: galaxy-eks-ng
    instanceType: m5.2xlarge
    minSize: 1
    desiredCapacity: 2
    maxSize: 6
    ssh:
      allow: true
      publicKeyName: $AWS_EC2_ACCESS_KEY
    volumeSize: 150
    volumeType: io1
    volumeIOPS: 3000
    ami: auto
    amiFamily: AmazonLinux2
    availabilityZones: ["$availability_zone"]
    iam:
      withAddonPolicies:
        autoScaler: true
        efs: true
        ebs: true
        imageBuilder: true
        albIngress: true
    securityGroups:
      withShared: true
      withLocal: true
      attachIDs: [ '$security_group_id' ]
    instanceName: Galaxy-EKS-Cluster-nodes
    tags:
      team: TrainingTeam
      Project: SingleCell

availabilityZones: ['$availability_zone']

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

# Create a security group to allow external access to Galaxy port

vpc_id=$(aws ec2 describe-vpcs --output text --region $AWS_REGION --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/VPC" --query "Vpcs[0].VpcId")
galaxy_access_security_group_id=$(aws ec2 create-security-group --group-name ext-galaxy-access --vpc-id ${vpc_id} --description "Galaxy access" --query "GroupId" --output text --region $AWS_REGION)

if [ $? -eq 0 ]; then
    echo -e "Created security group with ID $galaxy_access_security_group_id for Galaxy access"
else
    echo "Could not create security group" 1>&2
    exit 2
fi

# Actually allow the ingress

echo "Allowing ingress to port 30700 for security group $galaxy_access_security_group_id"
aws ec2 authorize-security-group-ingress --group-id ${galaxy_access_security_group_id} --protocol tcp --port 30700 --cidr 0.0.0.0/0 --region $AWS_REGION

# Associate the new security group with the running instances. Need to do this
# via the network interfaces, since there may be multiple per instance. First
# find the public IPs

instance_public_ips=$(aws ec2 describe-instances --region $AWS_REGION --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --query "Reservations[].Instances[].NetworkInterfaces[].Association.PublicIp" --output text)

# For each public IP find the interface and add the new security group to it

for ipi in $instance_public_ips; do

    network_interface_id=$(aws ec2 describe-network-interfaces --region $AWS_REGION  --filters "[{\"Name\": \"association.public-ip\",\"Values\": [\"$ipi\"]}, {\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --query "NetworkInterfaces[].NetworkInterfaceId" --output text)

    echo "Adding Galaxy access security group $galaxy_access_security_group_id to network interface $network_interface_id"

    interface_security_groups=$(aws ec2 describe-network-interfaces --region $AWS_REGION --network-interface-ids $network_interface_id --query "NetworkInterfaces[].Groups[].GroupId" --output text)
    aws ec2 modify-network-interface-attribute --network-interface-id $network_interface_id --groups $interface_security_groups $galaxy_access_security_group_id --region $AWS_REGION

    if [ $? -ne 0 ]; then
        echo "Failed to add Galaxy access security group $galaxy_access_security_group_id to network interface $network_interface_id" 1>&2
        exit 2
    fi
done

echo "Cluster created and configured successfully!"
