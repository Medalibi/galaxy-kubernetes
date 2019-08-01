#!/usr/bin/env bash

echo "1. Creating EFS file system"

aws efs create-file-system --creation-token "$FILESYSTEM_NAME" --performance-mode generalPurpose --throughput-mode bursting --region $AWS_REGION --tags Key=Name,Value="Test File System" Key=developer,Value="jon.manning.ebi"
fs_id=$(aws efs --region $AWS_REGION describe-file-systems --creation-token $FILESYSTEM_NAME --query "FileSystems[0].FileSystemId" --output text)

echo -e "Created file system ID $fs_id"

# Derive networking info from the cluster

vpc_id=$(aws ec2 describe-vpcs --output text --region $AWS_REGION --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/VPC" --query "Vpcs[0].VpcId")

# Get a private subnet. We get logical IDs like 'SubnetPrivateUSWEST2B',
# 'SubnetPrivateUSWEST2C', but don't seem to be able to guarantee specific
# values. So just use a wildcard to fetch the first private subnet and use that

subnet_id=$(aws ec2 describe-subnets --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]},{\"Name\": \"tag:aws:cloudformation:logical-id\",\"Values\": [\"SubnetPrivateUSWEST*\"]}]" --region $AWS_REGION --query "Subnets[0].SubnetId" --output text)
if [ "$subnet_id" = 'None' ]; then
    echo "Can't derive subnet" 1>&2
    exit 1
fi

# Create a security group

security_group_id=$(aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --vpc-id ${vpc_id} --description "EFS Security Group" --query "GroupId" --output text --region $AWS_REGION)
if [ $? -eq 0 ]; then
    echo -e "Created security group with ID $security_group_id"
else
    echo "Could not create security group" 1>&2
    exit 2
fi

# Add an ingress rule that opens up port 2049 from the 192.168.0.0/16 CIDR range:

aws ec2 authorize-security-group-ingress --group-id ${security_group_id} --protocol tcp --port 2049 --cidr 192.168.0.0/16 --region $AWS_REGION

echo "2. Creating mount target"

aws efs create-mount-target --file-system-id $fs_id --subnet-id $subnet_id --security-group $security_group_id --region $AWS_REGION
if [ $? -eq 0 ]; then
    mount_target_id=$(aws efs describe-mount-targets --region $AWS_REGION --file-system-id $fs_id --query "MountTargets[0].MountTargetId" --output text)
    echo "Created mount target with ID $mount_target_id"
else
    echo "Could not create mount target" 1>&2
    exit 3
fi

echo "3. Provisioning persisent volumes"

helm install stable/efs-provisioner --set efsProvisioner.efsFileSystemId=$fs_id --set efsProvisioner.awsRegion=$AWS_REGION

pvc=$DEPLOYMENT_FOLDER/claim.yaml
cat >$pvc <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs
  resources:
    requests:
      storage: 3600Gi
EOF

kubectl apply -f $pvc

echo "Use galaxy.pvc=$pvc on helm"
