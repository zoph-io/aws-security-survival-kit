# 🚑 AWS Security Survival Kit

## :brain: Rational

This AWS Security Survival Kit will allow you to set up minimal alerting on typical suspicious activities on your AWS Account.

You all know that CloudTrail is now the bare minimum service to activate on a newly created AWS Account to track all activities on your AWS account. It is nice, but suspicious activities will not come from themself to you. You still have to check periodically if something goes wrong.

With these templates, you will bring security observability to your AWS account, it's complementary to the GuardDuty service (There are no built-in alerts on GuardDuty).

## 💾 Suspicious Activities

Using this kit, you will deploy CloudWatch EventRules and CW alarms on all suspect activities below:

1. Root User activities
2. CloudTrail changes (`StopLogging`, `DeleteTrail`, `UpdateTrail`)
3. AWS Personal Health Dashboard Events
4. IAM Users Changes (`Create`, `Delete`, `Update`, `CreateAccessKey`, etc..)
5. MFA Monitoring (`CreateVirtualMFADevice` `DeactivateMFADevice` `DeleteVirtualMFADevice`, etc..)
6. Unauthorized Operations (`Access Denied`, `UnauthorizedOperation`)
7. Failed AWS Console login authentication

## :keyboard: Usage

Setup the correct parameters in the `Makefile`, then run the following command:

    $ make deploy

Setup [AWS Chatbot](https://aws.amazon.com/chatbot/) for best experience to get notified directly on Slack.

![Slack Alerts](./assets/slack-alert03.png)
![Slack Alerts](./assets/slack-alert02.png)

## :man_technologist: Credits

- :pirate_flag: AWS Security Boutique: [zoph.io](https://zoph.io)
- 💌 [AWS Security Digest Newsletter](https://awssecuritydigest.com)
- :bird: Twitter: [zoph](https://twitter.com/zoph)
