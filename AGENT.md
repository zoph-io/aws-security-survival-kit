# AGENT.md

Guidance for AI coding agents (Cursor, Claude Code, and similar) working in this repository. Humans should read `README.md` first.

## What this project is

The AWS Security Survival Kit (ASSK) is two CloudFormation stacks that wire EventBridge rules and CloudWatch alarms into an SNS topic to send actionable security alerts about an AWS account. It is intentionally small.

The goal: *"I would notice within minutes if something obviously bad happens in this AWS account"*, without paying for a SIEM. ASSK complements GuardDuty. It is not a SIEM, a SOAR, a remediation engine, or a multi-account orchestrator.

### Design principles (do not violate without discussion)

1. **Free or near-free.** Everything is serverless and pay-per-use. Typical accounts pay cents per month. New features must not push that into dollars without a clear opt-in flag and a documented cost note.
2. **No agents, no extra accounts, no SaaS.** Deploys into the account being monitored. No Lambda functions, no containers, no third-party integrations.
3. **Actionable alerts.** Every notification is a small, human-readable plain-text message (event name, account, region, principal, source IP, plus event-specific fields), formatted via `InputTransformer`. No JSON, no emoji, no raw CloudTrail blobs.
4. **Secure by default.** `make deploy` hardens the account before deploying the alerting stacks, and the alerting stacks themselves enable termination protection.
5. **Complements GuardDuty.** Do not duplicate what GuardDuty already covers. Focus on tampering and high-signal events GuardDuty misses.

## Repository layout

```
.
├── Makefile          # Entry point. Holds all per-deployment variables.
├── cfn-local.yml     # Regional stack: most EventBridge rules + CW alarms + SNS topic + optional CMK.
├── cfn-global.yml    # us-east-1 stack: global-service events (IAM, Organizations, ...) + SNS topic + optional CMK.
├── README.md         # User-facing documentation. MUST stay in sync with the templates and the Makefile.
├── AGENT.md          # This file. MUST stay in sync with project conventions.
├── LICENSE
└── assets/           # Screenshots referenced from README.md.
```

## Requirements

- **AWS CLI v2.**
- **`make`.**
- **`cfn-lint`** for template validation (`pip install cfn-lint` or `brew install cfn-lint`).
- **AWS credentials in the environment.** Either a named profile (`Profile` in `Makefile`) or env-injected credentials (`aws-vault exec`, IRSA, ECS task role, ...). The `Makefile` detects an empty `Profile` and omits the `--profile` flag, so both styles work.
- **A pre-existing CloudTrail trail** delivering to a CloudWatch Logs `LogGroup`. The `LogGroup` name is `CTLogGroupName`, the region is `LocalAWSRegion`.

## Common commands

```sh
cfn-lint cfn-local.yml cfn-global.yml         # validate templates
make -n deploy                                # show what `deploy` would run (recommended before any non-trivial change)
make account_level_security                   # cross-region account hardening only
make deploy                                   # hardening + both stacks + termination protection
make tear-down                                # disable protection + delete both stacks
```

For large templates (`cfn-local.yml` is already above the 51,200-byte inline CloudFormation deploy limit), set `LocalS3Bucket` and `GlobalS3Bucket` Makefile variables to existing buckets in the relevant regions. The deploy command then automatically uses `--s3-bucket ... --s3-prefix assk`.

## Conventions

### Adding a new EventBridge rule

1. **Choose the right template.**
   - `cfn-local.yml` for any regional service event (EC2, S3, Lambda, KMS, ...).
   - `cfn-global.yml` for global-service events (IAM, Organizations, Route 53 hosted zones, ...). Global-service CloudTrail events only surface in `us-east-1`.
2. **Always-on vs opt-in.**
   - Always-on is allowed only when the rule is genuinely high-signal and low-noise in any AWS account. When in doubt, make it opt-in.
   - Opt-in rules are introduced as a CloudFormation `Parameter` named `Enable<Name>Detection`, `Type: String`, `AllowedValues: ["true", "false"]`, `Default: "false"`, backed by a `Condition` named `<Name>DetectionEnabled`, and gated on the rule resource via `Condition: <Name>DetectionEnabled`.
3. **`EventPattern`.**
   - Prefer `prefix` matchers on `eventName` when AWS may add version suffixes (most of Lambda, some IAM).
   - Validate the pattern. EventBridge silently matches nothing for invalid patterns. (We caught a `"*.*.*.*/*"` bug this way.)
   - Use `wildcard` matchers for ARNs and other glob-like shapes.
4. **`InputTransformer`.** Every rule MUST use the project's plain-text key/value `InputTemplate` (no JSON, no emoji). The output is a clean multi-line message: a `"[ASSK] Security alert: <EventName>"` header, a blank line, then aligned `"Label: <Var>"` lines, with `Event ID` last. Each line is wrapped in double quotes so EventBridge strips the quotes and joins the lines with newlines (the documented way to emit multi-line plain text). Keep the eight base fields (Event, Account, Region, Time, Source IP, Principal, Identity, Event ID) and append any event-specific fields between Identity and Event ID. Look at `EventRuleConfigChanges` or `EventRuleSecurityGroupChanges` for the canonical pattern. Raw CloudTrail blobs in alerts are not acceptable.
5. **Target.** The stack's existing `CtAlertingTopic` SNS topic. Do not create per-rule topics.

