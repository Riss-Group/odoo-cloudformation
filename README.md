# Odoo CloudFormation

This repository contains an AWS CloudFormation template and supporting scripts to deploy a production-ready Odoo environment on AWS. It is designed for the Riss-Group and supports scalable, secure, and automated Odoo deployments using AWS managed services.

## Overview
- Deploys Odoo on Ubuntu 22.04 ARM64 EC2 spot instances
- Uses AWS managed services: EFS, ElastiCache Redis, RDS PostgreSQL, S3
- CI/CD integration with CodeDeploy/CodePipeline
- Secure IAM, VPC, and Security Group configuration
- TLS/SSL via ACM
- Auto Scaling and Load Balancing

## Features
- Dynamic environment configuration via S3
- Automated Odoo installation and configuration
- Multi-AZ support for high availability
- Secure storage of secrets and credentials
- Customizable via CloudFormation parameters

## Prerequisites
- AWS account with permissions to deploy CloudFormation stacks and create resources
- Default VPC and subnets in your target region
- GitHub repository and token for CI/CD integration
- S3 buckets for scripts and artifacts

## Deployment
1. **Clone this repository**
2. **Prepare parameters:**
   - Gather your default subnet IDs (see below)
   - Prepare your GitHub token and repository info
   - Set up S3 buckets for scripts and artifacts
3. **Deploy the stack:**
   - Use the AWS Console or CLI to launch the CloudFormation stack
   - Provide all required parameters (see below)

### Example CLI Command
```sh
aws cloudformation create-stack \
  --stack-name odoo-prod \
  --template-body file://cloudformation-template.yaml \
  --parameters ParameterKey=DefaultSubnetIds,ParameterValue="subnet-xxxx,subnet-yyyy,subnet-zzzz" \
               ParameterKey=GitHubToken,ParameterValue=YOUR_GITHUB_TOKEN \
               ...
```
```sh
   aws cloudformation create-stack   --stack-name odoo-prod   --template-body file://cloudformation-template.yaml   --parameters file://params.json   --capabilities CAPABILITY_NAMED_IAM
```


## Parameters
- **DefaultSubnetIds**: List of default subnet IDs for your VPC (comma-separated)
- **PrimaryAZ**: Primary Availability Zone for EC2 fleet
- **DomainName**: Main domain for Odoo
- **GitHubOwner, GitHubRepo, GitHubToken**: GitHub repo info and token for CI/CD
- **RdsUser, RdsPassword**: RDS PostgreSQL credentials
- **AdminPasswd**: Odoo admin password
- **ScriptBucketName, ScriptKey**: S3 location for setup scripts
- **ArtifactBucketName**: S3 bucket for deployment artifacts
- **OdooVersion**: Odoo version (default: 18.0)
- **StagingMinSize, StagingMaxSize, ProdMinSize, ProdMaxSize**: Auto Scaling settings

## Security Notes
- **No secrets are stored in this repository.** All sensitive values are passed as parameters or environment variables at deployment time.
- IAM users and access keys are created for S3FS and are not stored in the repo.
- Ensure you use secure methods to manage and inject secrets (e.g., AWS Secrets Manager, SSM Parameter Store).

## Support
For issues or questions, please contact the Riss-Group DevOps team. 