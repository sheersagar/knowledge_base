# Advanced Permissions & Accounts

## 1. AWS Organizations
It allows larger businesses to manage multiple AWS accounts. You create organization in one account and can add other accounts to it. These accounts are called member accounts. The account where you create organization is called management account.

Organization root (a container of all accounts) is the root of the organization. It is the parent of all accounts in the organization.

    - Root is the parent of all accounts in the organization.
        - It contains OUs (Organizational Units) (they contain management account or member accounts)

### Arrangement of Organization Root, OUs and accounts inside it

![Organization Root](../../../Images/Organization_Root.png)
---
![Organization Unit Creation](../../../Images/OU_creation.png)

---
![Organization Units](../../../Images/OUs_account.png)

### Benefits
- Centralized billing
- Centralized management
- Centralized security
- Centralized compliance
- Centralized governance
- Centralized cost management
- Centralized access management
- Centralized policy management
    - Using Service control policies
- Centralized audit management
- Centralized logging management

![AWS Organizations](../../../Images/aws_organization.png)


### Service Control Policies (SCPs)
SCPs are optional guardrails for the permissions that can be granted to an IAM principal (an IAM user, group, or role) in your organization. SCPs do not directly grant permissions to users, groups, or roles. Instead, they define the maximum permissions that can be granted to an IAM principal in your organization.

Management account of Organization cannot be restricted using SCPs, hence we never keep critical resources in management account. We create a separate account for the same.

    -  Account permission boundaries and not service level permissions.
    - They limit what the account (including account root user) can do.
    - Allow list vs Deny list about certain services.

![SCPs](../../../Images/scp.png)
---


## 2. Security Token Service (STS)
- Generates temporary credentials (sts:AssumeRole*)
- Similar to access Keys but they expires and short terms.
- They have limited AWS resources access and requested by an Identity (AWS or External)

![STS Service](../../../Images/sts_service.png)

#### How to revoke temporary credentials 
![Revoke STS creds](../../../Images/revoke_sts_creds.png)

-   Revoke all existing sessions using an `Inline Policy` that deny for any sessions older than Current time.
- Bad Actor still have the valid temporary credentials but Deny Policy will take effect because of `sts:SessionIssuer` condition key.
- We do `Revoke Access` from the AWS Console IAM Role, and then it will add another policy mentioned below.
![Revoke All](../../../Images/revoke_session.png)

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Deny",
            "Action": [
                "*"
            ],
            "Resource": [
                "*"
            ],
            "Condition": {
                "DateLessThan": {
                    "aws:TokenIssueTime": "[policy creation time]"
                }
            }
        }
    ]
}
```

---

## 3. AWS Policy Interpretation Deep Dive
#### **Policy 1 Holiday Gifts**

```json

{
    "Version": "2012-10-17",
    "Statement": 
    [
      {
        "Effect":"Allow",
        "Action":[
           "s3:PutObject",
           "s3:PutObjectAcl",
           "s3:GetObject",
           "s3:GetObjectAcl",
           "s3:DeleteObject"
        ],
        "Resource":"arn:aws:s3:::holidaygifts/*"
      },
      {
        "Effect": "Deny",
        "Action": [
          "s3:GetObject",
          "s3:GetObjectAcl"
        ],
        "Resource":"arn:aws:s3:::holidaygifts/*",
        "Condition": {
            "DateGreaterThan": {"aws:CurrentTime": "2022-12-01T00:00:00Z"},
            "DateLessThan": {"aws:CurrentTime": "2022-12-25T06:00:00Z"}
        }
      }
    ]
}
```
- We have a [] square bracket representing a list with two Statement Blocks under which there are two {} curly braces, each representing a statement.
- Effect: It either Allow or Deny explicitly.
    - Implicit Deny: If something is not allowed, it is denied.
    - Explicit Deny: It always wins
- First with any Allow block.
    - It allows 5 Actions to occur.
    - Allow on a particular Resource:- * means everything under holidaygifts bucket.
- Second with Deny block.
    - It denies 2 Actions to occur but they are overlap with Allow block action inside the same resource.
- So now overlap Action for Explicit Deny will always win, irrespective if it is mentioned in Allow block.
- Condition: If this Deny block is called between the date block, then it will take effect else Allow block will take effect.
- >__Overall Effect__:- Users are allowed to perform the actions listed in the Allow block and denied to perform the actions listed in the Deny block with condition in deny block.


#### **Policy 2 Region**

```json