### Adding a new parameter

1. Declare it in the relevant template's `Parameters` block with a clear `Description` and a sensible `Default`.
2. If it is a boolean toggle, use `Type: String` with `AllowedValues: ["true", "false"]`, paired with a `Condition`.
3. Plumb it through the `Makefile`: add a variable at the top of the file, then add the corresponding `<Name>=<value>` entry to the `--parameter-overrides` block in `deploy`.
4. Document it in `README.md` in the Parameters section.

### KMS and SNS

- The optional SNS CMK exists per stack (regional and `us-east-1`). The key policy must keep `events.amazonaws.com`, `cloudwatch.amazonaws.com`, and `chatbot.amazonaws.com` as `Service` principals with `kms:Decrypt` and `kms:GenerateDataKey*`. Removing any of these breaks alert delivery or Chatbot integration.
- The SNS topic policy must not grant `sns:Subscribe` via `Principal: "*"`. Subscribing happens through IAM permissions, not through the topic policy. Adding it back is a regression and a real exfiltration risk.

### Account-level hardening (`account_level_security` target)

- EBS default encryption, public AMI block, public snapshot block, IMDSv2 default, and the SSM document public-sharing block (`ssm update-service-setting --setting-id /ssm/documents/console/public-sharing-permission --setting-value Disable`) are **region-scoped APIs**. They must run in every enabled region, fetched via `aws ec2 describe-regions --filter Name=opt-in-status,Values=opt-in-not-required,opted-in`.
- S3 Block Public Access is **account-scoped** (single call), no loop needed.
- Per-call CLI timeouts (`--cli-connect-timeout 10 --cli-read-timeout 15`) are mandatory on every region-loop call so a down region cannot stall the loop.
- The `SkipRegions` Make variable exists for permanent exclusions (broken regions, regions the org has intentionally disabled in spirit but not via opt-in status).

## Validation before opening a PR

1. `cfn-lint cfn-local.yml cfn-global.yml` must pass without warnings.
2. `make -n deploy` must expand cleanly with the parameters you expect.
3. A live deploy to a sandbox AWS account is strongly recommended for any non-trivial change. The typical command is `aws-vault exec <profile> -- make deploy` with `Profile=""` in the `Makefile`.

## Documentation rule

`README.md` is the user-facing source of truth. `AGENT.md` is the agent-facing source of truth.

**Any change to `cfn-local.yml`, `cfn-global.yml`, or `Makefile` that adds, removes, or modifies a parameter, a detection rule, or a deployment step MUST be reflected in `README.md` in the same PR.** Concretely:

- New EventBridge rule: add an entry to the appropriate foldable list in "What it watches".
- New parameter: add a row to the relevant Parameters table.
- New `Makefile` target or changed `deploy` semantics: update the Quick Start section.
- Changed defaults: update the table and the related prose.

`AGENT.md` (this file) follows the same rule: any change to project conventions, layout, or workflow MUST be reflected here in the same PR.

If a change cannot be fully documented in the same PR, open a follow-up issue explicitly tracking the documentation debt. Documentation drift is a bug.

## Out of scope

The following are deliberate non-goals. Do not add them without a separate discussion with the maintainer:

- A SIEM, a SOAR, a remediation engine. ASSK alerts. It does not act.
- Per-rule fine-grained tuning UIs. Parameter overrides via the `Makefile` is the deliberate interface.
- Multi-account orchestration. ASSK deploys per-account; multi-account is a higher-order tool's job.
- Custom Lambda, EC2, or container infrastructure. Everything must be plain managed AWS primitives (EventBridge, SNS, CloudWatch, KMS).
- Deploying Organizations SCPs. SCPs require the management account and are an Org-level control. ASSK may **document** self-protection SCPs in `README.md` (see "Self-protection → Lock the kit with SCPs"), but it must not deploy or manage them.

## Related issues

- `#32`: original suggestions thread that motivated the latest batch of detections and hardening.
- `#33`: tracker for additional high-signal detection ideas. Partially implemented: `CreateLoginProfile` (folded into the IAM users rule), `PutKeyPolicy` (folded into the KMS rule), public Lambda URL (`AuthType: NONE`), `PutBucketReplication`, `CreateExportTask`, RDS `PubliclyAccessible`, `CreateClientVpnEndpoint`, and opt-in IAM enumeration (`EnableIamEnumerationDetection`). Remaining items still open.
- `#35`: AWS Organizations membership events (`AccountJoinedOrganization` / `AccountDepartedOrganization`) — implemented as the opt-in `EnableOrganizationsMembershipDetection` rules in `cfn-global.yml`.
- `#36`: account hardening — block public sharing of SSM documents (implemented in `account_level_security`).
- `#37`: dashboards — CloudWatch widgets covering every detection in the kit (implemented in both templates' `Dashboard` resource).
