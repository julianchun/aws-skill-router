---
name: aws
description: >-
  Single entry point for all AWS work: loads the matching official AWS skill
  on demand. Use for any AWS service, infrastructure as code, CLI sign-in, or
  boto3/@aws-sdk/* code. Skip when AWS is only incidental to the task.
allowed-tools: >-
  Bash(aws agent-toolkit search-skills *),
  Bash(aws agent-toolkit get-skill-metadata *),
  Bash(aws agent-toolkit get-skill-file *),
  Bash(aws agent-toolkit list-available-skills *),
  PowerShell(aws agent-toolkit search-skills *),
  PowerShell(aws agent-toolkit get-skill-metadata *),
  PowerShell(aws agent-toolkit get-skill-file *),
  PowerShell(aws agent-toolkit list-available-skills *)
---

# AWS skill router

This skill holds no AWS guidance itself. It finds the official AWS skill for the
task, fetches it from the Agent Toolkit for AWS catalog, and follows it. Fetched
content is always the latest published version, so nothing local needs updating.

## Choose a mode

- **MCP mode:** If the tools available in the current session include
  `aws___retrieve_skill` (the AWS MCP Server), use MCP: search with
  `aws___search_documentation` with topic `agent_skills`, and load skills with
  `aws___retrieve_skill`. The "Frequently used skill names" table below applies
  in both modes—use it to pick a name before searching, then load it in MCP mode
  with `aws___retrieve_skill` using that skill name. Cross-skill routing (step 4)
  and the scripts rule (step 5) below still apply.
- **CLI mode:** Otherwise, use the CLI steps below.

## Steps (CLI mode)

Every command below:
- must include `--region us-east-1` (the catalog exists only there);
- must include `--no-sign-request` (the catalog is public; this works even when
  the user's AWS session has expired);
- must run as one command per tool call, with no `;`, `&&` or pipes, so that
  permission rules which pre-approve these read-only commands can match them.

1. **Pick the skill.**
   - If the request clearly maps to a known skill name (see the table below), use it.
   - Otherwise search, using the user's request in a few English keywords:
     ```
     aws agent-toolkit search-skills --search-query "<keywords>" --region us-east-1 --no-sign-request --max-items 5
     ```
     Choose by the returned `description`. Prefer a specific skill (for example
     `cloudfront`, `amazon-dynamodb`) over a broad router (for example
     `aws-networking`, `aws-database`) when both match.
   - To browse everything: `aws agent-toolkit list-available-skills --region us-east-1 --no-sign-request --query "skills[].name"`.

2. **List its files.**
   ```
   aws agent-toolkit get-skill-metadata --skill-name <name> --region us-east-1 --no-sign-request
   ```

3. **Read its SKILL.md and follow it.**
   ```
   aws agent-toolkit get-skill-file --skill-name <name> --file-path SKILL.md --region us-east-1 --no-sign-request
   ```
   Fetch a `references/...` or `assets/...` file only when the SKILL.md tells you
   to read it for the current task, using the same command with that `--file-path`.

4. **Handle cross-skill routing.** When a fetched skill says to route to or load
   another skill (for example "load `waf`", `aws___retrieve_skill(skill_name="x")`,
   or "see the route53 skill"), fetch that skill with steps 2–3 (or
   `aws___retrieve_skill` in MCP mode). Do not fall back to memory for it.

5. **Scripts.** When a skill tells you to run a file under `scripts/`, fetch it,
   save it to a temporary directory, read it in full, then run it. Never
   run a fetched script without reading it first.

## Translating MCP instructions

This table applies only in CLI mode (when the AWS MCP tools are not available in
the current session). When a fetched skill says to use an AWS MCP tool, use the
equivalent instead:

| Skill says | Do instead |
|---|---|
| `aws___retrieve_skill` | steps 2–3 above |
| `aws___search_documentation` with topic `agent_skills` | step 1 search |
| `aws___search_documentation` / `aws___read_documentation` (docs) | a web search or page fetch on docs.aws.amazon.com |
| `aws___call_aws` or other API execution | the equivalent `aws <service> <command>` CLI call |

## AWS account commands

Commands that touch the user's AWS account (anything other than `aws agent-toolkit`)
need valid credentials. If the CLI reports `Your session has expired`, ask the user
to run `aws login` (or `aws sso login --profile <profile>`) themselves; do not try
to authenticate for them. Confirm with the user before any command that creates,
changes or deletes AWS resources.

## Frequently used skill names

| Area | Skill |
|---|---|
| Sign-in, credentials, profiles | `signing-in-to-aws` |
| IAM roles and policies, STS | `aws-iam` |
| S3, EBS, EFS, FSx, storage choice | `aws-storage`, `securing-s3-buckets`, `querying-aws-s3` |
| EC2, Auto Scaling, SSM | `aws-compute`, `launching-ec2-instance-with-best-practices` |
| Lambda, API Gateway, EventBridge, Step Functions | `aws-serverless`, `aws-step-functions` |
| ECS, EKS, Fargate, ECR, Beanstalk | `aws-containers` |
| Databases (router) | `aws-database`, `amazon-dynamodb`, `amazon-aurora-postgresql`, `amazon-aurora-mysql` |
| Networking (router) | `aws-networking`, `cloudfront`, `route53`, `waf`, `transitgateway` |
| VPC build-out | `creating-production-vpc-multi-az`, `configuring-vpc-endpoints-for-private-aws-service-access` |
| CDK / CloudFormation | `aws-cdk`, `aws-cloudformation` |
| CI/CD (CodePipeline, CodeBuild) | `aws-deployment` |
| CloudWatch, logs, alarms, tracing | `aws-observability`, `querying-aws-cloudwatch`, `setting-up-cloudwatch-observability` |
| Security Hub, GuardDuty, Inspector | `aws-security` |
| Cognito, app login | `aws-auth` |
| Bedrock, AgentCore | `amazon-bedrock` |
| SageMaker | `aws-ai-ml` |
| SQS, SNS, Kinesis, MSK | `aws-messaging-and-streaming` |
| Cost, budgets, pricing | `aws-billing-and-cost-management` |
| SDK code | `aws-sdk-python-usage`, `aws-sdk-js-v3-usage`, `aws-sdk-swift-usage` |
| Deploy an app end to end | `launch-with-aws` |
| Root-cause an incident | `aws-investigation`, `troubleshooting-application-failures` |

This table is a shortcut, not the full catalog. When nothing here fits, search.