{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DenyNonApprovedRegions",
            "Effect": "Deny",
            "NotAction": [
                "cloudfront:*",
                "iam:*",
                "route53:*",
                "support:*"
            ],
            "Resource": "*",
            "Condition": {
                "StringNotEquals": {
                    "aws:RequestedRegion": [
                        "ap-southeast-2",
                        "eu-west-1"
                    ]
                }
            }
        }
    ]
}
```
- Effect: Deny and only one statement block.
    - Since everything is denied by default so, it is explicit deny. Which means only deny policy will be used with something allow because either we mention explicit deny or not, implicitly it will be denied.
- NotAction: It denies all actions except the ones listed.
- Resource: * means everything.
- Condition: StringNotEquals means it denies all regions except the ones listed.
- >__Overall Effect__:- Users are denied access to all actions except the ones listed in NotAction block and for all regions except the ones listed in Condition block.


#### **Policy 3** Home Folder

```json

{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListAllMyBuckets",
                "s3:GetBucketLocation"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::cl-animals4life",
            "Condition": {
                "StringLike": {
                    "s3:prefix": [
                        "",
                        "home/",
                        "home/${aws:username}/*"
                    ]
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::cl-animals4life/home/${aws:username}",
                "arn:aws:s3:::cl-animals4life/home/${aws:username}/*"
            ]
        }
    ]
}
```
- Statement [] block is a list of statements, with three Effects.
- First statement block is Allowed 2 Actions on *(all) resources.
    - Can check which region a bucket is in.
- Second statement block is Allow 1 Action (list) on a specific bucket but with a condition.
    - Condition: If String prefix are "" (root of bucket), "home/" (home_folder), "home/${aws:username}/*" (only their own home folder)
- Third statement block allows All S3 action.
    - On resource: Only S3 bucket cl-animals4life/home/${aws:username} and everything inside it.
- >__Overall Effect:__ Every IAM user can list all buckets and browse to home/ but can only read/write/delete inside their own home/<username>/ folder. No user can touch another user's folder.

```bash
How AWS Policy Variables work

${aws:username} is a runtime policy variable. When an IAM user makes an API call, AWS automatically resolves it to the actual username of the authenticated caller from their login session.

Example:

- User john logs in → AWS internally replaces ${aws:username} with john
- The resource becomes → arn:aws:s3:::cl-animals4life/home/john/*
- User alice logs in → resolves to → arn:aws:s3:::cl-animals4life/home/alice/*

-So the same policy is attached to all users (usually via a Group), but behaves differently for each user at runtime based on their session identity.

AWS reads the identity from the signed API request (via SigV4 signature + credentials), and matches it against the policy variables before evaluating permissions.
```

---
### Permission Boundaries and Use Cases
![Permission Boundary](../../../Images/permission_boundary.png)
- They are the json permission that will only tell if a user is allowed to perform a certain action vs Identity policies which actually gives those permissions.
- **Deligation Problem:-**
    - If one Admin User wants to give another user an administrator rights.
    - Then nothing stops the other Admin user to become full Administrator.
- To let this delegation happen we use Permission boundaries.
> Create user boundary Policy ---> Create IAM policy for Bob (admin user) + Admin Boundary -------> 

![Admin boundaries](../../../Images/permission_boundary_1.png)

__User Boundaries Policy__
```json
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Sid": "ServicesLimitViaBoundaries",
          "Effect": "Allow",
          "Action": [
              "s3:*",
              "cloudwatch:*",
              "ec2:*"
          ],
          "Resource": "*"
      },
      {
          "Sid": "AllowIAMConsoleForCredentials",
          "Effect": "Allow",
          "Action": [
              "iam:ListUsers","iam:GetAccountPasswordPolicy"
          ],
          "Resource": "*"
      },
      {
          "Sid": "AllowManageOwnPasswordAndAccessKeys",
          "Effect": "Allow",
          "Action": [
              "iam:*AccessKey*",
              "iam:ChangePassword",
              "iam:GetUser",
              "iam:*ServiceSpecificCredential*",
              "iam:*SigningCertificate*"
          ],
          "Resource": ["arn:aws:iam::*:user/${aws:username}"]
      }
  ]
}
```

__Admin Boundary Policy__
- This will tell what exactly a user can do with any identity policy they got.
- User can only perform actions that falls in common between boundary and Identity policy.
- In the first block it says if a user has no permission user_boundary, it will not let create a user to any admin user if that user has this Admin boundary.
```json
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Sid": "CreateOrChangeOnlyWithBoundary",
          "Effect": "Allow",
          "Action": [
              "iam:CreateUser",
              "iam:DeleteUserPolicy",
              "iam:AttachUserPolicy",
              "iam:DetachUserPolicy",
              "iam:PutUserPermissionsBoundary",
              "iam:PutUserPolicy"
          ],
          "Resource": "*",
          "Condition": {"StringEquals": 
              {"iam:PermissionsBoundary": "arn:aws:iam::<AWS-account-ID>:policy/a4luserboundary"}}
      },
      {
          "Sid": "CloudWatchAndOtherIAMTasks",
          "Effect": "Allow",
          "Action": [
              "cloudwatch:*",
              "iam:GetUser",
              "iam:ListUsers",
              "iam:DeleteUser",
              "iam:UpdateUser",
              "iam:CreateAccessKey",
              "iam:CreateLoginProfile",
              "iam:GetAccountPasswordPolicy",
              "iam:GetLoginProfile",
              "iam:ListGroups",
              "iam:ListGroupsForUser",
              "iam:CreateGroup",
              "iam:GetGroup",
              "iam:DeleteGroup",
              "iam:UpdateGroup",
              "iam:CreatePolicy",
              "iam:DeletePolicy",
              "iam:DeletePolicyVersion",
              "iam:GetPolicy",
              "iam:GetPolicyVersion",
              "iam:GetUserPolicy",
              "iam:GetRolePolicy",
              "iam:ListPolicies",
              "iam:ListPolicyVersions",
              "iam:ListEntitiesForPolicy",
              "iam:ListUserPolicies",
              "iam:ListAttachedUserPolicies",
              "iam:ListRolePolicies",
              "iam:ListAttachedRolePolicies",
              "iam:SetDefaultPolicyVersion",
              "iam:SimulatePrincipalPolicy",
              "iam:SimulateCustomPolicy" 
          ],
          "NotResource": "arn:aws:iam::<AWS-account-ID>:user/bob"
      },
      {
          "Sid": "NoBoundaryPolicyEdit",
          "Effect": "Deny",
          "Action": [
              "iam:CreatePolicyVersion",
              "iam:DeletePolicy",
              "iam:DeletePolicyVersion",
              "iam:SetDefaultPolicyVersion"
          ],
          "Resource": [
              "arn:aws:iam::<AWS-account-ID>:policy/a4luserboundary",
              "arn:aws:iam::<AWS-account-ID>:policy/a4ladminboundary"
          ]
      },
      {
          "Sid": "NoBoundaryUserDelete",
          "Effect": "Deny",
          "Action": "iam:DeleteUserPermissionsBoundary",
          "Resource": "*"
      }
  ]
}
```

__Admin permission policy__

```json
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Sid": "IAM",
          "Effect": "Allow",
          "Action": "iam:*",
          "Resource": "*"
      },
      {
          "Sid": "CloudWatchLimited",
          "Effect": "Allow",
          "Action": [
              "cloudwatch:GetDashboard",
              "cloudwatch:GetMetricData",
              "cloudwatch:ListDashboards",
              "cloudwatch:GetMetricStatistics",
              "cloudwatch:ListMetrics"
          ],
          "Resource": "*"
      }
  ]
}
```
---
## 4. Policy Evaluation Logic
![Policy evaluation](../../../Images/policy_evaluation_logic.png)
These are the policies that AWS use to decide what principal has what level of access of resources.
- Gather all of the policies that apply to that access requested.
- Explicit Deny ---> No ------> SCPs (only AWS Organization)
- If no or Allow SCPs ----> Resource policies (Policies that are separately attached to resources like S3, KMS, etc {Not All AWS resources support Resource policy})
- If no Resource policies ----> Permission boundary (if attached)
- If no Permission boundary ----> IAM policy

## 5. Resource Access Manager (RAM)
![RAM](../../../Images/RAM.png)
- Subnet by Owner is shared accross Organization.
---
- Shares AWS resource between `AWS Accounts.`
- `Products` (e.g., subnet) needs to support RAM.
- Shared resources can be accessed natively (Console UI or CLI).
- No cost for using RAM ---> Only the service cost.
- Owner account `creates a share`, provide a name.
- Owner retains full ownership.
- Define the `principal` with whom to share that resource.
- If participant is inside an ORG with sharing enabled it's `accepted automatically`.
- 

---
![Availability Zone](../../../Images/naming_AZ.png)
- AWS rotate their facility, your us-east-1a might be us-east-1b for another and vice-versa.
- AWS implemented Availability Zone IDs to rectify this confusion.
    - **use1-az1 and use1-az2** = They are consistent accross accounts.

