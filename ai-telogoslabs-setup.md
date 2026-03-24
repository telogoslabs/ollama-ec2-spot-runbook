# ai.telogoslabs.com — Infrastructure Setup Checklist

One-time setup tasks. Work through each section in order.  
Check off each item only after you have verified the output.

---

## Prerequisites

Before starting, confirm you have the following available:

- [ ] AWS CLI installed and configured (`aws configure`)
- [ ] `jq` installed (`brew install jq` / `apt install jq`)
- [ ] An EC2 key pair already exists, or you are ready to create one
- [ ] You know your current public IP for SSH access

```bash
# Verify CLI is working and shows the right account
aws sts get-caller-identity

# Get your current public IP
curl -s https://checkip.amazonaws.com
```

**Record these values — you will need them throughout:**

| Item | Value |
|------|-------|
| AWS Account ID | |
| Your public IP (for SSH) | |
| Instance region (e.g. us-east-2) | |

>We can actually script out the public ip via the aws  
curl https://checkip.amazonaws.com

---

## Section 1 — Certificates (ACM)

> ACM certificates for CloudFront **must** be created in `us-east-1` regardless of where your instance runs.

### 1.1 Confirm existing wildcard cert

```bash
aws acm list-certificates \
  --region us-east-1 \
  --query "CertificateSummaryList[?contains(DomainName, 'telogoslabs.com')]"
```

- [ ] A `*.telogoslabs.com` certificate exists in us-east-1
- [ ] Its status is `ISSUED` (not `PENDING_VALIDATION`)

**Record:**

| Item | Value |
|------|-------|
| ACM Certificate ARN | |

```
*.telogoslabs.com     |  arn:aws:acm:us-east-1:547532908687:certificate/7624fe68-9631-4796-8466-b57482a9a85a
```

> If the cert is missing or in the wrong region, request a new one:
> ```bash
> aws acm request-certificate \
>   --region us-east-1 \
>   --domain-name "*.telogoslabs.com" \
>   --validation-method DNS
> ```
> Then add the DNS validation CNAME that ACM gives you to Route 53 and wait for status to become `ISSUED`.

---

## Section 2 — Route 53

### 2.1 Confirm hosted zone exists

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='telogoslabs.com.']"

agpial@agpial-asus-amd:~/TelogosLabs/ollama-ec2-spot-runbook$ aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='telogoslabs.com.']"
[
    {
        "Id": "/hostedzone/Z04656781DJQ2OTU4E4HT",
        "Name": "telogoslabs.com.",
        "CallerReference": "RISWorkflow-RD:2f9ae655-1669-42eb-8f58-fee779da8ec4",
        "Config": {
            "Comment": "HostedZone created by Route53 Registrar",
            "PrivateZone": false
        },
        "ResourceRecordSetCount": 9
    }
]
```

- [ ] Hosted zone for `telogoslabs.com` exists
- [ ] It is a **Public** hosted zone

**Record:**

| Item | Value |
|------|-------|
| Hosted Zone ID | /hostedzone/Z04656781DJQ2OTU4E4HT|

### 2.2 Confirm no conflicting A record for ai subdomain

```bash
# Replace Z1234567890ABC with your hosted zone ID
aws route53 list-resource-record-sets \
  --hosted-zone-id Z04656781DJQ2OTU4E4HT \
  --query "ResourceRecordSets[?Name=='ai.telogoslabs.com.']"
```

- [ ] No existing A record for `ai.telogoslabs.com` — or you are happy to overwrite it

---

## Section 3 — S3 Fallback Bucket

### 3.1 Choose a bucket name

S3 bucket names are global. Suggested: `ai-telogoslabs-fallback`

```bash
# Check the name is available (should return an error if it doesn't exist yet — that's fine)
aws s3api head-bucket --bucket ai-telogoslabs-fallback 2>&1
```

- [x] Bucket name is available

**Record:**

| Item | Value |
|------|-------|
| Bucket name | |
| Bucket region | |

### 3.2 Create the bucket

```bash
aws s3 mb s3://ai-telogoslabs-fallback --region us-east-1
```

- [ ] Bucket created successfully

### 3.3 Enable static website hosting

```bash
aws s3 website s3://ai-telogoslabs-fallback \
  --index-document index.html \
  --error-document index.html
