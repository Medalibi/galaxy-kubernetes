#!/usr/bin/env bash

export DEPLOYMENT_FOLDER=$(pwd)/deploy

# Delete Galaxy helm

helm delete $(helm list | grep "galaxy-stable" | awk -F'\t' '{print $1}')

################################################################################
#
# 1. Take down the file system and associated infrastructure 
#
################################################################################

# Delete the PVC

kubectl delete -f $DEPLOYMENT_FOLDER/claim.yaml 

# Delete the EFS provisioner Helm

helm delete $(helm list | grep "efs-provisioner" | awk -F'\t' '{print $1}')

# If a the file system exists, remove it

fs_id=$(aws efs --region $AWS_REGION describe-file-systems --creation-token $FILESYSTEM_NAME --query "FileSystems[0].FileSystemId" --output text)

if [ "$fs_id" != 'None' ]; then
    mount_target_id=$(aws efs describe-mount-targets --region $AWS_REGION --file-system-id $fs_id --query "MountTargets[0].MountTargetId" --output text)

    # Delete mount targets

    echo "Deleting mount target $mount_target_id"
    aws efs delete-mount-target --mount-target-id $mount_target_id --region $AWS_REGION 
fi

vpc_id=$(aws ec2 describe-vpcs --output text --region $AWS_REGION --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/VPC" --query "Vpcs[0].VpcId")
if [ "$vpc_id" != 'None' ]; then

    subnet_id=$(aws ec2 describe-subnets --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]},{\"Name\": \"tag:aws:cloudformation:logical-id\",\"Values\": [\"SubnetPrivateUSWEST2B\"]}]" --region $AWS_REGION --query "Subnets[0].SubnetId" --output text)
    security_group_ids=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "[{\"Name\": \"vpc-id\",\"Values\": [\"$vpc_id\"]}]" --query "SecurityGroups[].GroupId" --output text)

    if [ -n "$security_group_id" ]; then

        # Delete security groups 

        for sgid in $security_group_ids; do
            echo "Deleting security group $sgid"
            aws ec2 delete-security-group --group-id $sgid --region $AWS_REGION
        done
    fi
fi

echo "Deleting the VPC ..."
aws ec2 delete-vpc --vpc-id $vpc_id --region $AWS_REGION

# Give things a few seconds to disappear before trying to delete the file system

sleep 10

if [ "$fs_id" != 'None' ]; then

    # Delete the file system

    echo "Deleting file system $fs_id"
    aws efs delete-file-system --file-system-id $fs_id --region $AWS_REGION

fi

################################################################################
#
# 2. Delete the cluster infrastructure itself. The iam policy must be detached
# before we can do so, and stacks take a while to actually go, so we must wait
#
################################################################################

policy_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='efs-csi'].Arn" --output text)

if [ -n "$policy_arn" ]; then
    instance_role_name=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-nodegroup-ng-1 --output text --query "Stacks[0].Outputs[1].OutputValue" --region $AWS_REGION | sed -e 's/.*\///g')
    echo "Detaching role policy $instance_role_name"
    aws iam detach-role-policy --policy-arn ${policy_arn} --role-name ${instance_role_name}
    echo "Deleting policy $policy_arn"
    aws iam delete-policy --policy-arn $policy_arn
fi

# Delete the cluster

echo "Deleting the cluster ${CLUSTER_NAME}"
eksctl delete cluster --region=$AWS_REGION --name=$CLUSTER_NAME

if [ $? -eq 0 ]; then
    stack_status=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster --region $AWS_REGION --query "Stacks[0].StackStatus" --output text)

    echo -n "Waiting for stacks to delete ..."
    while [ "$stack_status" = 'DELETE_IN_PROGRESS' ]; do
        stack_status=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster --region $AWS_REGION --query "Stacks[0].StackStatus" --output text 2>/dev/null)
        if [ $? -ne 0 ]; then
            break
        fi
        echo -n '.'
        sleep 20
    done
    echo -e "\n\n"
    echo "Deletion complete."
else
    echo "Cluster deletion failed" 1>&2
    exit 1
fi


