# 🚑 AWS Security Survival Kit

The smallest possible AWS account monitoring kit. Two CloudFormation stacks, ~30 EventBridge rules, an SNS topic. You get an email (or Slack / Teams via AWS Chatbot) the moment something interesting happens in your account. Free or near-free, no agents, no extra accounts, no SaaS.

## Why this exists

AWS gives you excellent logging (CloudTrail, VPC Flow Logs, Config) but very few alerts. GuardDuty covers a narrow slice (threat intel, anomaly detection on a few services). It does not tell you when:

- The root account just logged in.
- Someone disabled CloudTrail, deleted a KMS key, or stopped your GuardDuty detector.
- A new IAM user was created, or `AdministratorAccess` was attached to a role.
- A security group was opened on port 22 to `0.0.0.0/0`.
- A snapshot or AMI was shared with another AWS account.
- A flood of `AccessDenied` errors is happening (enumeration, misconfigured workload, compromised credential probing).
- Your own monitoring stack just got deleted.

ASSK is the minimum so that *"I would notice within minutes if something obviously bad happens"* is true for your AWS account. It complements GuardDuty. It is not a SIEM, a SOAR, or a full detection engineering practice.

## Quick start

1. Edit the variables at the top of the `Makefile` (`AlarmRecipient`, `Project`, `LocalAWSRegion`, `CTLogGroupName`).
2. Deploy:

```sh
make deploy
```

`make deploy` does three things, in order:

1. Hardens the account (S3 Block Public Access, EBS encryption, public AMI / snapshot block, IMDSv2 default, SSM document public-sharing block) across every enabled region.
2. Deploys both CloudFormation stacks (`-local` in your region, `-global` in `us-east-1`).
3. Enables CloudFormation stack termination protection on both stacks.

`make tear-down` disables termination protection and deletes both stacks.

## What it watches

<details>
<summary><b>Always-on detections</b> (CloudWatch alarms and EventBridge rules)</summary>

1. Root user activity
2. CloudTrail tampering (`StopLogging`, `DeleteTrail`, `UpdateTrail`)
3. AWS Health Dashboard events
4. IAM user changes (`Create`, `Delete`, `Update`, `CreateAccessKey`, `CreateLoginProfile`, `UpdateLoginProfile`, ...)
5. IAM admin escalation (`Attach*Policy` with `AdministratorAccess`)
6. MFA changes (`CreateVirtualMFADevice`, `DeactivateMFADevice`, `DeleteVirtualMFADevice`, ...)
7. AccessDenied / UnauthorizedOperation burst (alarm, threshold configurable, see Parameters)
8. Console login failures (alarm)
9. EBS snapshot exfiltration (`ModifySnapshotAttribute`, `SharedSnapshotCopyInitiated`, `SharedSnapshotVolumeCreated`)
10. AMI exfiltration (`ModifyImageAttribute`)
11. `sts:GetCallerIdentity` (flippable, see "may want to turn OFF" below)
12. IMDSv1 `RunInstances`
13. CloudShell exfiltration (`GetFileDownloadUrls`)
14. KMS key tampering (`DisableKey`, `ScheduleKeyDeletion`, `DeleteAlias`, `DisableKeyRotation`, `PutKeyPolicy`)
15. Security group ingress / egress changes
16. AWS Config tampering (`StopConfigurationRecorder`, `DeleteConfigurationRecorder`, `DeleteConfigRule`, `DeleteEvaluationResults`)
17. `ec2:GetPasswordData` (flippable, see "may want to turn OFF" below)
18. `secretsmanager:BatchGetSecretValue` (flippable, see "may want to turn OFF" below)
19. Route53 Resolver query-log deletion (`DeleteResolverQueryLogConfig`)
20. VPC Flow Logs (`DeleteFlowLogs`, `ModifyFlowLogs`)
21. Security group admin-port exposure IPv4 (22 / 3389 from `0.0.0.0/0`)
22. Security group admin-port exposure IPv6 (22 / 3389 from `::/0`)
23. IAM Roles Anywhere (`CreateProfile`, `CreateTrustAnchor`)
24. STS `GetFederationToken`
25. GuardDuty tampering (`DeleteDetector`, `UpdateDetector`, `DeletePublishingDestination`, `StopMonitoringMembers`, `CreateFilter` with `ARCHIVE`)
26. Self-protection (`DeleteStack`, `UpdateTerminationProtection` on `${Project}-*` stacks, see caveat below)
27. Public Lambda function URL (`CreateFunctionUrlConfig` / `UpdateFunctionUrlConfig` with `AuthType: NONE`)
28. S3 bucket replication configuration (`PutBucketReplication`)
29. CloudWatch Logs bulk export (`CreateExportTask`)
30. RDS instance made internet-facing (`CreateDBInstance` / `ModifyDBInstance` with `PubliclyAccessible: true`)
31. EC2 Client VPN endpoint creation (`CreateClientVpnEndpoint`)

