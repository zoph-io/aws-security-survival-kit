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
AlarmRecipient ?= "changeme@domain.com"
Project ?= aws-security-survival-kit
Description ?= Bare minimum AWS Security alerting
LocalAWSRegion ?= eu-west-1
CTLogGroupName ?= ""
Profile ?= "default"
#######################################################

account_level_security:
	@echo "==> Enable S3 Block Public Access (Account Level)"
	aws s3control put-public-access-block \
		--public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
		--account-id $(shell aws sts get-caller-identity --query Account --output text)
	@if [ $$? -eq 0 ]; then echo "✅ S3 Block Public Access"; fi
	@echo "==> Enable EBS Default Encryption (Region Level)"
	aws ec2 enable-ebs-encryption-by-default --region ${LocalAWSRegion}
	@if [ $$? -eq 0 ]; then echo "✅ EBS Default Encryption"; fi
	@echo "==> Enable AMI Block Public Access (Account Level)"
	aws ec2 enable-image-block-public-access \
		--image-block-public-access-state block-new-sharing
	@if [ $$? -eq 0 ]; then echo "✅ AMI Block Public Access"; fi

deploy: account_level_security
	aws cloudformation deploy \
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

	aws cloudformation deploy \
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
