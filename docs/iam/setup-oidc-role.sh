#!/usr/bin/env bash
# docs/iam/setup-oidc-role.sh
#
# Creates an IAM OIDC identity provider (if absent) and an IAM role that
# GitHub Actions can assume via short-lived OIDC tokens.
#
# This is the RECOMMENDED approach — no long-lived secrets stored in GitHub.
# The workflow already has `id-token: write` permission so it supports OIDC.
#
# After setup, update .github/workflows/build-ami.yml:
#   Replace the `aws-access-key-id` / `aws-secret-access-key` block with:
#
#     - name: Configure AWS credentials
#       uses: aws-actions/configure-aws-credentials@v4
#       with:
#         role-to-assume: arn:aws:iam::ACCOUNT_ID:role/GitHubActions-PackerMediaWiki
#         aws-region: ${{ env.AWS_REGION }}
#
# Prerequisites:
#   - aws CLI configured with AdministratorAccess or equivalent
#   - Set GITHUB_ORG and GITHUB_REPO below (or pass as env vars)
#
# Usage:
#   GITHUB_ORG=myorg GITHUB_REPO=wiki bash docs/iam/setup-oidc-role.sh
#
# What this creates:
#   OIDC Provider: token.actions.githubusercontent.com  (skipped if exists)
#   IAM Role:      GitHubActions-PackerMediaWiki
#   IAM Policy:    PackerMediaWikiBuilderPolicy  (from packer-policy.json)

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="${AWS_REGION:-us-east-2}"
GITHUB_ORG="${GITHUB_ORG:?Set GITHUB_ORG to your GitHub organization or username}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO to your repository name}"
ROLE_NAME="GitHubActions-PackerMediaWiki"
POLICY_NAME="PackerMediaWikiBuilderPolicy"
POLICY_FILE="$(dirname "$0")/packer-policy.json"
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_THUMBPRINT="9514f4ed3c841c96c43def0f0acbf177405ded12"

echo "==> AWS account: ${AWS_ACCOUNT_ID}, region: ${AWS_REGION}"
echo "==> GitHub repo: ${GITHUB_ORG}/${GITHUB_REPO}"

# ── 1. Create the GitHub Actions OIDC provider (idempotent) ─────────────────
echo "==> Checking for OIDC identity provider"
EXISTING_PROVIDER=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn,'token.actions.githubusercontent.com')].Arn" \
  --output text --no-cli-pager)

if [ -z "${EXISTING_PROVIDER}" ]; then
  echo "    Creating OIDC provider for token.actions.githubusercontent.com"
  aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${OIDC_THUMBPRINT}" \
    --no-cli-pager
else
  echo "    OIDC provider already exists: ${EXISTING_PROVIDER}"
fi

# ── 2. Write the trust policy ────────────────────────────────────────────────
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/tags/ami/*",
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:workflow_dispatch"
          ]
        }
      }
    }
  ]
}
EOF
)

# ── 3. Create the IAM role ───────────────────────────────────────────────────
echo "==> Creating IAM role: ${ROLE_NAME}"
ROLE_ARN=$(aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "Assumed by GitHub Actions to run Packer AMI builds for mediawiki" \
  --tags Key=Purpose,Value=packer-ami-builder \
         Key=ManagedBy,Value=manual \
  --query Role.Arn \
  --output text \
  --no-cli-pager 2>/dev/null) || {
    ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
    echo "    (role already exists — updating trust policy)"
    aws iam update-assume-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-document "${TRUST_POLICY}" \
      --no-cli-pager
}
echo "    Role ARN: ${ROLE_ARN}"

# ── 4. Create the permissions policy ────────────────────────────────────────
echo "==> Creating IAM policy: ${POLICY_NAME}"
POLICY_ARN=$(aws iam create-policy \
  --policy-name "${POLICY_NAME}" \
  --description "Minimal permissions for Packer to build the mediawiki AMI in ${AWS_REGION}" \
  --policy-document "file://${POLICY_FILE}" \
  --tags Key=Purpose,Value=packer-ami-builder \
         Key=ManagedBy,Value=manual \
  --query Policy.Arn \
  --output text \
  --no-cli-pager 2>/dev/null) || {
    POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
    echo "    (policy already exists — using ${POLICY_ARN})"
}
echo "    Policy ARN: ${POLICY_ARN}"

# ── 5. Attach the policy to the role ────────────────────────────────────────
echo "==> Attaching policy to role"
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}" \
  --no-cli-pager

echo ""
echo "==> Done."
echo ""
echo "Role ARN to use in your workflow:"
echo "  ${ROLE_ARN}"
echo ""
echo "Update .github/workflows/build-ami.yml — replace the credentials step with:"
echo ""
echo '  - name: Configure AWS credentials'
echo '    uses: aws-actions/configure-aws-credentials@v4'
echo '    with:'
echo "      role-to-assume: ${ROLE_ARN}"
echo '      aws-region: ${{ env.AWS_REGION }}'
echo ""