</details>

<details>
<summary><b>Opt-in detections</b> (default off)</summary>

Off by default because they are noisy in IaC-heavy environments or only meaningful in specific account / region contexts.

| Detection | Parameter | Enable when |
| --- | --- | --- |
| S3 bucket policy / ACL / `PublicAccessBlock` changes | `EnableS3PolicyDetection` | You want to be alerted on any S3 access-surface change. |
| Lambda creation / code update / permission grants | `EnableLambdaDetection` | You do not deploy Lambdas frequently from IaC. |
| IAM Identity Center (SSO) permission sets and account assignments | `EnableSSODetection` | Only in the account and region of your SSO tenant. |
| VPC peering, routes, IGW | `EnableNetworkInfrastructureDetection` | You do not modify network infrastructure often. |
| IAM `UpdateAssumeRolePolicy` (trust policy changes) | `EnableIamTrustPolicyDetection` | You want to catch a common backdoor mechanism. |
| AWS Organizations tampering (`DetachPolicy`, `DeletePolicy`, `DisablePolicyType`, `LeaveOrganization`, `RemoveAccountFromOrganization`) | `EnableOrganizationsDetection` | Only in the Organizations management account. |
| AWS Organizations membership changes (`AccountJoinedOrganization`, `AccountDepartedOrganization` — incl. the async `Cleaned` finalization) | `EnableOrganizationsMembershipDetection` | Only in the Organizations management account. Very low volume; `Cleaned` can arrive ~90 days after a `CloseAccount`. |
| IAM enumeration / reconnaissance (`GetAccountAuthorizationDetails`, `GenerateCredentialReport`, `GenerateOrganizationsAccessReport`) | `EnableIamEnumerationDetection` | You want to catch IAM enumeration and your account does not run CSPM/IAM tooling that calls these routinely. |

</details>

<details>
<summary><b>Existing detections you may want to turn OFF</b></summary>

For backward compatibility these stay on, but they are alert-fatigue cannons in active accounts. Flip the parameter to `"false"` if your inbox is drowning.

| Detection | Parameter | Why it is noisy |
| --- | --- | --- |
| `sts:GetCallerIdentity` | `EnableGetCallerIdentityDetection` | Called on every AWS SDK init, every `terraform plan`, every CI step. |
| `secretsmanager:BatchGetSecretValue` | `EnableSecretsBatchGetDetection` | Called by ECS / EKS / Lambda when batch-loading secrets at startup. |
| `ec2:GetPasswordData` | `EnableEc2PasswordDataDetection` | Called by SSM and admin tooling on every Windows admin password fetch. |

</details>

<details>
<summary><b>Account-level hardening applied by <code>make deploy</code></b></summary>

