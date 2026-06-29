# IAM Setup for Packer CI Builds

This directory contains everything needed to prepare AWS for GitHub Actions
to run `packer validate` and `packer build` for the mediawiki AMI.

**Three things must exist before the workflow can run:**

1. **A VPC + public subnet** — Packer launches a builder EC2 instance here.
   Packer does _not_ create these; they must already exist and their IDs must
   be set as `PACKER_VPC_ID` / `PACKER_SUBNET_ID` GitHub Secrets.
2. **An IAM identity** (OIDC role) — provides AWS credentials to
   the workflow.
3. **The `PackerMediaWikiBuilderPolicy`** — grants only the EC2 permissions
   Packer actually needs.

Run the scripts in order:

```
Step 1 → setup-vpc.sh          (VPC + subnet)
Step 2 → setup-oidc-role.sh
```

---

## What Packer actually does with AWS

The `amazon-ebs` builder performs these AWS API calls during a build:

| Phase | AWS API calls |
|-------|---------------|
| Source AMI lookup (`data "amazon-ami"`) | `ec2:DescribeImages` — finds the latest `al2025-ami-2025.*-arm64` Amazon-owned AMI |
| Validate VPC / subnet | `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeRegions` |
| Create temporary SSH keypair | `ec2:CreateKeyPair`, `ec2:DeleteKeyPair` |
| Create temporary security group | `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:DescribeSecurityGroups` |
| Launch builder EC2 (`t4g.medium`) | `ec2:RunInstances`, `ec2:DescribeInstances`, `ec2:DescribeInstanceStatus` |
| Tag builder resources | `ec2:CreateTags` |
| Provision via SSH | *(no AWS API calls — SSH only)* |
| Stop instance before snapshot | `ec2:StopInstances` |
| Create AMI + snapshot | `ec2:CreateImage`, `ec2:DescribeImages`, `ec2:DescribeSnapshots`, `ec2:CreateSnapshot` |
| Tag AMI + snapshot | `ec2:CreateTags` (via `tags` + `snapshot_tags` in HCL) |
| Terminate builder instance | `ec2:TerminateInstances` |
| Clean up temp SG | `ec2:DeleteSecurityGroup`, `ec2:RevokeSecurityGroupIngress` |
| Failure cleanup | `ec2:DeregisterImage`, `ec2:DeleteSnapshot`, `ec2:ModifyImageAttribute` |

`packer validate` only exercises the read-only describe calls (no resources are created).

---

## Files

| File | Purpose |
|------|---------|
| `setup-vpc.sh` | **Step 1** — find the default VPC/subnet or create a dedicated one; outputs `PACKER_VPC_ID` + `PACKER_SUBNET_ID` |
| `packer-policy.json` | IAM policy document — attach to either the OIDC role |
| `oidc-trust-policy.json` | Trust policy template for the OIDC role (fill in `ACCOUNT_ID`, `YOUR_GITHUB_ORG`, `YOUR_REPO_NAME`) |
| `setup-oidc-role.sh` | **Step 2** — creates an OIDC identity provider + role (no long-lived keys) |

---

## Step 1 — VPC and subnet

Packer requires an existing **public subnet** (one with a route to an Internet
Gateway) so the builder instance can reach `dnf`/`yum` mirrors and the
Gerrit/GitHub servers during provisioning. Packer only creates a temporary
**security group** inside that subnet — it never creates VPCs, subnets,
route tables, or internet gateways.

```bash
# Use the AWS-managed default VPC (fastest, works for most accounts):
bash docs/iam/setup-vpc.sh
```

The script prints the IDs at the end. Set them as GitHub Secrets:

```bash
gh secret set PACKER_VPC_ID    --body "vpc-xxxxxxxxxxxxxxxxx"
gh secret set PACKER_SUBNET_ID --body "subnet-xxxxxxxxxxxxxxxxx"
```

---

## Step 2 — IAM credentials

### Option A — OIDC Role (recommended)

GitHub Actions supports AWS OIDC natively. The workflow already has
`id-token: write` permission, so no long-lived secrets are required.

```bash
GITHUB_ORG=your-org GITHUB_REPO=wiki bash docs/iam/setup-oidc-role.sh
```

Then update `.github/workflows/build-ami.yml` — replace both
`aws-access-key-id` / `aws-secret-access-key` credential steps with:

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::ACCOUNT_ID:role/GitHubActions-PackerMediaWiki
    aws-region: ${{ env.AWS_REGION }}
