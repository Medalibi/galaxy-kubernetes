#!/usr/bin/env bash

echo "1. Creating EFS file system"

aws efs create-file-system --creation-token "$FILESYSTEM_NAME" --performance-mode maxIO --throughput-mode bursting --region $AWS_REGION --tags Key=Name,Value="Galaxy filesystem" Key=developer,Value="$DEVELOPER"
fs_id=$(aws efs --region $AWS_REGION describe-file-systems --creation-token $FILESYSTEM_NAME --query "FileSystems[0].FileSystemId" --output text)

echo -e "Created file system ID $fs_id"

# Derive networking info from the cluster

vpc_id=$(aws ec2 describe-vpcs --output text --region $AWS_REGION --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --query "Vpcs[0].VpcId")
vpc_cidr=$(aws ec2 describe-vpcs --output text --region $AWS_REGION --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --query "Vpcs[0].CidrBlock")
# Create a security group

security_group_id=$(aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --vpc-id ${vpc_id} --description "EFS Security Group" --query "GroupId" --output text --region $AWS_REGION)
if [ $? -eq 0 ]; then
    echo -e "Created security group with ID $security_group_id"
else
    echo "Could not create security group" 1>&2
    exit 2
fi

# Add an ingress rule that opens up port 2049 from the 192.168.0.0/16 CIDR range:

aws ec2 authorize-security-group-ingress --group-id ${security_group_id} --protocol tcp --port 2049 --cidr $vpc_cidr --region $AWS_REGION
aws ec2 authorize-security-group-ingress --group-id ${security_group_id} --protocol tcp --port 2049 --cidr $GALAXY_EKS_SG_ID --region $AWS_REGION
echo "2. Creating mount targets for each subnet"

subnet_id=$(aws ec2 describe-subnets --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --region $AWS_REGION --query "Subnets[0].SubnetId" --output text)

aws efs create-mount-target --file-system-id $fs_id --subnet-id $subnet_id --security-group $security_group_id --region $AWS_REGION
if [ $? -eq 0 ]; then
    mount_target_id=$(aws efs describe-mount-targets --region $AWS_REGION --file-system-id $fs_id --query "MountTargets[0].MountTargetId" --output text)
    echo "Created mount target with ID $mount_target_id"
else
    echo "Could not create mount target" 1>&2
    exit 3
fi

# The mount targets take a little while to create

mount_targets_ready=no
mt_wait_loops=1
max_mt_wait_loops=10
echo "Waiting for mount points to be available"

while [ "$mount_targets_ready" = 'no' ]; do

    loop_mt_ready=yes
    mount_target_states=$(aws efs describe-mount-targets --region $AWS_REGION --file-system-id $fs_id --query "MountTargets[].LifeCycleState" --output text)

    for mts in $mount_target_states; do
        if [ "$mts" != 'available' ]; then
            loop_mt_ready=no
            break
        fi
    done

    if [ "$loop_mt_ready" = 'yes' ]; then
        mount_targets_ready=yes
    else
        echo -n '.'
        sleep 10
        mt_wait_loops=$[$mt_wait_loops+1]
    fi
done

echo "Mount points ready"

echo "3. Provisioning persisent volumes"

helm install stable/efs-provisioner --set efsProvisioner.efsFileSystemId=$fs_id --set efsProvisioner.awsRegion=$AWS_REGION

sleep 5

kubectl get pods --field-selector status.phase=Running | grep "efs-provisioner"

if [ $? -ne 0 ]; then
    echo "EFS helm deployment failed"
    exit 1
fi

# setup the efs claim volume
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
      storage: 1000Gi
EOF

kubectl apply -f $pvc

# Setup the Postgres volume claim on aws gp2
postgrespvc=$DEPLOYMENT_FOLDER/postgres-claim.yaml
cat >$postgrespvc <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  annotations:
    volume.beta.kubernetes.io/storage-class: gp2
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
EOF

kubectl apply -f $postgrespvc

kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "Use galaxy.pvc=$pvc on helm"
