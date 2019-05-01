#!/bin/bash -ex

usage() {
cat """
Usage: $0
    -m      (Required) Managing profile, the AWS cli profile where the EKS cluster will be deployed
	-k      (Required) Kubernetes cluster name, the name of the Kubernetes cluster to be created
    -h      Help, print this help message
""" 1>&2; exit 1;
}

while getopts ":m:k:s:h:" o; do
    case "${o}" in
        m)
            export AWS_PROFILE=${OPTARG}
            ;;
        k)
            K8S_NAME=${OPTARG}
            ;;
        s)
            K8S_KEYPAIR=${OPTARG}
            ;;

        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "${MANAGING_PROFILE}" ]; then
    echo "Missing managing profile: -m"
    usage
    exit 1
fi

if [ -z "${K8S_NAME}" ]; then
    echo "Missing Kubernetes cluster name: -k"
    usage
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EKS_VPC_STACK_NAME="spin-eks-vpc"
WORKER_AMI="ami-0923e4b35a30a5f53"
WORKER_TYPE="t2.small"
EKS_WORKER_STACK_NAME="infra-eks-nodes"
K8S_KEYPAIR="eks-keypair"
CODEBUILD_STACK_NAME="codebuild-projects"

function createEKS {
    STACK_NAME=${1}
    echo "Checking for and creating ${STACK_NAME}"
    aws cloudformation describe-stacks --stack-name ${STACK_NAME} && echo "${STACK_NAME} already exists" || \
        aws cloudformation create-stack \
            --stack-name ${STACK_NAME} \
            --template-body "$(cat resources/cloudformation/eks.yaml)" \
            --capabilities CAPABILITY_NAMED_IAM
    echo "Waiting for stack creation complete"
    aws cloudformation wait stack-create-complete --stack-name ${STACK_NAME}
    echo "Stack creation is now complete"
    unset STACK_NAME
}

#TODO: Check default value in eks-nodegroup.yaml
function createEKSWorkers {
    EKS_WORKER_STACK_NAME=${1}
    K8S_NAME=${2}
    K8S_KEYPAIR=${3}
    WORKER_AMI=${4}
    WORKER_TYPE=${5}
    ACCOUNT_ID=${6}
    NETWORK_STACK_NAME=${7}
    echo "Creating EKS worker nodes"
    aws cloudformation describe-stacks --stack-name ${EKS_WORKER_STACK_NAME} && echo "stack ${EKS_WORKER_STACK_NAME} already exists" || \
        aws cloudformation deploy --stack-name ${EKS_WORKER_STACK_NAME} \
            --template-file resources/cloudformation/eks-nodegroup.yaml \
            --parameter-overrides ClusterName=${K8S_NAME} KeyName=${K8S_KEYPAIR} \
                NodeGroupName=crossplane-eks NodeImageId=${WORKER_AMI} NodeInstanceType=${WORKER_TYPE} NetworkStackName=${NETWORK_STACK_NAME} \
            --capabilities CAPABILITY_NAMED_IAM
    aws cloudformation wait stack-create-complete --stack-name ${EKS_WORKER_STACK_NAME}
}

function renderKubeConfig {
    K8S_ENDPOINT=${1}
    CA_DATA=${2}
    K8S_NAME=${3}
    EKS_ADMIN_ARN=${4}
    mkdir -p resources/kubernetes/
    if [ -z "${EKS_ADMIN_ARN}" ]; then
        echo "Rendering without role iam access"
        sed -e "s|%%K8S_ENDPOINT%%|${K8S_ENDPOINT}|g;s|%%CA_DATA%%|${CA_DATA}|g;s|%%K8S_NAME%%|${K8S_NAME}|g" < templates/kubeconfig.tmpl.yaml > resources/kubernetes/kubeconfig.yaml
    else
        echo "Rendering with role iam access"
        mv resources/kubernetes/kubeconfig.yaml resources/kubernetes/kubeconfig-no-role.yaml
        sed -e "s|%%K8S_ENDPOINT%%|${K8S_ENDPOINT}|g;s|%%CA_DATA%%|${CA_DATA}|g;s|%%K8S_NAME%%|${K8S_NAME}|g;s|%%EKS_ADMIN_ARN%%|${EKS_ADMIN_ARN}|g" < templates/kubeconfig-with-role.tmpl.yaml > resources/kubernetes/kubeconfig.yaml
    fi
}