```

### Resources created

| Resource | Name | Purpose |
|----------|------|---------|
| OIDC Identity Provider | `token.actions.githubusercontent.com` | Lets GitHub Actions obtain short-lived AWS tokens |
| IAM Role | `GitHubActions-PackerMediaWiki` | Assumed by the workflow; scoped to tag pushes + manual dispatch |
| IAM Policy | `PackerMediaWikiBuilderPolicy` | EC2 permissions described above; restricted to `us-east-2` |

---

## Policy design notes

### Two condition families used throughout

Every statement uses one of two IAM condition families to scope it to
resources Packer itself created:

| Condition | Applies to | Meaning |
|-----------|-----------|---------|
| `aws:RequestTag/ManagedBy: packer` | **Create** actions | The API call must include `ManagedBy=packer` in its `TagSpecification`. Packer always does this because `ManagedBy = "packer"` is in `local.common_tags` and the `tags` block in the HCL. If the tag is absent the action is denied. |
| `aws:ResourceTag/ManagedBy: packer` | **Delete / modify** actions | The targeted resource must already carry the tag. Packer-created resources always do. Pre-existing resources (production volumes, other accounts' snapshots, anyone else's key pairs) do not, so those actions are denied. |

Together these form a tag-based ownership fence: **Packer can only destroy or
modify what it created.**

### Statement-by-statement rationale

**`PackerDescribeResources`**
All read-only `Describe*` calls. Scoped to `us-east-2`; no resource
restrictions needed since describe calls cannot modify anything.

**`PackerCreateKeyPair` / `PackerDeleteKeyPair`**
Packer generates a throwaway RSA key pair at build start and deletes it on
exit (including failure). `CreateKeyPair` requires the `ManagedBy=packer` tag
at creation so only Packer-initiated key pairs exist with that tag.
`DeleteKeyPair` is then gated to `ResourceTag/ManagedBy=packer`, so it cannot
delete any key pair that was not created by Packer.

**`PackerCreateSecurityGroup` / `PackerManageSecurityGroup`**
Packer creates a temporary security group, opens port 22 from the runner IP
(`temporary_security_group_source_public_ip = true`), then deletes it when
done. `CreateSecurityGroup` includes `vpc/*` because the API references the
VPC; `aws:RequestTag` only applies to the SG being created, not to the
pre-existing VPC. All subsequent manage operations (`Delete`, `Authorize`,
`Revoke`) are restricted to `ResourceTag/ManagedBy=packer` — Packer cannot
modify any pre-existing security group in the account.

**`PackerRunInstanceNewResources`**
Covers the instance and root volume Packer launches. Two conditions are
enforced simultaneously:
- `aws:RequestTag/ManagedBy: packer` — Packer must tag both the instance and
  volume at launch. Without the tag the `RunInstances` call is denied.
- `ec2:InstanceType: t4g.medium` — Prevents the credential from launching any
  instance type other than the one used for this build. Because `ec2:InstanceType`
  is a request-context key evaluated once per API call, placing it in the
  `instance/*` statement blocks the entire `RunInstances` request if the wrong
  type is requested, even though the volume statement has no InstanceType
  condition of its own.

**`PackerRunInstanceOwnedRefs`**
The security group and key pair referenced in `RunInstances` must already be
tagged `ManagedBy=packer`. This ensures Packer can only launch into its own
temporary security group, not an arbitrary pre-existing one.

**`PackerRunInstanceExternalRefs`**
The source AMI, target subnet, and ephemeral network interface are not
Packer-owned (AMI is Amazon-owned; subnet was created by the admin). They
cannot carry `ManagedBy=packer` so they are region-scoped only. The AMI ARN
includes both `arn:aws:ec2:us-east-2::image/*` (Amazon-owned, no account ID)
and `arn:aws:ec2:us-east-2:*:image/*` (account-owned) to cover both forms.

**`PackerManageInstance`**
Stop, terminate, and modify are restricted to `ResourceTag/ManagedBy=packer`.
Packer cannot stop or terminate any pre-existing production instance.

**`PackerCreateImage` / `PackerManageImage`**
`CreateImage` and `RegisterImage` require the new AMI to be tagged at
creation. `DeregisterImage` and `ModifyImageAttribute` are restricted to
Packer-tagged AMIs, preventing the credential from deregistering or
modifying any AMI it did not build.

**`PackerCreateSnapshot` / `PackerCreateSnapshotFromVolume` / `PackerManageSnapshot`**
`ec2:CreateSnapshot` operates on two IAM resource types simultaneously — the
new snapshot being created and the source volume. Two separate statements are
required: one requiring `RequestTag` on the new snapshot, and one requiring
`ResourceTag` on the source volume (ensuring Packer can only snapshot its own
volumes). `DeleteSnapshot` and `ModifySnapshotAttribute` are locked to
`ResourceTag/ManagedBy=packer`, preventing deletion of any snapshot Packer
did not create.

**`PackerCreateVolume` / `PackerManageVolume`**
Volumes created directly (outside of `RunInstances`) must be tagged at
creation. `DeleteVolume`, `AttachVolume`, and `DetachVolume` require
`ResourceTag/ManagedBy=packer` on both the volume and the target instance,
so operations are confined to Packer-owned resources on both sides.

**`PackerCreateTags`**
Restricted to tags applied *at resource creation time* via the
`ec2:CreateAction` condition key. The `Resource: *` is intentional — it
allows tagging the snapshot and NICs created implicitly by `RunInstances` and
`CreateImage` (which don't have their own dedicated ARNs in the request).
The `ec2:CreateAction` condition prevents any standalone `CreateTags` call
from retroactively tagging arbitrary existing resources.

### What this policy does NOT grant

- Access to any S3 bucket (the builder instance reads packages from the
  internet; S3 backup permissions belong to a separate instance profile)
- IAM permissions (cannot create/modify roles or policies)
- `ec2:GetPasswordData` (not needed for Linux AMIs)
- Any cross-region actions (all ARNs and conditions lock to `us-east-2`)
- The ability to delete or modify any resource that was not created with
  `ManagedBy=packer` — including production volumes, snapshots, security
  groups, key pairs, AMIs, and instances
- VPC / subnet / IGW / route table modifications — those are set up once
  by `setup-vpc.sh` with admin credentials and never touched by Packer

---

## Updating the policy

If you add region support or change the instance type, update `packer-policy.json`
and re-apply with:

```bash
# Get the current policy ARN
POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='PackerMediaWikiBuilderPolicy'].Arn" \
  --output text)

# Create a new version (max 5 versions; oldest non-default is deleted automatically)
aws iam create-policy-version \
  --policy-arn "${POLICY_ARN}" \
  --policy-document file://docs/iam/packer-policy.json \
  --set-as-default
```

