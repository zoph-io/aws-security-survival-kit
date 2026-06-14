# 🚑 AWS Security Survival Kit

The smallest possible AWS account monitoring kit. Two CloudFormation stacks, ~25 EventBridge rules, an SNS topic. You get an email (or Slack / Teams via AWS Chatbot) the moment something interesting happens in your account. Free or near-free, no agents, no extra accounts, no SaaS.

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

1. Hardens the account (S3 Block Public Access, EBS encryption, public AMI / snapshot block, IMDSv2 default) across every enabled region.
2. Deploys both CloudFormation stacks (`-local` in your region, `-global` in `us-east-1`).
3. Enables CloudFormation stack termination protection on both stacks.

`make tear-down` disables termination protection and deletes both stacks.

## What it watches

<details>
<summary><b>Always-on detections</b> (CloudWatch alarms and EventBridge rules)</summary>

1. Root user activity
2. CloudTrail tampering (`StopLogging`, `DeleteTrail`, `UpdateTrail`)
3. AWS Health Dashboard events
4. IAM user changes (`Create`, `Delete`, `Update`, `CreateAccessKey`, `UpdateLoginProfile`, ...)
5. IAM admin escalation (`Attach*Policy` with `AdministratorAccess`)
6. MFA changes (`CreateVirtualMFADevice`, `DeactivateMFADevice`, `DeleteVirtualMFADevice`, ...)
7. AccessDenied / UnauthorizedOperation burst (alarm, threshold configurable, see Parameters)
8. Console login failures (alarm)
9. EBS snapshot exfiltration (`ModifySnapshotAttribute`, `SharedSnapshotCopyInitiated`, `SharedSnapshotVolumeCreated`)
10. AMI exfiltration (`ModifyImageAttribute`)
11. `sts:GetCallerIdentity` (flippable, see "may want to turn OFF" below)
12. IMDSv1 `RunInstances`
13. CloudShell exfiltration (`GetFileDownloadUrls`)
14. KMS key tampering (`DisableKey`, `ScheduleKeyDeletion`, `DeleteAlias`, `DisableKeyRotation`)
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

## Self-protection caveat

The self-protection rule alerts on `DeleteStack` and `UpdateTerminationProtection` against any stack matching `${Project}-*` (matches both literal stack names and ARNs via `prefix` + `wildcard`).

`UpdateTerminationProtection` reliably fires (nothing is being deleted yet). `DeleteStack` is best-effort: the rule's SNS target lives in the same stack being deleted, so EventBridge and SNS are torn down concurrently with the rule trying to fire. For airtight self-protection use an SCP `Deny`, a watchdog stack in a separate account, or both.

## SNS topic policy

The alerting topic's resource policy intentionally does not grant `sns:Subscribe` to in-account principals via `Principal: "*"`. A compromised role with `sns:Subscribe` only via topic policy could otherwise add an attacker email / HTTPS endpoint and silently exfiltrate every security alert. Subscribing still works for principals that hold `sns:Subscribe` via IAM (the normal admin flow).

## Notifications

Alerts are delivered by email through the SNS topic.

![Email Notification](./assets/notification.png)

## ChatOps

Set up [AWS Chatbot](https://aws.amazon.com/chatbot/) to get notified directly on Slack or Microsoft Teams.

## Dashboards

ASSK ships two CloudWatch dashboards (Local and Global) for at-a-glance visibility on suspicious activity.

## Credits

- AWS security boutique: [zoph.io](https://zoph.io)
- BlueSky: [@zoph](https://bsky.app/zoph.me)
- X: [@zoph](https://x.com/zoph)

## Other initiatives

- [Azure Security Survival Kit](https://github.com/O3-Cyber/azure-security-survival-kit) by [O3 Cyber](https://www.o3c.no/).
