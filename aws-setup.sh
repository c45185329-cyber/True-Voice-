#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  RESONANCE — S3 + Amplify Setup Script
#  Run this from your local machine or GitHub Codespace
#  Requires: AWS CLI installed and configured
# ─────────────────────────────────────────────────────────────

set -e

# ─── CONFIG ──────────────────────────────────────────────────
AWS_ACCESS_KEY="AKIAUXXOSDPFO2QCGHGD"
AWS_SECRET_KEY="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"
S3_BUCKET="amz-resonance-app"
AWS_REGION="pa-southeast-2"
GITHUB_REPO="https://github.com/c45185329-cyber/True-Voice-"
APP_NAME="resonance"
# ─────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RESONANCE — AWS infrastructure setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 1. Check AWS CLI is available ─────────────────────────────
echo "▸ Checking AWS CLI..."
if ! command -v aws &> /dev/null; then
  echo "  ✗ AWS CLI not found. Install it with:"
  echo "    pip install awscli"
  exit 1
fi
echo "  ✓ AWS CLI found"

# ── 2. Verify S3 bucket exists ────────────────────────────────
echo ""
echo "▸ Verifying S3 bucket..."

if aws s3 ls "s3://${S3_BUCKET}" --region ${AWS_REGION} > /dev/null 2>&1; then
  echo "  ✓ Bucket ${S3_BUCKET} found"
else
  echo "  ✗ Bucket not found. Creating it..."
  aws s3api create-bucket \
    --bucket ${S3_BUCKET} \
    --region ${AWS_REGION} \
    --create-bucket-configuration LocationConstraint=${AWS_REGION} 2>/dev/null || \
  aws s3api create-bucket \
    --bucket ${S3_BUCKET} \
    --region ${AWS_REGION}
  echo "  ✓ Bucket created"
fi

# ── 3. Apply CORS policy to S3 ────────────────────────────────
echo ""
echo "▸ Applying CORS policy to S3 bucket..."

cat > /tmp/cors.json << 'EOF'
{
  "CORSRules": [
    {
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["GET", "PUT", "POST", "DELETE"],
      "AllowedOrigins": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }
  ]
}
EOF

aws s3api put-bucket-cors \
  --bucket ${S3_BUCKET} \
  --cors-configuration file:///tmp/cors.json \
  --region ${AWS_REGION}

echo "  ✓ CORS policy applied"

# ── 4. Apply lifecycle policy (auto-delete free tier recordings after 30 days)
echo ""
echo "▸ Applying lifecycle policy..."

cat > /tmp/lifecycle.json << 'EOF'
{
  "Rules": [
    {
      "ID": "delete-free-tier-recordings",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "recordings/anonymous/"
      },
      "Expiration": {
        "Days": 30
      }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket ${S3_BUCKET} \
  --lifecycle-configuration file:///tmp/lifecycle.json \
  --region ${AWS_REGION}

echo "  ✓ Lifecycle policy applied (anonymous recordings auto-delete after 30 days)"

# ── 5. Block public access (recordings only accessible via signed URLs) ───
echo ""
echo "▸ Securing bucket access..."

aws s3api put-public-access-block \
  --bucket ${S3_BUCKET} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region ${AWS_REGION}

echo "  ✓ Public access blocked — recordings only accessible via signed URLs"

# ── 6. Create Amplify app ─────────────────────────────────────
echo ""
echo "▸ Creating Amplify app..."

AMPLIFY_APP=$(aws amplify create-app \
  --name ${APP_NAME} \
  --repository ${GITHUB_REPO} \
  --platform WEB \
  --region ${AWS_REGION} \
  --build-spec '{
    "version": 1,
    "frontend": {
      "phases": {
        "build": {
          "commands": []
        }
      },
      "artifacts": {
        "baseDirectory": "/",
        "files": ["**/*"]
      },
      "cache": {
        "paths": []
      }
    }
  }' \
  --output json 2>/dev/null || echo "NEEDS_OAUTH")

if [[ "$AMPLIFY_APP" == "NEEDS_OAUTH" ]]; then
  echo ""
  echo "  ⚠ Amplify needs GitHub authorization — this part requires"
  echo "  the AWS console UI. Here's exactly what to do:"
  echo ""
  echo "  1. Go to console.aws.amazon.com/amplify"
  echo "  2. Click 'Create new app' → 'Host web app'"
  echo "  3. Choose GitHub and authorize when prompted"
  echo "  4. Select repo: c45185329-cyber/True-Voice-"
  echo "  5. Branch: main"
  echo "  6. On build settings, click Edit and paste this build spec:"
  echo ""
  echo "     version: 1"
  echo "     frontend:"
  echo "       phases:"
  echo "         build:"
  echo "           commands: []"
  echo "       artifacts:"
  echo "         baseDirectory: /"
  echo "         files:"
  echo "           - '**/*'"
  echo "       cache:"
  echo "         paths: []"
  echo ""
  echo "  7. Click Save and deploy"
  echo "  8. Copy the URL Amplify gives you (looks like https://main.xxxxx.amplifyapp.com)"
else
  APP_ID=$(echo $AMPLIFY_APP | python3 -c "import sys,json; print(json.load(sys.stdin)['app']['appId'])")
  
  # Create main branch
  aws amplify create-branch \
    --app-id ${APP_ID} \
    --branch-name main \
    --region ${AWS_REGION} > /dev/null

  # Trigger first deployment
  aws amplify start-job \
    --app-id ${APP_ID} \
    --branch-name main \
    --job-type RELEASE \
    --region ${AWS_REGION} > /dev/null

  AMPLIFY_URL="https://main.${APP_ID}.amplifyapp.com"
  echo "  ✓ Amplify app created and deploying"
  echo "  ✓ Your app URL: ${AMPLIFY_URL}"
fi

# ── 7. Verify EC2 backend is reachable ────────────────────────
echo ""
echo "▸ Verifying EC2 backend..."

EC2_IP="3.25.160.183"
HEALTH=$(curl -s --max-time 5 http://${EC2_IP}:5000/health || echo "unreachable")

if [[ "$HEALTH" == *"ok"* ]]; then
  echo "  ✓ EC2 backend is reachable"
  echo "  ✓ Response: $HEALTH"
else
  echo "  ⚠ EC2 backend not responding at http://${EC2_IP}:5000"
  echo "  SSH into your EC2 and run: sudo systemctl status resonance"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ AWS infrastructure setup complete"
echo ""
echo "  S3 Bucket:  s3://${S3_BUCKET}"
echo "  EC2 API:    http://${EC2_IP}:5000"
echo ""
echo "  Next step: push index.html to GitHub"
echo "  Amplify will auto-deploy within ~1 minute"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