function updateKubeRoles {
    export KUBECONFIG=${1}
    EKS_ADMIN_ARN=${2}
    EKS_NODE_INSTANCE_ROLE_ARN=${3}
    CODEBUILD_ROLE_ARN=${4}
    if kubectl get svc; then
        echo "Have connectivity to kubernetes, updating with EKS admins role access and worker nodes"

        sed -e "s|%%EKS_ADMIN_ARN%%|${EKS_ADMIN_ARN}|g;s|%%EKS_NODE_INSTANCE_ROLE_ARN%%|${EKS_NODE_INSTANCE_ROLE_ARN}|g;s|%%EKS_ADMIN_ACCOUNT%%|${MANAGING_PROFILE}|g" < templates/aws-auth-cm.tmpl.yaml > resources/kubernetes/aws-auth-cm.yaml
        cat $KUBECONFIG > resources/kubeconfig.yaml
        cp $KUBECONFIG ~/.kube/config
        kubectl apply -f resources/kubernetes/aws-auth-cm.yaml
    fi
}

#TODO: The cat and cp commands are
#workarounds
function installHelm {
    export KUBECONFIG=${1}
    EKS_ADMIN_ARN=${2}
    CODEBUILD_ROLE_ARN=${3}
    cp $KUBECONFIG ~/.kube/config
    curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
    chmod +x get_helm.sh
    ./get_helm.sh
    if kubectl get namespaces; then
        echo "Have connectivity to kubernetes, updating with EKS admins role access and worker nodes"
        kubectl apply -f resources/kubernetes/helm-rbac.yaml
        helm init --wait --service-account tiller
    fi
}

function installCrossplane {
    export KUBECONFIG=${1}
    EKS_ADMIN_ARN=${2}
    CODEBUILD_ROLE_ARN=${3}
    if kubectl get namespaces; then
        echo "Have connectivity to kubernetes, updating with EKS admins role access and worker nodes"
        helm repo add crossplane-master https://charts.crossplane.io/master/
        helm repo add crossplane-alpha https://charts.crossplane.io/alpha/
        helm repo update
        helm search crossplane
        helm install --name crossplane --namespace crossplane-system crossplane-alpha/crossplane
    fi
}

function main {
    createEKS ${EKS_VPC_STACK_NAME}
    createEKSWorkers ${EKS_WORKER_STACK_NAME} ${K8S_NAME} ${K8S_KEYPAIR} ${WORKER_AMI} ${WORKER_TYPE} ${ACCOUNT_ID} ${EKS_VPC_STACK_NAME}
    EKS_NODE_INSTANCE_ROLE_ARN=$(aws cloudformation describe-stacks --stack-name ${EKS_WORKER_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`NodeInstanceRole`].OutputValue' --output text)
    K8S_ENDPOINT=$(aws eks describe-cluster --name ${K8S_NAME} --query 'cluster.endpoint' --output text)
    CA_DATA=$(aws eks describe-cluster --name ${K8S_NAME} --query 'cluster.certificateAuthority.data' --output text)
    renderKubeConfig ${K8S_ENDPOINT} ${CA_DATA} ${K8S_NAME}
    EKS_ADMIN_ROLE=$(aws cloudformation describe-stacks --stack-name ${EKS_VPC_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`EKSAdminRole`].OutputValue' --output text)
    EKS_ADMIN_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EKS_ADMIN_ROLE}"
    CODEBUILD_PROJECT_ROLE=$(aws cloudformation describe-stacks --stack-name ${CODEBUILD_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`CreateEKSRole`].OutputValue' --output text)
    CODEBUILD_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_PROJECT_ROLE}"
    KUBECONFIG=${1}
    echo "$(aws sts get-caller-identity)"
    echo "Is admin on EKS"
    updateKubeRoles resources/kubernetes/kubeconfig.yaml ${EKS_ADMIN_ARN} ${EKS_NODE_INSTANCE_ROLE_ARN} ${CODEBUILD_ROLE_ARN}
    renderKubeConfig ${K8S_ENDPOINT} ${CA_DATA} ${K8S_NAME} ${EKS_ADMIN_ARN}
    if [ -f /sys/hypervisor/uuid ] && [ `head -c 3 /sys/hypervisor/uuid` == ec2 ]; then
        ## Deploy crossplane helm resources to EKS
        ## With kubectl commands
        echo "Install helm"
        installHelm resources/kubeconfig.yaml ${EKS_ADMIN_ARN} ${CODEBUILD_ROLE_ARN}
        echo "Deploy Crossplane helm charts"
        installCrossplane resources/kubeconfig.yaml ${EKS_ADMIN_ARN} ${CODEBUILD_ROLE_ARN}
    fi
    SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name ${EKS_VPC_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`EKSSubnetIds`].OutputValue' --output text)
    SUBNET_ID=$(echo "${SUBNET_IDS}" | cut -d "," -f 1)
}

main