1. S3 Block Public Access (account-scoped, single call).
2. EBS default encryption, in every enabled region.
3. Block public AMI sharing, in every enabled region. ([announcement](https://aws.amazon.com/about-aws/whats-new/2023/10/ami-block-public-enabled-aws-accounts-no-public-amis/))
4. Block public snapshot sharing, in every enabled region. ([blog post](https://aws.amazon.com/blogs/aws/new-block-public-sharing-of-amazon-ebs-snapshots/))
5. IMDSv2 required by default for new EC2 instances, in every enabled region. ([announcement](https://aws.amazon.com/about-aws/whats-new/2024/03/set-imdsv2-default-new-instance-launches/))
6. Block public sharing of SSM documents, in every enabled region. ([docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/documents-ssm-sharing.html#block-public-access)) SSM documents can embed scripts, parameters, and internal hostnames; AWS leaves public sharing *enabled* by default, so this closes the gap for free.

The region loop uses `aws ec2 describe-regions` with `opt-in-status in (opt-in-not-required, opted-in)`, so no manual region list is needed. Per-call CLI timeouts (`--cli-connect-timeout 10 --cli-read-timeout 15`) prevent a slow region from stalling the loop. Use `SkipRegions="us-west-1 me-south-1"` in the `Makefile` to permanently skip a region.

</details>

## Parameters

<details>
<summary><b>Core</b></summary>

| Parameter | Description |
| --- | --- |
| `AlarmRecipient` | Email address that receives alerts. |
| `Project` | Stack-name prefix (also matched by the self-protection rule). Default `aws-security-survival-kit`. |
| `LocalAWSRegion` | Region where the CloudTrail CloudWatch Logs `LogGroup` lives. Metric-filter alarms (AccessDenied, Failed Console Login, IMDSv1) are evaluated here. EventBridge rules in `cfn-local.yml` are deployed here. |
| `CTLogGroupName` | CloudTrail CloudWatch Logs `LogGroup` name. Required. |

</details>

<details>
<summary><b>Tuning</b></summary>

| Parameter | Default | Description |
| --- | --- | --- |
| `AccessDeniedThreshold` | `25` | Threshold for the AccessDenied alarm. Evaluated as `Period=3600s, EvaluationPeriods=2, Statistic=Sum`, so it fires when this many events or more occur in each of two consecutive 1-hour windows. Raised from the original `1` to absorb legitimate noise (SCP blocks, eventual-consistency lookups, idempotent retries). |

</details>

<details>
<summary><b>Optional SNS encryption at rest</b></summary>

| Parameter | Default | Description |
| --- | --- | --- |
| `EnableSnsEncryption` | `"false"` | When `"true"`, both SNS topics are encrypted at rest with a dedicated customer-managed KMS key (CMK). |
| `TrustedAccountIds` | `""` | Comma-separated list of AWS account IDs allowed to use the CMK for cross-account publish. Leave empty for single-account. |

**Cost note**: enabling encryption creates two CMKs (one per stack, regional and `us-east-1`). Expect roughly `$2/month` at rest plus per-call `GenerateDataKey` / `Decrypt` charges that scale with alert volume. The CMK key policy grants `kms:Decrypt` and `kms:GenerateDataKey*` to `events.amazonaws.com`, `cloudwatch.amazonaws.com`, and `chatbot.amazonaws.com`, so AWS Chatbot integration keeps working when encryption is enabled.

</details>

## Self-protection

### Built-in alert (best-effort)

The self-protection rule alerts on `DeleteStack` and `UpdateTerminationProtection` against any stack matching `${Project}-*` (matches both literal stack names and ARNs via `prefix` + `wildcard`).

`UpdateTerminationProtection` reliably fires (nothing is being deleted yet). `DeleteStack` is best-effort: the rule's SNS target lives in the same stack being deleted, so EventBridge and SNS are torn down concurrently with the rule trying to fire. For airtight self-protection use an SCP `Deny`, a watchdog stack in a separate account, or both.

### Lock the kit with SCPs (recommended, optional)

The alert above is *detective* — it tells you after the fact. To make ASSK genuinely tamper-resistant, pair it with *preventive* AWS Organizations [Service Control Policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) that deny anyone from deleting, disabling, or detaching the kit's own resources and the secure-by-default settings it applies.

ASSK does **not** deploy these SCPs itself: SCPs require AWS Organizations and must be attached from the **management account**, which is out of scope for a per-account kit (see `AGENT.md`). They are documented here so you can apply them with your existing landing-zone / Org tooling.

**Before you apply them, read these caveats:**

- SCPs only constrain **member accounts** in an Organization. The **management account is never restricted by SCPs** — keep ASSK alerting on it and protect it separately.
- The `aws:PrincipalARN` exclusions below are your **break-glass / deploy** escape hatch, so `make deploy` and emergency operators are not locked out. Replace the placeholder role ARNs:
  - `<ACCOUNT_ID>` — the account (or use `*` to apply org-wide via an OU).
  - `arn:aws:iam::*:role/OrgAdminBreakGlass` — your break-glass role.
  - `arn:aws:iam::*:role/assk-deployer` — the principal that runs `make deploy` (it must stay excluded, otherwise the next deploy / hardening pass is denied).
- **Close the wildcard bypass:** because the exclusion matches a role *name* across accounts, an attacker with `iam:CreateRole` could mint a role with that name to escape the `Deny`. Either use exact ARNs (no `*` account), or add a companion SCP that denies `iam:CreateRole` / `iam:CreateUser` for the protected names. Prefer paths/permission boundaries you control.
- This is `Deny`-by-policy: validate in a non-production OU first. Adjust `aws-security-survival-kit` if you changed the `Project` prefix, and `<CT_LOG_GROUP_NAME>` to match `CTLogGroupName`.

**SCP 1 — protect the ASSK resources** (stacks, EventBridge rules, SNS topics, alarms, metric filters):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProtectAsskStacks",
      "Effect": "Deny",
      "Action": ["cloudformation:DeleteStack", "cloudformation:UpdateTerminationProtection"],
      "Resource": "arn:aws:cloudformation:*:<ACCOUNT_ID>:stack/aws-security-survival-kit-*/*",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    },
    {
      "Sid": "ProtectAsskEventBridgeRules",
      "Effect": "Deny",
      "Action": ["events:DeleteRule", "events:DisableRule", "events:RemoveTargets", "events:PutRule", "events:PutTargets"],
      "Resource": "arn:aws:events:*:<ACCOUNT_ID>:rule/aws-security-survival-kit-*",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    },
    {
      "Sid": "ProtectAsskSnsTopics",
      "Effect": "Deny",
      "Action": ["sns:DeleteTopic", "sns:SetTopicAttributes", "sns:AddPermission", "sns:RemovePermission", "sns:Unsubscribe"],
      "Resource": "arn:aws:sns:*:<ACCOUNT_ID>:aws-security-survival-kit-alarm-topic-*",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    },
    {
      "Sid": "ProtectAsskAlarms",
      "Effect": "Deny",
      "Action": ["cloudwatch:DeleteAlarms", "cloudwatch:DisableAlarmActions", "cloudwatch:SetAlarmState"],
      "Resource": "arn:aws:cloudwatch:*:<ACCOUNT_ID>:alarm:*[aws-security-survival-kit]*",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    },
    {
      "Sid": "ProtectAsskMetricFilters",
      "Effect": "Deny",
      "Action": ["logs:DeleteMetricFilter"],
      "Resource": "arn:aws:logs:*:<ACCOUNT_ID>:log-group:<CT_LOG_GROUP_NAME>:*",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    }
  ]
}
```

**SCP 2 — lock the secure-by-default settings** applied by `make deploy` (S3 BPA, EBS encryption, AMI / snapshot public-sharing block, SSM document public sharing):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LockAccountHardening",
      "Effect": "Deny",
      "Action": [
        "s3:PutAccountPublicAccessBlock",
        "ec2:DisableEbsEncryptionByDefault",
        "ec2:DisableImageBlockPublicAccess",
        "ec2:DisableSnapshotBlockPublicAccess"
      ],
      "Resource": "*",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    },
    {
      "Sid": "LockSsmDocumentSharingSetting",
      "Effect": "Deny",
      "Action": ["ssm:UpdateServiceSetting", "ssm:ResetServiceSetting"],
      "Resource": "arn:aws:ssm:*:<ACCOUNT_ID>:servicesetting/ssm/documents/console/public-sharing-permission",
      "Condition": { "ArnNotLike": { "aws:PrincipalARN": [
        "arn:aws:iam::*:role/OrgAdminBreakGlass",
        "arn:aws:iam::*:role/assk-deployer"
      ] } }
    }
  ]
}
```

**Optional companions** (add to SCP 2 if they fit your environment): `ec2:ModifyInstanceMetadataDefaults` to freeze the IMDSv2 default; `kms:ScheduleKeyDeletion` / `kms:DisableKey` / `kms:DisableKeyRotation` / `kms:PutKeyPolicy` scoped to the optional SNS CMKs; and `cloudtrail:StopLogging` / `cloudtrail:DeleteTrail` / `cloudtrail:UpdateTrail` + `logs:DeleteLogGroup` on `<CT_LOG_GROUP_NAME>` to protect the CloudTrail data source ASSK depends on.

> Each SCP must stay under the 5,120-character limit. If you hit it, split the statements across multiple policies, or drop the per-statement `Condition` blocks in favor of a single Organization-wide deny SCP plus a narrowly-scoped `Allow` for break-glass.

## SNS topic policy

The alerting topic's resource policy intentionally does not grant `sns:Subscribe` to in-account principals via `Principal: "*"`. A compromised role with `sns:Subscribe` only via topic policy could otherwise add an attacker email / HTTPS endpoint and silently exfiltrate every security alert. Subscribing still works for principals that hold `sns:Subscribe` via IAM (the normal admin flow).

## Notifications

Alerts are delivered by email through the SNS topic, as clean plain-text messages (no JSON, no emoji). Each `InputTransformer` renders a readable, scannable body:

```
[ASSK] Security alert: StopLogging

Event:     StopLogging
Account:   123456789012
Region:    eu-west-1
Time:      2026-06-26T14:32:10Z
Source IP: 203.0.113.10
Principal: AROAEXAMPLE123:session
Identity:  my-admin-role
Event ID:  a1b2c3d4-5678-90ab-cdef-EXAMPLE
```

Rules that carry extra context add it between `Identity` and `Event ID` (for example `KeyId`, `BucketName`, `GroupId`, `StackName`). The same plain-text body is what AWS Chatbot renders into Slack / Teams.

Two delivery caveats are inherent to SNS email and apply regardless of formatting: the body is plain text only (no HTML, bold, or links), and the email subject line stays the generic "AWS Notification Message" because EventBridge cannot set the SNS subject. Customizing either would require SES or a Lambda, both of which are deliberately out of scope.

## ChatOps

Set up [AWS Chatbot](https://aws.amazon.com/chatbot/) to get notified directly on Slack or Microsoft Teams.

## Dashboards

ASSK ships two CloudWatch dashboards for at-a-glance visibility on suspicious activity:

- **`AWS-Security-Survival-Kit-Dashboard-<region>`** (Local stack) — metric-filter alarm graphs (Access Denied, failed console logins, IMDSv1 launches), plus EventBridge rule-invocation graphs grouped by category (*defense evasion / detection tampering*, *data exfiltration*, *network exposure*, *identity / reconnaissance*), plus CloudWatch Logs Insights tables for fast triage (latest Access Denied events, recent IMDSv1 launches, CloudTrail changes).
- **`AWS-Security-Survival-Kit-Dashboard-Global`** (Global stack, `us-east-1`) — an all-rules overview plus rule-invocation graphs for *root & privileged identity*, *IAM users & MFA*, *account & org tampering*, and *AWS Health*.

Every detection shipped by the kit appears on a dashboard. Rule-invocation widgets read the `AWS/Events` `Invocations` metric per rule, so a **flat line at zero means the detection is armed and nothing matched** (the metric only materializes after a rule first fires). Opt-in detections (`Enable*Detection`) only report data once enabled.

**Cost note:** AWS includes 3 dashboards in the always-free tier; ASSK uses 2, so dashboards stay free. The Logs Insights table widgets run a query on each load/refresh (billed per GB scanned) — the queries use tight `limit`s to keep this negligible. Adding more dashboards (beyond the 3 free) costs ~$3/dashboard/month.

## Credits

- AWS security boutique: [zoph.io](https://zoph.io)
- BlueSky: [@zoph](https://bsky.app/zoph.me)
- X: [@zoph](https://x.com/zoph)

## Other initiatives

- [Azure Security Survival Kit](https://github.com/O3-Cyber/azure-security-survival-kit) by [O3 Cyber](https://www.o3c.no/).
