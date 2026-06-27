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
AlarmRecipient ?= hello@zoph.io
Project ?= aws-security-survival-kit
Description ?= Bare minimum AWS Security alerting and configuration
LocalAWSRegion ?= eu-west-1
CTLogGroupName ?= aws-cloudtrail-logs-567589703415-c7b72250

# Pass Profile=<name> to use a named AWS CLI profile. Leave empty (default)
# when credentials come from the environment (e.g. `aws-vault exec`, IAM Role,
# ECS task role) - in that case the --profile flag is omitted entirely.
Profile ?=
PROFILE_FLAG := $(if $(strip $(Profile)),--profile $(Profile),)

# Space-separated list of regions to SKIP during account_level_security.
# Use this for regions that are currently down, that you do not use, or
# that consistently 5xx (e.g. me-south-1 has had EC2 control-plane issues).
# Example: make deploy SkipRegions="me-south-1 ap-east-2"
SkipRegions ?=

# Per-API-call timeout. Without this, a single unreachable region can stall
# the hardening loop for several minutes (default AWS CLI socket timeout is
# 60s per call x 4 calls per region). 10s connect / 15s read fails fast.
AwsCliTimeouts := --cli-connect-timeout 10 --cli-read-timeout 15

# Optional S3 bucket(s) for CloudFormation template staging.
# Required once the templates grow past 51,200 bytes (CFN inline limit).
# Leave empty to attempt inline deploy. If your account has CFN's default
# managed bucket, it is named cf-templates-<random>-<region> - run
# `aws s3 ls | grep cf-templates` to find yours, or create one.
LocalS3Bucket  ?=
GlobalS3Bucket ?=
LOCAL_S3_FLAG  := $(if $(strip $(LocalS3Bucket)),--s3-bucket $(LocalS3Bucket) --s3-prefix assk,)
GLOBAL_S3_FLAG := $(if $(strip $(GlobalS3Bucket)),--s3-bucket $(GlobalS3Bucket) --s3-prefix assk,)

# ---- Optional detections (opt-in, default "false") ----
EnableS3PolicyDetection ?= "false"
EnableLambdaDetection ?= "false"
EnableSSODetection ?= "false"
EnableNetworkInfrastructureDetection ?= "false"
EnableIamTrustPolicyDetection ?= "false"
EnableOrganizationsDetection ?= "false"
EnableOrganizationsMembershipDetection ?= "false"
EnableIamEnumerationDetection ?= "false"

# ---- Existing-but-noisy detections (default ON for back-compat; flip to
# ---- "false" if alert fatigue is a problem in your environment) ----
EnableGetCallerIdentityDetection ?= "true"
EnableSecretsBatchGetDetection ?= "true"
EnableEc2PasswordDataDetection ?= "true"

# ---- Alarm tuning ----
AccessDeniedThreshold ?= 25

# ---- SNS encryption (optional CMK) ----
# Set EnableSnsEncryption="true" to create a dedicated KMS CMK for the SNS
# alerting topics. Cost consideration applies (KMS key + per-API-call charges).
# TrustedAccountIds is a comma-separated list of AWS account IDs that should be
# allowed to use the CMK (cross-account publish). Leave empty for single-account.
EnableSnsEncryption ?= "false"
TrustedAccountIds ?= ""
#######################################################

# Hardening across ALL enabled regions. The five APIs invoked here
# (enable-ebs-encryption-by-default, enable-image-block-public-access,
# enable-snapshot-block-public-access, modify-instance-metadata-defaults,
# ssm update-service-setting for public document sharing) are REGION-SCOPED,
# so applying them only to LocalAWSRegion leaves every other region
# unprotected. We loop over enabled+default-opted-in regions.
# S3 Block Public Access is account-scoped and only needs to run once.
account_level_security:
	@echo "==> Enable S3 Block Public Access (Account Level)"
	@aws s3control put-public-access-block \
		--public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
		--account-id $$(aws sts get-caller-identity --query Account --output text ${PROFILE_FLAG}) \
		${PROFILE_FLAG}
	@if [ $$? -eq 0 ]; then echo "✅ S3 Block Public Access Enabled (account)"; fi

	@echo "==> Apply region-scoped hardening across ALL enabled regions"
	@echo "    (SkipRegions='${SkipRegions}', per-call timeouts: connect=10s read=15s)"
	@SKIP=" ${SkipRegions} "; \
	for region in $$(aws ec2 describe-regions --all-regions \
			--filters "Name=opt-in-status,Values=opt-in-not-required,opted-in" \
			--query 'Regions[].RegionName' --output text ${PROFILE_FLAG}); do \
		case "$$SKIP" in *" $$region "*) \
			echo "  --> $$region [SKIPPED via SkipRegions]"; continue;; \
		esac; \
		echo "  --> $$region"; \
		aws ec2 enable-ebs-encryption-by-default --region $$region ${PROFILE_FLAG} ${AwsCliTimeouts} > /dev/null 2>&1 \
			&& echo "    ✅ EBS default encryption" \
			|| echo "    ⚠️  EBS default encryption skipped"; \
		aws ec2 enable-image-block-public-access --image-block-public-access-state block-new-sharing --region $$region ${PROFILE_FLAG} ${AwsCliTimeouts} > /dev/null 2>&1 \
			&& echo "    ✅ AMI block public sharing" \
			|| echo "    ⚠️  AMI block public sharing skipped"; \
		aws ec2 enable-snapshot-block-public-access --state block-new-sharing --region $$region ${PROFILE_FLAG} ${AwsCliTimeouts} > /dev/null 2>&1 \
			&& echo "    ✅ Snapshot block public sharing" \
			|| echo "    ⚠️  Snapshot block public sharing skipped"; \
		aws ec2 modify-instance-metadata-defaults --http-tokens required --http-put-response-hop-limit 2 --region $$region ${PROFILE_FLAG} ${AwsCliTimeouts} > /dev/null 2>&1 \
			&& echo "    ✅ IMDSv2 default" \
			|| echo "    ⚠️  IMDSv2 default skipped"; \
		aws ssm update-service-setting --setting-id /ssm/documents/console/public-sharing-permission --setting-value Disable --region $$region ${PROFILE_FLAG} ${AwsCliTimeouts} > /dev/null 2>&1 \
			&& echo "    ✅ SSM document public sharing blocked" \
			|| echo "    ⚠️  SSM document public sharing block skipped"; \
	done
	@echo "==> Region-scoped hardening complete"

