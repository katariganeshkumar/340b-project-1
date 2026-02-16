# 340B AWS Infrastructure

CloudFormation-based infrastructure for 340B project with Dev, QA, and Prod environments.

## Structure

```
340b-project-1/
├── main.yaml                 # Master nested stack (requires S3)
├── deploy.sh                 # Sequential deployment script (recommended)
├── delete.sh                 # Teardown script (reverse dependency order)
├── modules/
│   ├── network/
│   │   └── vpc.yaml          # VPC, subnets, NAT, security groups, Flow Logs
│   ├── security/
│   │   ├── kms.yaml          # KMS encryption key
│   │   └── waf.yaml          # WAF attached to ALB
│   ├── compute/
│   │   └── alb-asg.yaml      # ALB, ASG, Launch Template (Ubuntu)
│   ├── storage/
│   │   └── s3.yaml           # S3 bucket with KMS encryption
│   ├── connectivity/
│   │   ├── transit-gateway.yaml
│   │   ├── tgw-vpc-attachment.yaml
│   │   └── privatelink.yaml  # Interface endpoints + optional endpoint service
│   ├── monitoring/
│   │   └── cloudwatch.yaml   # Log groups, alarms
│   ├── dns/
│   │   └── route53.yaml      # Hosted zone, ALB alias record
│   └── certificates/
│       └── acm.yaml          # ACM certificate
└── environments/
    ├── dev/
    │   └── parameters.json
    ├── qa/
    │   └── parameters.json
    └── prod/
        └── parameters.json
```

## Resources Created

| Resource | Naming Pattern | Description |
|----------|----------------|-------------|
| VPC | 340b-{env}-vpc-{region} | 10.0.0.0/16 with 2 public + 2 private subnets |
| ALB | 340b-{env}-alb | Application Load Balancer |
| ASG | 340b-{env}-api-asg | Auto Scaling Group |
| EC2 | 340b-{env}-api-{region} | Ubuntu instances |
| WAF | 340b-{env}-waf-acl | Attached to ALB |
| TGW | 340b-{env}-tgw-{region} | Transit Gateway |
| VPC Endpoints | ECR, Logs, S3, STS | PrivateLink interface endpoints |

## Deployment

### Prerequisites

- AWS CLI configured
- `jq` for JSON parsing
- EC2 Key Pair (optional, for SSH to instances)

### Deploy with Script (Recommended)

```bash
# Deploy Dev environment
./deploy.sh dev

# Deploy with specific AWS profile
./deploy.sh prod my-aws-profile
```

### Teardown with Script

```bash
# Delete Dev environment
./delete.sh dev

# Delete with specific AWS profile
./delete.sh prod my-aws-profile
```

> **Note:** Resources with `DeletionPolicy: Retain` (KMS key, S3 bucket) are preserved after stack deletion.

### Deploy with Nested Stacks (main.yaml)

1. Upload templates to S3:
   ```bash
   aws s3 sync . s3://YOUR-BUCKET/340b-templates/ \
     --exclude "*.json" --exclude ".git/*" --exclude "deploy.sh"
   ```

2. Deploy master stack:
   ```bash
   aws cloudformation create-stack \
    --stack-name bmc340b-dev-master \
     --template-body file://main.yaml \
     --parameters \
       ParameterKey=Environment,ParameterValue=dev \
       ParameterKey=TemplateBucket,ParameterValue=YOUR-BUCKET \
       ParameterKey=TemplatePrefix,ParameterValue=340b-templates
   ```

## Parameterization

| Parameter | Description | Example |
|-----------|-------------|---------|
| Environment | dev, qa, prod | dev |
| Region | AWS region | us-west-1 |
| NamingPrefix | Resource prefix | 340b |
| VPCCidr | VPC CIDR | 10.0.0.0/16 |
| InstanceType | EC2 type | t3.micro |
| DomainName | For Route53/ACM | example.com |

## Cross-Stack References

- **Network** → Compute, TGW Attachment, PrivateLink
- **KMS** → Storage, Monitoring (log encryption)
- **Compute** → WAF, Monitoring, Route53
- **TGW** → TGW Attachment

## Post-Deployment

1. **ACM Certificate**: If using custom domain, validate the certificate via DNS in ACM console.
2. **Route53**: Update your domain's nameservers to the hosted zone if creating new zone.
3. **Key Pair**: Add `KeyName` to compute parameters for SSH access to EC2 instances.

## Notes

- VPC Flow Logs use CloudWatch Logs (optional KMS encryption)
- PrivateLink endpoint service requires NLB (set `EnableEndpointService: true` with NLB ARN)
- TGW routing: Set `TgwRouteDestinationCidr` for on-premises connectivity (e.g., 10.1.0.0/16)
