#!/usr/bin/env bash
# docs/iam/setup-vpc.sh
#
# Ensures a VPC and public subnet exist for Packer to launch its builder
# instance.  Packer does NOT create these — it requires them as inputs
# (PACKER_VPC_ID / PACKER_SUBNET_ID GitHub Secrets).
#
#   default            Use the AWS-managed default VPC + a default subnet.
#                      Fast, zero config, and fine for CI builds.
#
# Usage:
#   bash docs/iam/setup-vpc.sh              # use default VPC
#
# Prerequisites:
#   - aws CLI configured with admin credentials (NOT the packer IAM user)
#   - AWS_REGION set, or defaulting to us-east-2
#
# Output:
#   Prints the VPC ID and subnet ID to set as GitHub Secrets:
#     PACKER_VPC_ID
#     PACKER_SUBNET_ID

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"

echo "==> AWS region: ${AWS_REGION}"
echo ""

echo "==> Looking for default VPC in ${AWS_REGION}"

VPC_ID=$(aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" \
  --output text --no-cli-pager)

if [ "${VPC_ID}" = "None" ] || [ -z "${VPC_ID}" ]; then
  echo ""
  echo "ERROR: No default VPC found in ${AWS_REGION}."
  echo "  Either restore it with:"
  echo "    aws ec2 create-default-vpc --region ${AWS_REGION}"
  echo "  Or run this script with --dedicated to create a minimal VPC."
  exit 1
fi

echo "    Found default VPC: ${VPC_ID}"
echo ""
echo "==> Looking for a public subnet in ${VPC_ID}"

# Default subnets auto-assign public IPs — pick the first available one.
SUBNET_ID=$(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters \
      Name=vpc-id,Values="${VPC_ID}" \
      Name=defaultForAz,Values=true \
      Name=state,Values=available \
  --query "Subnets[0].SubnetId" \
  --output text --no-cli-pager)

if [ "${SUBNET_ID}" = "None" ] || [ -z "${SUBNET_ID}" ]; then
  echo "ERROR: No default subnet found in ${VPC_ID}."
  echo "  Run with --dedicated to create a fresh VPC + subnet."
  exit 1
fi

echo "    Found default subnet: ${SUBNET_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# Output: GitHub Secrets to set
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Set these GitHub Secrets in your repository:"
echo ""
echo "  PACKER_VPC_ID    = ${VPC_ID}"
echo "  PACKER_SUBNET_ID = ${SUBNET_ID}"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "Or set them with the GitHub CLI:"
echo "  gh secret set PACKER_VPC_ID    --body \"${VPC_ID}\""
echo "  gh secret set PACKER_SUBNET_ID --body \"${SUBNET_ID}\""

