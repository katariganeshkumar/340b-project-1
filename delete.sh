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

# Helper: delete a stack if it exists (with retry on DELETE_FAILED)
delete_stack() {
  local stack_name=$1
  local step=$2

  if ! aws cloudformation describe-stacks $AWS_OPTS --stack-name "$stack_name" &>/dev/null; then
    echo "[$step] $stack_name does not exist, skipping."
    return 0
  fi

  echo "[$step] Deleting $stack_name..."
  aws cloudformation delete-stack $AWS_OPTS --stack-name "$stack_name"
  echo "    Waiting for deletion to complete..."

  if aws cloudformation wait stack-delete-complete $AWS_OPTS --stack-name "$stack_name" 2>/dev/null; then
    echo "    Deleted $stack_name"
    return 0
  fi

  local status
  status=$(aws cloudformation describe-stacks $AWS_OPTS --stack-name "$stack_name" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null)

  if [[ "$status" == "DELETE_FAILED" ]]; then
    echo "    DELETE_FAILED - retrying with --retain-resources for IAM resources..."
    local failed_resources
    failed_resources=$(aws cloudformation describe-stack-events $AWS_OPTS --stack-name "$stack_name" \
      --query "StackEvents[?ResourceStatus=='DELETE_FAILED' && ResourceType!='AWS::CloudFormation::Stack'].LogicalResourceId" \
      --output text 2>/dev/null)

    if [[ -n "$failed_resources" ]]; then
      echo "    Retaining: $failed_resources"
      aws cloudformation delete-stack $AWS_OPTS --stack-name "$stack_name" \
        --retain-resources $failed_resources
      aws cloudformation wait stack-delete-complete $AWS_OPTS --stack-name "$stack_name" 2>/dev/null \
        && echo "    Deleted $stack_name (with retained resources)" \
        || echo "    WARNING: $stack_name still failed to delete"
    fi
  fi
}

# Delete in reverse dependency order

# 12. Route53
delete_stack "${STACK_PREFIX}-route53" "1/12"

# 11. ACM
delete_stack "${STACK_PREFIX}-acm" "2/12"

# 10. Monitoring
delete_stack "${STACK_PREFIX}-monitoring" "3/12"

# 9. Storage (has DeletionPolicy: Retain on S3 bucket — stack deletes but bucket is retained)
delete_stack "${STACK_PREFIX}-storage" "4/12"

# 8. WAF
delete_stack "${STACK_PREFIX}-waf" "5/12"

# 7. Compute (ALB + ASG)
delete_stack "${STACK_PREFIX}-compute" "6/12"

# 6. PrivateLink
delete_stack "${STACK_PREFIX}-privatelink" "7/12"

# 5. Network Firewall
delete_stack "${STACK_PREFIX}-network-firewall" "8/12"

# 4. TGW VPC Attachment
delete_stack "${STACK_PREFIX}-tgw-attachment" "9/12"

# 3. Transit Gateway
delete_stack "${STACK_PREFIX}-tgw" "10/12"

# 2. KMS (has DeletionPolicy: Retain — stack deletes but key is retained)
delete_stack "${STACK_PREFIX}-kms" "11/12"

# 1. Network
delete_stack "${STACK_PREFIX}-network" "12/12"

# Clean up orphaned resources that may survive failed stack deletions
NAMING_PREFIX=$(jq -r '.Network.NamingPrefix // "340b"' "$PARAMS_FILE")

echo ""
echo "Cleaning up retained log groups..."
for lg in "/aws/vpc/${NAMING_PREFIX}-${ENV}-flow-logs" "/aws/networkfirewall/${NAMING_PREFIX}-${ENV}-nfw" "/aws/340b/${ENV}/application"; do
  if aws logs describe-log-groups $AWS_OPTS --log-group-name-prefix "$lg" --query "logGroups[?logGroupName=='$lg'].logGroupName" --output text 2>/dev/null | grep -q "$lg"; then
    echo "  Deleting log group: $lg"
    aws logs delete-log-group $AWS_OPTS --log-group-name "$lg" 2>/dev/null || true
  fi
done

echo ""
echo "Cleaning up orphaned IAM roles..."
delete_iam_role() {
  local role_name=$1
  if aws iam get-role --role-name "$role_name" &>/dev/null; then
    echo "  Found orphaned role: $role_name"
    for policy in $(aws iam list-role-policies --role-name "$role_name" --query "PolicyNames[]" --output text 2>/dev/null); do
      echo "    Removing inline policy: $policy"
      aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy" 2>/dev/null || true
    done
    for arn in $(aws iam list-attached-role-policies --role-name "$role_name" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
      echo "    Detaching managed policy: $arn"
      aws iam detach-role-policy --role-name "$role_name" --policy-arn "$arn" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$role_name" 2>/dev/null && echo "    Deleted role: $role_name" || echo "    Could not delete role: $role_name (may require elevated permissions)"
  fi
}

# Scan for orphaned roles created by CloudFormation stacks (FlowLog, Network Firewall Lambda)
ORPHAN_ROLES=$(aws iam list-roles --query "Roles[?contains(RoleName, '${STACK_PREFIX}')].RoleName" --output text 2>/dev/null)
if [[ -n "$ORPHAN_ROLES" ]]; then
  for role in $ORPHAN_ROLES; do
    delete_iam_role "$role"
  done
else
  echo "  No orphaned roles found for prefix: ${STACK_PREFIX}"
fi

echo ""
echo "Cleaning up orphaned Lambda functions..."
ORPHAN_LAMBDAS=$(aws lambda list-functions $AWS_OPTS --query "Functions[?contains(FunctionName, '${NAMING_PREFIX}-${ENV}-nfw')].FunctionName" --output text 2>/dev/null)
if [[ -n "$ORPHAN_LAMBDAS" ]]; then
  for fn in $ORPHAN_LAMBDAS; do
    echo "  Deleting Lambda function: $fn"
    aws lambda delete-function $AWS_OPTS --function-name "$fn" 2>/dev/null || true
  done
else
  echo "  No orphaned Lambda functions found."
fi

echo ""
echo "Cleaning up stacks stuck in REVIEW_IN_PROGRESS..."
STUCK_STACKS=$(aws cloudformation list-stacks $AWS_OPTS \
  --stack-status-filter REVIEW_IN_PROGRESS \
  --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].StackName" \
  --output text 2>/dev/null)
if [[ -n "$STUCK_STACKS" ]]; then
  for stuck in $STUCK_STACKS; do
    echo "  Deleting stuck stack: $stuck"
    aws cloudformation delete-stack $AWS_OPTS --stack-name "$stuck" 2>/dev/null || true
    aws cloudformation wait stack-delete-complete $AWS_OPTS --stack-name "$stuck" 2>/dev/null || true
  done
else
  echo "  No stuck stacks found."
fi

echo ""
echo "=== Teardown complete for environment: $ENV ==="
echo "Note: Resources with DeletionPolicy: Retain (KMS key, S3 bucket) are preserved."
