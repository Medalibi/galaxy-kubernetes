# Initialise the Hinxton Galaxy portal on AWS

Scripts in this directory allow initalisation of Galaxy (of the Hinxton single-cell flavour) on AWS using Kubernetes under EKS using Amazon's elastic file system (EFS).

## Configure

The following assumes you have the AWS client installed and configured properly with all necessary authenticaion.

### Clone respository

```
cd <checkout dir>
git clone git@github.com:ebi-gene-expression-group/galaxy-kubernetes.git
```

### Environment

Edit `<checkout_dir>/deployment-guides/AWS-EKS-EFS/destroy-all.sh`. In particular you'll need to modify DEVELOPER and AWS_REGION:

```
export DEVELOPER=<your amazon account ID>
export AWS_REGION=<an Amazon region, e.g. us-west-2>
```

### Move to a deployment dir

Move to a location from which you wish to deploy the resource. A directory called 'deploy' will be created to store various config files generated during setup.

```
mkdir -p ~/galaxy_aws_efs
cd ~/galaxy_aws_efs
```

## Install

Install can be done by running the install script

```
<checkout_dir>/deployment-guides/AWS-EKS-EFS/deploy-all.sh
```

This will:

 * Set up a cluster under EKS with all necessary security groups etc
 * Create an EFS filesystem and mount points in all subnets of the region
 * Configure Helm 
 * Deploy [efs-provisoner](https://github.com/helm/charts/tree/master/stable/efs-provisioner).
 * Deploy [helm-hinxton-single-cell-aws](helm-hinxton-single-cell-aws) to provide a single-cell-centric Galaxy deployment
 * Report the final URI at which Galaxy will be accessible


## Teardown

Taking resources down in AWS is actually quite complex. A teardown script is provided to accomplish this:

```
<checkout_dir>/deployment-guides/AWS-EKS-EFS/destroy-all.sh
```

This requires the same environment variables as the deployment. 