```

- [ ] Static hosting enabled

### 3.4 Disable block public access

```bash
aws s3api put-public-access-block \
  --bucket ai-telogoslabs-fallback \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
```

- [ ] Block public access disabled

### 3.5 Apply public read bucket policy

```bash
aws s3api put-bucket-policy \
  --bucket ai-telogoslabs-fallback \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::ai-telogoslabs-fallback/*"
    }]
  }'
```

- [ ] Bucket policy applied

### 3.6 Upload fallback page

Create your `index.html` fallback and upload it:

```bash
aws s3 cp index.html s3://ai-telogoslabs-fallback/index.html \
  --content-type "text/html"
```

- [ ] Fallback page uploaded
- [ ] Verify it loads: `http://ai-telogoslabs-fallback.s3-website-us-east-1.amazonaws.com`

---

## Section 4 — CloudFront Distribution

### 4.1 Create the distribution

This creates the distribution with:
- Primary origin: placeholder IP `1.1.1.1` (boot script will update this)
- Fallback origin: S3 bucket
- Origin Group with automatic failover on 5xx
- ACM wildcard cert for TLS

```bash
# Set your values first
ACM_CERT_ARN="arn:aws:acm:us-east-1:YOUR_ACCOUNT:certificate/YOUR_CERT_ID"
BUCKET_NAME="ai-telogoslabs-fallback"
DOMAIN="ai.telogoslabs.com"

aws cloudfront create-distribution \
  --distribution-config "{
    \"CallerReference\": \"$(date +%s)\",
    \"Aliases\": {\"Quantity\": 1, \"Items\": [\"${DOMAIN}\"]},
    \"Origins\": {
      \"Quantity\": 2,
      \"Items\": [
        {
          \"Id\": \"spot-instance\",
          \"DomainName\": \"1.1.1.1\",
          \"CustomOriginConfig\": {
            \"HTTPPort\": 80, \"HTTPSPort\": 443,
            \"OriginProtocolPolicy\": \"http-only\",
            \"OriginReadTimeout\": 10,
            \"OriginKeepaliveTimeout\": 5
          }
        },
        {
          \"Id\": \"s3-fallback\",
          \"DomainName\": \"${BUCKET_NAME}.s3-website-us-east-1.amazonaws.com\",
          \"CustomOriginConfig\": {
            \"HTTPPort\": 80, \"HTTPSPort\": 443,
            \"OriginProtocolPolicy\": \"http-only\"
          }
        }
      ]
    },
    \"OriginGroups\": {
      \"Quantity\": 1,
      \"Items\": [{
        \"Id\": \"failover-group\",
        \"FailoverCriteria\": {
          \"StatusCodes\": {\"Quantity\": 4, \"Items\": [500,502,503,504]}
        },
        \"Members\": {
          \"Quantity\": 2,
          \"Items\": [{\"OriginId\": \"spot-instance\"},{\"OriginId\": \"s3-fallback\"}]
        }
      }]
    },
    \"DefaultCacheBehavior\": {
      \"TargetOriginId\": \"failover-group\",
      \"ViewerProtocolPolicy\": \"redirect-to-https\",
      \"CachePolicyId\": \"4135ea2d-6df8-44a3-9df3-4b5a84be39ad\",
      \"AllowedMethods\": {
        \"Quantity\": 7,
        \"Items\": [\"GET\",\"HEAD\",\"OPTIONS\",\"PUT\",\"POST\",\"PATCH\",\"DELETE\"],
        \"CachedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\",\"HEAD\"]}
      },
      \"Compress\": true
    },
    \"ViewerCertificate\": {
      \"ACMCertificateArn\": \"${ACM_CERT_ARN}\",
      \"SSLSupportMethod\": \"sni-only\",
      \"MinimumProtocolVersion\": \"TLSv1.2_2021\"
    },
    \"HttpVersion\": \"http2\",
    \"Enabled\": true,
    \"Comment\": \"ai.telogoslabs.com\",
    \"DefaultRootObject\": \"\"
  }"
```

- [ ] Distribution created — note the ID and domain name from the output

**Record:**

| Item | Value |
|------|-------|
| CloudFront Distribution ID | |
| CloudFront Domain (e.g. dxxxx.cloudfront.net) | |

### 4.2 Verify distribution status

CloudFront takes 5–10 minutes to deploy. Check status:

```bash
aws cloudfront get-distribution \
  --id YOUR_DIST_ID \
  --query "Distribution.Status"
```

- [ ] Status is `Deployed` (not `InProgress`)

---

## Section 5 — Route 53 Alias to CloudFront

> Do this **after** the CloudFront distribution is `Deployed`.  
> CloudFront's hosted zone ID is always `Z2FDTNDATAQYW2` — this is an AWS constant, not yours.

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "ai.telogoslabs.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "YOUR_CF_DOMAIN.cloudfront.net",
          "EvaluateTargetHealth": false
        }
      }
    }]
  }'
```

- [ ] Record created
- [ ] Verify DNS resolves: `dig ai.telogoslabs.com` — should return CloudFront IPs
- [ ] Verify HTTPS loads fallback page: `https://ai.telogoslabs.com`

---

## Section 6 — IAM Role for Spot Instance

The instance needs permission to update the CloudFront origin on boot.  
Replace `YOUR_DIST_ID` with the distribution ID from Section 4.

### 6.1 Create the role

```bash
aws iam create-role \
  --role-name "spot-ai-instance-role" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'
```

- [ ] Role created

### 6.2 Attach permissions policy

```bash
aws iam put-role-policy \
  --role-name "spot-ai-instance-role" \
  --policy-name "spot-ai-permissions" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "cloudfront:GetDistributionConfig",
          "cloudfront:UpdateDistribution"
        ],
        "Resource": "arn:aws:cloudfront::YOUR_ACCOUNT_ID:distribution/YOUR_DIST_ID"
      },
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject"],
        "Resource": "arn:aws:s3:::ai-telogoslabs-fallback/*"
      }
    ]
  }'
```

- [ ] Policy attached

### 6.3 Create instance profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "spot-ai-instance-profile"

aws iam add-role-to-instance-profile \
  --instance-profile-name "spot-ai-instance-profile" \
  --role-name "spot-ai-instance-role"
```

- [ ] Instance profile created
- [ ] Role added to profile
- [ ] Verify: `aws iam get-instance-profile --instance-profile-name spot-ai-instance-profile`

---

## Section 7 — Security Group

### 7.1 Get your default VPC

```bash
aws ec2 describe-vpcs \
  --region YOUR_INSTANCE_REGION \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text
```

**Record:**

| Item | Value |
|------|-------|
| VPC ID | |

### 7.2 Create security group

```bash
aws ec2 create-security-group \
  --region YOUR_INSTANCE_REGION \
  --group-name "spot-ai-sg" \
  --description "HTTP from CloudFront, SSH from admin" \
  --vpc-id YOUR_VPC_ID
```

- [ ] Security group created — note the Group ID

**Record:**

| Item | Value |
|------|-------|
| Security Group ID | |

### 7.3 Allow SSH from your IP

```bash
aws ec2 authorize-security-group-ingress \
  --region YOUR_INSTANCE_REGION \
  --group-id YOUR_SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr YOUR_IP/32
```

- [ ] SSH rule added

### 7.4 Allow HTTP from CloudFront only
I think since we are only launching in us-east the amis are also specific right ? 
```bash
# Find the CloudFront managed prefix list for your instance region
aws ec2 describe-managed-prefix-lists \
  --region YOUR_INSTANCE_REGION \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --query "PrefixLists[0].PrefixListId" \
  --output text
```

**Record:**

| Item | Value |
|------|-------|
| CloudFront Prefix List ID | |

```bash
aws ec2 authorize-security-group-ingress \
  --region YOUR_INSTANCE_REGION \
  --group-id YOUR_SG_ID \
  --protocol tcp \
  --port 80 \
  --source-prefix-list-id YOUR_PREFIX_LIST_ID
```

- [ ] HTTP rule added — port 80 from CloudFront prefix list only
- [ ] Verify rules: `aws ec2 describe-security-groups --region YOUR_INSTANCE_REGION --group-ids YOUR_SG_ID`

---

## Section 8 — EC2 Key Pair

Skip this section if you already have a key pair.

```bash
aws ec2 create-key-pair \
  --region YOUR_INSTANCE_REGION \
  --key-name "telogoslabs-key" \
  --query "KeyMaterial" \
  --output text > ~/.ssh/telogoslabs-key.pem

chmod 400 ~/.ssh/telogoslabs-key.pem
```

- [ ] Key pair created and saved locally
- [ ] Permissions set to 400

**Record:**

| Item | Value |
|------|-------|
| Key pair name | |
| Local path to .pem | |

---

## Section 9 — Launch Template

This is a one-time setup but the template is reused every time you launch a spot instance.

### 9.1 Find the latest Ubuntu 22.04 AMI for your instance region

```bash
aws ec2 describe-images \
  --region YOUR_INSTANCE_REGION \
  --owners amazon \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].[ImageId,Name]" \
  --output table
```

- [ ] AMI ID confirmed and noted

**Record:**

| Item | Value |
|------|-------|
| AMI ID | |

### 9.2 Review the boot script

Before creating the launch template, review and customise the boot script:

- [ ] `DIST_ID` is set to your CloudFront distribution ID
- [ ] Ollama model pull matches the model you want (default: `llama3`)
- [ ] JupyterLab token/password is set appropriately (default is none — add auth before exposing publicly)
- [ ] EBS volume size is sufficient (100GB suggested for models)

### 9.3 Create the launch template

```bash
# Encode your boot script as base64 and pass as UserData
# Replace all YOUR_* placeholders with real values before running

aws ec2 create-launch-template \
  --region YOUR_INSTANCE_REGION \
  --launch-template-name "spot-ai-template" \
  --version-description "v1" \
  --launch-template-data '{
    "ImageId": "YOUR_AMI_ID",
    "InstanceType": "g4dn.xlarge",
    "KeyName": "YOUR_KEY_PAIR_NAME",
    "SecurityGroupIds": ["YOUR_SG_ID"],
    "IamInstanceProfile": {"Name": "spot-ai-instance-profile"},
    "InstanceMarketOptions": {
      "MarketType": "spot",
      "SpotOptions": {
        "SpotInstanceType": "one-time",
        "InstanceInterruptionBehavior": "terminate"
      }
    },
    "UserData": "YOUR_BASE64_ENCODED_BOOT_SCRIPT",
    "BlockDeviceMappings": [{
      "DeviceName": "/dev/sda1",
      "Ebs": {
        "VolumeSize": 100,
        "VolumeType": "gp3",
        "DeleteOnTermination": true
      }
    }]
  }'
```

- [ ] Launch template created

---

## Summary — Values to Record

Fill this table out as you complete each section. Keep it somewhere safe.

| Item | Value |
|------|-------|
| AWS Account ID | |
| Instance region | |
| Hosted Zone ID | |
| ACM Certificate ARN | |
| S3 Bucket name | |
| CloudFront Distribution ID | |
| CloudFront Domain | |
| IAM Role name | `spot-ai-instance-role` |
| Instance Profile name | `spot-ai-instance-profile` |
| VPC ID | |
| Security Group ID | |
| CloudFront Prefix List ID | |
| Key pair name | |
| AMI ID | |
| Launch Template name | `spot-ai-template` |

---

## Ongoing — Launching a Spot Instance

Once all sections above are complete, launching (or relaunching after interruption) is a single command:

```bash
aws ec2 run-instances \
  --region YOUR_INSTANCE_REGION \
  --launch-template "LaunchTemplateName=spot-ai-template,Version=1" \
  --count 1
```

The boot script handles everything from there:
1. Grabs the new public IP from instance metadata
2. Updates the CloudFront origin
3. Installs and starts Ollama, Open WebUI, JupyterLab
4. Configures Nginx path routing
5. Traffic starts flowing within ~5 minutes

To check boot progress via SSH:
```bash
# Get the new instance IP
aws ec2 describe-instances \
  --region YOUR_INSTANCE_REGION \
  --filters "Name=instance-state-name,Values=running" \
             "Name=tag:Name,Values=spot-ai*" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text

# Tail the boot log
ssh -i ~/.ssh/telogoslabs-key.pem ubuntu@YOUR_INSTANCE_IP \
  "sudo tail -f /var/log/cloud-init-output.log"
```
