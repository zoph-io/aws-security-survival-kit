.DEFAULT_GOAL ?= help
.PHONY: help

help:
	@echo "${Project}"
	@echo "${Description}"
	@echo ""
	@echo "	deploy - deploy aws security survival kit templates"
	@echo "	---"
	@echo "	tear-down - destroy CloudFormation stacks"
	@echo "	clean - clean temp folders"

###################### Parameters ######################
AlarmRecipient ?= "hello@zoph.io"
Project ?= "aws-security-survival-kit"
Description ?= "Bare minimum AWS Security alerting and configuration"
LocalAWSRegion ?= "eu-west-1"
CTLogGroupName ?= "aws-cloudtrail-logs-567589703415-c7b72250"
Profile ?= ""
#######################################################

account_level_security:
# Block S3 Bucket Public Access
	@echo "==> Enable S3 Block Public Access (Account Level)"
	@aws s3control put-public-access-block \
		--public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
		--account-id $(shell aws sts get-caller-identity --query Account --output text)
	@if [ $$? -eq 0 ]; then echo "✅ S3 Block Public Access Enabled"; fi

# Enable EBS Default Encryption
	@echo "==> Enable EBS Default Encryption (Region Level)"
	@aws ec2 enable-ebs-encryption-by-default \
		--region ${LocalAWSRegion}
	@if [ $$? -eq 0 ]; then echo "✅ EBS Default Encryption Enabled" ; fi

# Enable AMI Block Public Access (New Sharing Only)
	@echo "==> Enable AMI Block Public Access (Region Level)"
	@aws ec2 enable-image-block-public-access \
		--image-block-public-access-state block-new-sharing \
		--region ${LocalAWSRegion}
	@if [ $$? -eq 0 ]; then echo "✅ AMI Block Public Access Enabled"; fi

# Enable Snapshot Block Public Access (New Sharing Only)
	@echo "==> Enable Snapshot Block Public Access (Region Level)"
	@aws ec2 enable-snapshot-block-public-access \
		--state block-new-sharing \
		--region ${LocalAWSRegion}
	@if [ $$? -eq 0 ]; then echo "✅ Snapshot Block Public Access Enabled"; fi

# Enable Instance Metadata Service Version 2 Default
	@echo "==> Enable IMDSv2 by Default (Region Level)"
	@aws ec2 modify-instance-metadata-defaults \
		--region ${LocalAWSRegion} \
		--http-tokens required \
		--http-put-response-hop-limit 2
	@if [ $$? -eq 0 ]; then echo "✅ IMDSv2 is now set by default"; fi

deploy: #account_level_security
	@echo "==> Deploying Local Stack (${LocalAWSRegion})"
	@aws cloudformation deploy \
		--template-file ./cfn-local.yml \
		--region ${LocalAWSRegion} \
		--stack-name "${Project}-local" \
		--parameter-overrides \
			Project=${Project} \
			Region=${LocalAWSRegion} \
			AlarmRecipient=${AlarmRecipient} \
			CTLogGroupName=${CTLogGroupName} \
		--no-fail-on-empty-changeset \
		--profile ${Profile}

	@echo "==> Deploying Global Stack (us-east-1)"
	@aws cloudformation deploy \
		--template-file ./cfn-global.yml \
		--region us-east-1 \
		--stack-name "${Project}-global" \
		--parameter-overrides \
			Project=${Project} \
			AlarmRecipient=${AlarmRecipient} \
		--no-fail-on-empty-changeset \
		--profile ${Profile}

tear-down:
	@read -p "Are you sure that you want to destroy stack '${Project}'? [y/N]: " sure && [ $${sure:-N} = 'y' ]
	aws cloudformation delete-stack --region ${LocalAWSRegion} --stack-name "${Project}-local" --profile ${Profile}
	aws cloudformation delete-stack --region us-east-1 --stack-name "${Project}-global" --profile ${Profile}

clean:
	@rm -fr temp/
	@rm -fr dist/
	@rm -fr htmlcov/
	@rm -fr site/
	@rm -fr .eggs/
	@rm -fr .tox/
	@find . -name '*.egg-info' -exec rm -fr {} +
	@find . -name '.DS_Store' -exec rm -fr {} +
	@find . -name '*.egg' -exec rm -f {} +
	@find . -name '*.pyc' -exec rm -f {} +
	@find . -name '*.pyo' -exec rm -f {} +
	@find . -name '*~' -exec rm -f {} +
	@find . -name '__pycache__' -exec rm -fr {} +
