#!/bin/bash
# 340B CloudFormation Teardown Script
# Deletes all stacks in reverse dependency order
# Usage: ./delete.sh <environment> [aws-profile]
# Example: ./delete.sh dev
# Example: ./delete.sh prod my-aws-profile

set -e

ENV=${1:?Usage: ./delete.sh <dev|qa|prod> [aws-profile]}
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

echo "=== Deleting 340B infrastructure for environment: $ENV in $REGION ==="
echo "Stack prefix: $STACK_PREFIX"
echo ""

# Helper: delete a stack if it exists
delete_stack() {
  local stack_name=$1
  local step=$2

  # Check if the stack exists
  if aws cloudformation describe-stacks $AWS_OPTS --stack-name "$stack_name" &>/dev/null; then
    echo "[$step] Deleting $stack_name..."
    aws cloudformation delete-stack $AWS_OPTS --stack-name "$stack_name"
    echo "    Waiting for deletion to complete..."
    aws cloudformation wait stack-delete-complete $AWS_OPTS --stack-name "$stack_name"
    echo "    Deleted $stack_name"
  else
    echo "[$step] $stack_name does not exist, skipping."
  fi
}

# Delete in reverse dependency order

# 11. Route53
delete_stack "${STACK_PREFIX}-route53" "1/11"

# 10. ACM
delete_stack "${STACK_PREFIX}-acm" "2/11"

# 9. Monitoring
delete_stack "${STACK_PREFIX}-monitoring" "3/11"

# 8. Storage (has DeletionPolicy: Retain on S3 bucket — stack deletes but bucket is retained)
delete_stack "${STACK_PREFIX}-storage" "4/11"

# 7. WAF
delete_stack "${STACK_PREFIX}-waf" "5/11"

# 6. Compute (ALB + ASG)
delete_stack "${STACK_PREFIX}-compute" "6/11"

# 5. PrivateLink
delete_stack "${STACK_PREFIX}-privatelink" "7/11"

# 4. TGW VPC Attachment
delete_stack "${STACK_PREFIX}-tgw-attachment" "8/11"

# 3. Transit Gateway
delete_stack "${STACK_PREFIX}-tgw" "9/11"

# 2. KMS (has DeletionPolicy: Retain — stack deletes but key is retained)
delete_stack "${STACK_PREFIX}-kms" "10/11"

# 1. Network
delete_stack "${STACK_PREFIX}-network" "11/11"

# Clean up log groups that may be retained after stack deletion
NAMING_PREFIX=$(jq -r '.Network.NamingPrefix // "340b"' "$PARAMS_FILE")
echo ""
echo "Cleaning up retained log groups..."
for lg in "/aws/vpc/${NAMING_PREFIX}-${ENV}-flow-logs" "/aws/340b/${ENV}/application"; do
  if aws logs describe-log-groups $AWS_OPTS --log-group-name-prefix "$lg" --query "logGroups[?logGroupName=='$lg'].logGroupName" --output text 2>/dev/null | grep -q "$lg"; then
    echo "  Deleting log group: $lg"
    aws logs delete-log-group $AWS_OPTS --log-group-name "$lg" 2>/dev/null || true
  fi
done

echo ""
echo "=== Teardown complete for environment: $ENV ==="
echo "Note: Resources with DeletionPolicy: Retain (KMS key, S3 bucket) are preserved."
