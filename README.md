# Crossplane on EKS

This repo is intended for Crossplane on EKS testing; It is heavily inspired from [aws-deploy-spinnaker-halyard](https://github.com/aws-samples/aws-deploy-spinnaker-halyard) repository, it helps:

1. Creating an EKS cluster for Crossplane
2. Deploying Crossplane Workloads

This repository is meant to quickly demo Crossplane on AWS, AWS being the leading cloud platform.
Getting started with Crossplane needs a good knowledge of both Kubernetes and a cloud provider. I wanted to demo crossplane for people that have abstract knowledge of Kubernetes and AWS, and who's intent aim is to have all their infrastructure on the cloud including kubernetes.

the choice of using EKS rather than minikube:
- Minikube config might change from user to user, while EKS is a standard deployment for everyone
- EKS is closer to what a production Crossplane deployment would look like

I also use codebuild to avoid the need to install a huge number of tools locally. 

It's downside is that EKS costs money.

I also wanted the project for:
- integration tests for different managed resources.
- Testing crossplane's workload portability accross CSPs.
- Testing crossplane's workload migration accross CSPs.

# Pre-requisites
This repository assumes you have a new AWS account and wish to test Crossplane out, you will need AWS CLI credentials setup for a user with at least Administrator access to create resources.

Need to have a kubectl binary installed locally, see [aws official guide](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html).

# Quick Start

Run the following from a terminal with aws cli access to your account (change GITHUB to CODECOMMIT if code is uploaded there).

```
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ACCOUNT_ARN=$(aws sts get-caller-identity --query Arn --output text)
    aws cloudformation create-stack --stack-name codebuild-projects \
        --template-body "$(cat resources/cloudformation/codebuild-projects.yaml)" \
        --parameters ParameterKey=CodeBuildArtifactsBucketName,ParameterValue=codebuild-artifacts-${ACCOUNT_ID} \
                     ParameterKey=SourceLocation,ParameterValue=https://github.com/Sanhajio/crossplane-cfn \
                     ParameterKey=SourceType,ParameterValue=GITHUB \
                     ParameterKey=EKSAdminCLI,ParameterValue=${ACCOUNT_ARN} \
        --capabilities CAPABILITY_NAMED_IAM
    aws ec2 create-key-pair --key-name eks-keypair --output=text > eks-keypair
```

3. Navigate to CodeBuild
4. Start the create-eks CodeBuild project, it takes around 15 minutes to get started.


# Accessing EKS
You will need to add your user ARN to the EKS-Admin role, once this done you can download the EKS kubeconfig with the following command.

```
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    aws eks update-kubeconfig --name crossplane-infra
    export KUBECONFIG=~/.kube/config
    kubectl -n kubesystem get namespaces
```


# Deploying Resources on AWS

I don't know if crossplane supports creating aws networking resources, like DBSubnetGroups, DBSecurityGroups, for now they are created with AWS cloudformation templates.

Creating Networking Resources in AWS:
```
    export EC2_VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=EC2-VPC --query Vpcs[0].VpcId)
    export EC2_SUBNET_IDS=$(aws ec2 describe-subnets --filters Name=vpcId,Values=$EC2_VPC_ID --query Subnets[*].SubnetId --output text | tr [:space:] ",")
    export EC2_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$EC2_VPC_ID --query SecurityGroups[0].GroupId)
    export EC2_SECURITY_GROUP_NAME=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$EC2_VPC_ID --query SecurityGroups[0].GroupName)
    aws cloudformation create-stack --stack-name networking-resources \
        --template-body "$(cat resources/crossplane/rds.yaml)" \
        --parameters ParameterKey=VpcId,ParameterValue=${EC2_VPC_ID} \
                     ParameterKey=SubnetIds,ParameterValue=\'${EC2_SUBNET_IDS::-1}\' \
                     ParameterKey=ClusterSecurityGroupName,ParameterValue=${EC2_SECURITY_GROUP_NAME} \
                     ParameterKey=ClusterSecurityGroupId,ParameterValue=${EC2_SECURITY_GROUP_ID}

```

Create Crossplane rds instance Resource:
```
    export PROVIDER=AWS
    export provider=aws
    export PROVIDER_KEY_FILE=~/.aws/credentials
    AWS_SECURITY_GROUP=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=crossplane-rds-sg --query SecurityGroups[0].GroupId)
    AWS_SUBNET_GROUP=$(aws rds describe-db-subnet-groups --query DBSubnetGroups[0].DBSubnetGroupName)

    sed "s/BASE64ENCODED_${PROVIDER}_PROVIDER_CREDS/`cat ${PROVIDER_KEY_FILE}|base64|tr -d '\n'`/g;" examples/provider.yaml | kubectl -n crossplane-system create -f -
    sed "s/%%DB_SECURITY_GROUP%%/${AWS_SECURITY_GROUP}/g;s/%%DB_SUBNET_GROUP_NAME%%/${AWS_SUBNET_GROUP}/g" examples/v1alpha1-rdsinstance.yaml | kubectl -n crossplane-system create -f -
```

Create Crossplane wordpress workload:
```
    export PROVIDER=AWS
    export provider=aws
    export PROVIDER_KEY_FILE=~/.aws/credentials
    AWS_SECURITY_GROUP=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=crossplane-rds-sg --query SecurityGroups[0].GroupId)
    AWS_SUBNET_GROUP=$(aws rds describe-db-subnet-groups --query DBSubnetGroups[0].DBSubnetGroupName)

   sed "s/BASE64ENCODED_${PROVIDER}_PROVIDER_CREDS/`cat ${PROVIDER_KEY_FILE}|base64|tr -d '\n'`/g;" examples/wordpress/provider.yaml | kubectl -n crossplane-system create -f -
   sed "s/%%DB_SECURITY_GROUP%%/${AWS_SECURITY_GROUP}/g;s/%%DB_SUBNET_GROUP_NAME%%/${AWS_SUBNET_GROUP}/g" examples/wordpress/wordpress.yaml | kubectl -n crossplane-system create -f -

```

Access wordpress workload endpoint:

```
    kubectl -n crossplane-system get services
```

# Clean up

Unfortunatly deleting resources with: ` kubectl -n crossplane-system delete -f examples/wordpress/wordpress.yaml ` does not delete all resources and some have to be deleted by hand.


