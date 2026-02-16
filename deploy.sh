#!/bin/bash
# 340B CloudFormation Deployment Script
# Deploys stacks sequentially with cross-stack references
# Usage: ./deploy.sh <environment> [aws-profile]
# Example: ./deploy.sh dev
# Example: ./deploy.sh prod my-aws-profile

set -e

ENV=${1:?Usage: ./deploy.sh <dev|qa|prod> [aws-profile]}
AWS_PROFILE=${2:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${SCRIPT_DIR}/environments/${ENV}/parameters.json"

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "Error: Parameters file not found: $PARAMS_FILE"
  exit 1
fi

# CloudFormation stack names must start with a letter.
STACK_PREFIX="bmc340b-${ENV}"
REGION=$(jq -r '.Network.Region // "us-west-1"' "$PARAMS_FILE")

# AWS CLI options
AWS_OPTS="--region $REGION"
[[ -n "$AWS_PROFILE" ]] && AWS_OPTS="$AWS_OPTS --profile $AWS_PROFILE"

echo "=== Deploying 340B infrastructure for environment: $ENV in $REGION ==="

# Helper to get JSON value
get_param() {
  local stack=$1
  local key=$2
  jq -r --arg s "$stack" --arg k "$key" '.[$s][$k] // empty' "$PARAMS_FILE"
}

# 1. Network
echo "[1/11] Deploying Network stack..."
aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/network/vpc.yaml" \
  --stack-name "${STACK_PREFIX}-network" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Network Region)" \
    NamingPrefix="$(get_param Network NamingPrefix)" \
    VPCCidr="$(get_param Network VPCCidr)" \
    PublicSubnet1Cidr="$(get_param Network PublicSubnet1Cidr)" \
    PublicSubnet2Cidr="$(get_param Network PublicSubnet2Cidr)" \
    PrivateSubnet1Cidr="$(get_param Network PrivateSubnet1Cidr)" \
    PrivateSubnet2Cidr="$(get_param Network PrivateSubnet2Cidr)" \
    AvailabilityZone1="$(get_param Network AvailabilityZone1)" \
    AvailabilityZone2="$(get_param Network AvailabilityZone2)" \
    FlowLogRetentionDays="$(get_param Network FlowLogRetentionDays)" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# 2. KMS
echo "[2/11] Deploying KMS stack..."
aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/security/kms.yaml" \
  --stack-name "${STACK_PREFIX}-kms" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Security Region)" \
    NamingPrefix="$(get_param Security NamingPrefix)" \
  --no-fail-on-empty-changeset

# 3. Transit Gateway
echo "[3/11] Deploying Transit Gateway stack..."
aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/connectivity/transit-gateway.yaml" \
  --stack-name "${STACK_PREFIX}-tgw" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Connectivity Region)" \
    NamingPrefix="$(get_param Connectivity NamingPrefix)" \
  --no-fail-on-empty-changeset

# 4. TGW VPC Attachment
echo "[4/11] Deploying TGW VPC Attachment stack..."
VPC_ID=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
PRIVATE_SUBNET_1=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet1Id'].OutputValue" --output text)
PRIVATE_SUBNET_2=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2Id'].OutputValue" --output text)
PRIVATE_RT=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='PrivateRouteTableId'].OutputValue" --output text)
TGW_ID=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-tgw" --query "Stacks[0].Outputs[?OutputKey=='TransitGatewayId'].OutputValue" --output text)

aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/connectivity/tgw-vpc-attachment.yaml" \
  --stack-name "${STACK_PREFIX}-tgw-attachment" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Connectivity Region)" \
    NamingPrefix="$(get_param Connectivity NamingPrefix)" \
    TransitGatewayId="$TGW_ID" \
    VpcId="$VPC_ID" \
    PrivateSubnet1Id="$PRIVATE_SUBNET_1" \
    PrivateSubnet2Id="$PRIVATE_SUBNET_2" \
    PrivateRouteTableId="$PRIVATE_RT" \
    TgwRouteDestinationCidr="$(get_param Connectivity TgwRouteDestinationCidr)" \
  --no-fail-on-empty-changeset

# 5. PrivateLink (Interface Endpoints)
echo "[5/11] Deploying PrivateLink stack..."
aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/connectivity/privatelink.yaml" \
  --stack-name "${STACK_PREFIX}-privatelink" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Connectivity Region)" \
    NamingPrefix="$(get_param Connectivity NamingPrefix)" \
    VpcId="$VPC_ID" \
    VPCCidr="$(get_param Network VPCCidr)" \
    PrivateSubnet1Id="$PRIVATE_SUBNET_1" \
    PrivateSubnet2Id="$PRIVATE_SUBNET_2" \
    PrivateRouteTableId="$PRIVATE_RT" \
    EnableEndpointService="$(get_param Connectivity EnableEndpointService)" \
  --no-fail-on-empty-changeset

# 6. Compute (ALB + ASG)
echo "[6/11] Deploying Compute stack..."
PUBLIC_SUBNET_1=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet1Id'].OutputValue" --output text)
PUBLIC_SUBNET_2=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet2Id'].OutputValue" --output text)
ALB_SG=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='ALBSecurityGroupId'].OutputValue" --output text)
EC2_SG=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-network" --query "Stacks[0].Outputs[?OutputKey=='EC2SecurityGroupId'].OutputValue" --output text)

aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/compute/alb-asg.yaml" \
  --stack-name "${STACK_PREFIX}-compute" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Compute Region)" \
    NamingPrefix="$(get_param Compute NamingPrefix)" \
    InstanceType="$(get_param Compute InstanceType)" \
    MinSize="$(get_param Compute MinSize)" \
    MaxSize="$(get_param Compute MaxSize)" \
    DesiredCapacity="$(get_param Compute DesiredCapacity)" \
    KeyName="$(get_param Compute KeyName)" \
    VpcId="$VPC_ID" \
    PublicSubnet1Id="$PUBLIC_SUBNET_1" \
    PublicSubnet2Id="$PUBLIC_SUBNET_2" \
    PrivateSubnet1Id="$PRIVATE_SUBNET_1" \
    PrivateSubnet2Id="$PRIVATE_SUBNET_2" \
    ALBSecurityGroupId="$ALB_SG" \
    EC2SecurityGroupId="$EC2_SG" \
    CertificateArn="" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# 7. WAF
echo "[7/11] Deploying WAF stack..."
ALB_ARN=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-compute" --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerArn'].OutputValue" --output text)

aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/security/waf.yaml" \
  --stack-name "${STACK_PREFIX}-waf" \
  --parameter-overrides \
    LoadBalancerArn="$ALB_ARN" \
    Environment="$ENV" \
    Region="$(get_param Security Region)" \
    NamingPrefix="$(get_param Security NamingPrefix)" \
  --no-fail-on-empty-changeset

# 8. Storage
echo "[8/11] Deploying Storage stack..."
KMS_ARN=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-kms" --query "Stacks[0].Outputs[?OutputKey=='KMSKeyArn'].OutputValue" --output text)

aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/storage/s3.yaml" \
  --stack-name "${STACK_PREFIX}-storage" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Storage Region)" \
    NamingPrefix="$(get_param Storage NamingPrefix)" \
    KMSKeyArn="$KMS_ARN" \
    BucketSuffix="$(get_param Storage BucketSuffix)" \
  --no-fail-on-empty-changeset

# 9. Monitoring
echo "[9/11] Deploying Monitoring stack..."
ASG_NAME=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-compute" --query "Stacks[0].Outputs[?OutputKey=='AutoScalingGroupName'].OutputValue" --output text)

aws cloudformation deploy $AWS_OPTS \
  --template-file "${SCRIPT_DIR}/modules/monitoring/cloudwatch.yaml" \
  --stack-name "${STACK_PREFIX}-monitoring" \
  --parameter-overrides \
    Environment="$ENV" \
    Region="$(get_param Monitoring Region)" \
    NamingPrefix="$(get_param Monitoring NamingPrefix)" \
    KMSKeyArn="$KMS_ARN" \
    LogRetentionDays="$(get_param Monitoring LogRetentionDays)" \
    AlarmEmail="$(get_param Monitoring AlarmEmail)" \
    LoadBalancerArn="$ALB_ARN" \
    AutoScalingGroupName="$ASG_NAME" \
  --no-fail-on-empty-changeset

# 10. ACM (optional - if DomainName is set)
DOMAIN=$(get_param DNS DomainName)
if [[ -n "$DOMAIN" && "$DOMAIN" != "null" ]]; then
  echo "[10/11] Deploying ACM stack..."
  aws cloudformation deploy $AWS_OPTS \
    --template-file "${SCRIPT_DIR}/modules/certificates/acm.yaml" \
    --stack-name "${STACK_PREFIX}-acm" \
    --parameter-overrides \
      Environment="$ENV" \
      Region="$(get_param ACM Region)" \
      NamingPrefix="$(get_param ACM NamingPrefix)" \
      DomainName="$(get_param ACM DomainName)" \
      SubjectAlternativeNames="$(get_param ACM SubjectAlternativeNames)" \
      ValidationMethod="$(get_param ACM ValidationMethod)" \
    --no-fail-on-empty-changeset
fi

# 11. Route53 (optional - if DomainName is set and zone is available)
CREATE_ZONE=$(get_param DNS CreateHostedZone)
EXISTING_ZONE=$(get_param DNS HostedZoneId)
if [[ -n "$DOMAIN" && "$DOMAIN" != "null" && ( "$CREATE_ZONE" == "true" || ( -n "$EXISTING_ZONE" && "$EXISTING_ZONE" != "null" ) ) ]]; then
  echo "[11/11] Deploying Route53 stack..."
  ALB_DNS=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-compute" --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNSName'].OutputValue" --output text)
  ALB_ZONE=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-compute" --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerHostedZoneId'].OutputValue" --output text)

  aws cloudformation deploy $AWS_OPTS \
    --template-file "${SCRIPT_DIR}/modules/dns/route53.yaml" \
    --stack-name "${STACK_PREFIX}-route53" \
    --parameter-overrides \
      Environment="$ENV" \
      Region="$(get_param DNS Region)" \
      NamingPrefix="$(get_param DNS NamingPrefix)" \
      DomainName="$DOMAIN" \
      CreateHostedZone="$(get_param DNS CreateHostedZone)" \
      HostedZoneId="$(get_param DNS HostedZoneId)" \
      LoadBalancerDNSName="$ALB_DNS" \
      LoadBalancerHostedZoneId="$ALB_ZONE" \
      RecordName="$(get_param DNS RecordName)" \
    --no-fail-on-empty-changeset
fi

echo ""
echo "=== Deployment complete ==="
ALB_DNS=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "${STACK_PREFIX}-compute" --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNSName'].OutputValue" --output text)
echo "ALB URL: http://${ALB_DNS}"