deploy: account_level_security
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
			AccessDeniedThreshold=${AccessDeniedThreshold} \
			EnableS3PolicyDetection=${EnableS3PolicyDetection} \
			EnableLambdaDetection=${EnableLambdaDetection} \
			EnableSSODetection=${EnableSSODetection} \
			EnableNetworkInfrastructureDetection=${EnableNetworkInfrastructureDetection} \
			EnableGetCallerIdentityDetection=${EnableGetCallerIdentityDetection} \
			EnableSecretsBatchGetDetection=${EnableSecretsBatchGetDetection} \
			EnableEc2PasswordDataDetection=${EnableEc2PasswordDataDetection} \
			EnableSnsEncryption=${EnableSnsEncryption} \
			TrustedAccountIds=${TrustedAccountIds} \
		--no-fail-on-empty-changeset \
		${LOCAL_S3_FLAG} \
		${PROFILE_FLAG}
	@echo "==> Enabling termination protection on Local Stack"
	@aws cloudformation update-termination-protection \
		--region ${LocalAWSRegion} \
		--stack-name "${Project}-local" \
		--enable-termination-protection \
		${PROFILE_FLAG} > /dev/null
	@if [ $$? -eq 0 ]; then echo "✅ Termination protection enabled on ${Project}-local"; fi

	@echo "==> Deploying Global Stack (us-east-1)"
	@aws cloudformation deploy \
		--template-file ./cfn-global.yml \
		--region us-east-1 \
		--stack-name "${Project}-global" \
		--parameter-overrides \
			Project=${Project} \
			AlarmRecipient=${AlarmRecipient} \
			EnableIamTrustPolicyDetection=${EnableIamTrustPolicyDetection} \
			EnableOrganizationsDetection=${EnableOrganizationsDetection} \
			EnableOrganizationsMembershipDetection=${EnableOrganizationsMembershipDetection} \
			EnableIamEnumerationDetection=${EnableIamEnumerationDetection} \
			EnableSnsEncryption=${EnableSnsEncryption} \
			TrustedAccountIds=${TrustedAccountIds} \
		--no-fail-on-empty-changeset \
		${GLOBAL_S3_FLAG} \
		${PROFILE_FLAG}
	@echo "==> Enabling termination protection on Global Stack"
	@aws cloudformation update-termination-protection \
		--region us-east-1 \
		--stack-name "${Project}-global" \
		--enable-termination-protection \
		${PROFILE_FLAG} > /dev/null
	@if [ $$? -eq 0 ]; then echo "✅ Termination protection enabled on ${Project}-global"; fi

tear-down:
	@read -p "Are you sure that you want to destroy stack '${Project}'? [y/N]: " sure && [ $${sure:-N} = 'y' ]
	@echo "==> Disabling termination protection (required before delete)"
	-aws cloudformation update-termination-protection --region ${LocalAWSRegion} --stack-name "${Project}-local" --no-enable-termination-protection ${PROFILE_FLAG} > /dev/null
	-aws cloudformation update-termination-protection --region us-east-1 --stack-name "${Project}-global" --no-enable-termination-protection ${PROFILE_FLAG} > /dev/null
	aws cloudformation delete-stack --region ${LocalAWSRegion} --stack-name "${Project}-local" ${PROFILE_FLAG}
	aws cloudformation delete-stack --region us-east-1 --stack-name "${Project}-global" ${PROFILE_FLAG}

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
