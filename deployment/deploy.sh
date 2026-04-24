#!/bin/bash
# =============================================================================
# IoT Device Simulator - Deploy Script
# =============================================================================
# Usage:
#   ./deploy.sh --email <admin-email> [--region <aws-region>] [--stack-name <name>] [--bucket-prefix <prefix>]
#
# Examples:
#   ./deploy.sh --email admin@example.com
#   ./deploy.sh --email admin@example.com --region ap-southeast-1
#   ./deploy.sh --email admin@example.com --region us-west-2 --stack-name my-iot-sim
# =============================================================================

set -e

# ---- Defaults ----
REGION="ap-southeast-1"
STACK_NAME="iot-device-simulator"
PIPELINE_STACK_NAME=""
SOLUTION_NAME="iot-device-simulator"
VERSION="v3.1.0"
BUCKET_PREFIX=""
EMAIL=""
IOT_TOPIC="telemetry"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --email)          EMAIL="$2"; shift 2 ;;
        --region)         REGION="$2"; shift 2 ;;
        --stack-name)     STACK_NAME="$2"; shift 2 ;;
        --bucket-prefix)  BUCKET_PREFIX="$2"; shift 2 ;;
        --iot-topic)      IOT_TOPIC="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./deploy.sh --email <admin-email> [options]"
            echo ""
            echo "Options:"
            echo "  --email <email>          Admin email for console login (required)"
            echo "  --region <region>        AWS region (default: ap-southeast-1)"
            echo "  --stack-name <name>      CloudFormation stack name (default: iot-device-simulator)"
            echo "  --bucket-prefix <prefix> S3 bucket prefix (default: auto-generated)"
            echo "  --iot-topic <topic>      IoT topic name for data pipeline (default: telemetry)"
            exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# ---- Resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE_TEMPLATE="$PROJECT_ROOT/templates/cloudformation.yaml"
PIPELINE_STACK_NAME="${STACK_NAME}-pipeline"

# ---- Helper functions ----
info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }

separator() {
    echo ""
    echo "=============================================================================="
    echo "  $1"
    echo "=============================================================================="
    echo ""
}

# =============================================================================
# STEP 1: Validate prerequisites
# =============================================================================
separator "Step 1: Validating prerequisites"

# Email is required
if [ -z "$EMAIL" ]; then
    fail "Admin email is required. Usage: ./deploy.sh --email <admin-email>"
fi

# Validate email format (basic check)
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    fail "Invalid email format: $EMAIL"
fi
success "Admin email: $EMAIL"

# Check Node.js
if ! command -v node &> /dev/null; then
    fail "Node.js is not installed. Please install Node.js 22 or later."
fi
NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt 22 ]; then
    fail "Node.js 22+ is required. Found: $(node -v)"
fi
success "Node.js $(node -v)"

# Check npm
if ! command -v npm &> /dev/null; then
    fail "npm is not installed."
fi
success "npm $(npm -v)"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    fail "AWS CLI is not installed. Please install and configure it."
fi
success "AWS CLI $(aws --version 2>&1 | cut -d' ' -f1)"

# Check AWS credentials
info "Verifying AWS credentials..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --region "$REGION" --query "Account" --output text 2>/dev/null) || \
    fail "AWS credentials are not configured or are invalid. Run 'aws configure' first."
success "AWS Account: $AWS_ACCOUNT_ID"
success "Target region: $REGION"

# Check pipeline template exists
if [ ! -f "$PIPELINE_TEMPLATE" ]; then
    fail "Pipeline template not found at: $PIPELINE_TEMPLATE"
fi
success "Pipeline template found"

# Generate bucket prefix if not provided
if [ -z "$BUCKET_PREFIX" ]; then
    BUCKET_PREFIX="iot-sim-$(openssl rand -hex 4)"
    info "Generated bucket prefix: $BUCKET_PREFIX"
fi
BUCKET_NAME="${BUCKET_PREFIX}-${REGION}"

# Check if stacks already exist
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")
SIM_ACTION="create"
if [[ "$STACK_STATUS" =~ ^(CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE)$ ]]; then
    SIM_ACTION="update"
    warn "Simulator stack '$STACK_NAME' already exists ($STACK_STATUS). Will update on rerun."
elif [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
    success "Stack name '$STACK_NAME' is available"
else
    fail "Stack '$STACK_NAME' exists in $REGION with status: $STACK_STATUS. Delete it first or use a different --stack-name."
fi

PIPELINE_STATUS=$(aws cloudformation describe-stacks --stack-name "$PIPELINE_STACK_NAME" --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")
PIPE_ACTION="create"
if [[ "$PIPELINE_STATUS" =~ ^(CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE)$ ]]; then
    PIPE_ACTION="update"
    warn "Pipeline stack '$PIPELINE_STACK_NAME' already exists ($PIPELINE_STATUS). Will update on rerun."
elif [ "$PIPELINE_STATUS" = "DOES_NOT_EXIST" ]; then
    success "Pipeline stack name '$PIPELINE_STACK_NAME' is available"
else
    fail "Pipeline stack '$PIPELINE_STACK_NAME' exists in $REGION with status: $PIPELINE_STATUS. Delete it first or use a different --stack-name."
fi

echo ""
info "Deployment configuration:"
echo "  Region:              $REGION"
echo "  Simulator stack:     $STACK_NAME"
echo "  Pipeline stack:      $PIPELINE_STACK_NAME"
echo "  S3 bucket:           $BUCKET_NAME"
echo "  Admin email:         $EMAIL"
echo "  IoT topic:           $IOT_TOPIC"
echo "  Version:             $VERSION"
echo ""
read -p "Proceed with deployment? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Deployment cancelled."
    exit 0
fi

# =============================================================================
# STEP 2: Create S3 bucket
# =============================================================================
if [ "$SIM_ACTION" = "update" ] && [ "$PIPE_ACTION" = "update" ]; then
    separator "Step 2: Skipping S3 bucket creation (stacks already deployed)"
    success "Both stacks already exist. Skipping bucket setup."
else
    separator "Step 2: Creating S3 bucket"

    if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
        warn "Bucket $BUCKET_NAME already exists, reusing it."
    else
        info "Creating bucket: $BUCKET_NAME"
        aws s3 mb "s3://${BUCKET_NAME}" --region "$REGION"
        success "Bucket created: $BUCKET_NAME"
    fi

    # Block public access on the bucket
    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    success "Public access blocked on $BUCKET_NAME"
fi

# =============================================================================
# STEP 3: Build the solution
# =============================================================================
if [ "$SIM_ACTION" = "update" ] && [ "$PIPE_ACTION" = "update" ]; then
    separator "Step 3: Skipping build (stacks already deployed)"
    success "Both stacks already exist. Skipping application build."
else
    separator "Step 3: Building the solution"

    cd "$SCRIPT_DIR"
    chmod +x build-s3-dist.sh
    ./build-s3-dist.sh "$BUCKET_PREFIX" "$SOLUTION_NAME" "$VERSION"

    if [ $? -ne 0 ]; then
        fail "Build failed. Check the output above for errors."
    fi
    success "Build completed"
fi

# =============================================================================
# STEP 4: Upload assets to S3
# =============================================================================
if [ "$SIM_ACTION" = "update" ] && [ "$PIPE_ACTION" = "update" ]; then
    separator "Step 4: Skipping asset upload (stacks already deployed)"
    success "Both stacks already exist. Skipping asset upload."
else
    separator "Step 4: Uploading assets to S3"

    info "Uploading global assets..."
    aws s3 sync "$SCRIPT_DIR/global-s3-assets/" \
        "s3://${BUCKET_NAME}/${SOLUTION_NAME}/${VERSION}/" \
        --region "$REGION"

    info "Uploading regional assets..."
    aws s3 sync "$SCRIPT_DIR/regional-s3-assets/" \
        "s3://${BUCKET_NAME}/${SOLUTION_NAME}/${VERSION}/" \
        --region "$REGION"

    success "All assets uploaded"
fi

# =============================================================================
# STEP 5: Deploy IoT Device Simulator stack
# =============================================================================
separator "Step 5: Deploying IoT Device Simulator stack"

if [ "$SIM_ACTION" = "update" ]; then
    warn "Simulator stack '$STACK_NAME' uses an S3-hosted template. Skipping update."
    warn "To update the simulator stack, delete it first and redeploy, or update it manually via the CloudFormation console."
    success "Simulator stack '$STACK_NAME' unchanged."
else
    TEMPLATE_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${SOLUTION_NAME}/${VERSION}/iot-device-simulator.template"
    info "Template URL: $TEMPLATE_URL"
    info "Creating stack '$STACK_NAME'..."

    aws cloudformation create-stack \
        --region "$REGION" \
        --template-url "$TEMPLATE_URL" \
        --stack-name "$STACK_NAME" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameters "ParameterKey=UserEmail,ParameterValue=${EMAIL}" \
        --tags "Key=Solution,Value=IoTDeviceSimulator" "Key=Version,Value=${VERSION}"

    success "Simulator stack creation initiated"

    info "Waiting for simulator stack (this takes 10-15 minutes)..."
    while true; do
        STATUS=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query "Stacks[0].StackStatus" \
            --output text 2>/dev/null)

        case "$STATUS" in
            CREATE_COMPLETE)
                echo ""
                success "Simulator stack deployed successfully!"
                break
                ;;
            CREATE_IN_PROGRESS)
                echo -n "."
                sleep 15
                ;;
            CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_IN_PROGRESS|ROLLBACK_FAILED)
                echo ""
                fail "Simulator stack deployment failed (status: $STATUS). Check the CloudFormation console."
                ;;
            *)
                echo ""
                fail "Unexpected stack status: $STATUS"
                ;;
        esac
    done
fi

# =============================================================================
# STEP 6: Deploy Data Pipeline stack
# =============================================================================
separator "Step 6: Deploying Data Pipeline stack"

if [ "$PIPE_ACTION" = "update" ]; then
    info "Updating pipeline stack '$PIPELINE_STACK_NAME'..."

    UPDATE_OUTPUT=$(aws cloudformation update-stack \
        --region "$REGION" \
        --template-body "file://${PIPELINE_TEMPLATE}" \
        --stack-name "$PIPELINE_STACK_NAME" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameters "ParameterKey=IoTTopicName,ParameterValue=${IOT_TOPIC}" \
        --tags "Key=Solution,Value=IoTDeviceSimulator" "Key=Version,Value=${VERSION}" 2>&1) || {
        if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
            success "Pipeline stack '$PIPELINE_STACK_NAME' is already up to date. No changes needed."
            PIPE_ACTION="skip"
        else
            fail "Pipeline stack update failed: $UPDATE_OUTPUT"
        fi
    }

    if [ "$PIPE_ACTION" = "update" ]; then
        success "Pipeline stack update initiated"

        info "Waiting for pipeline stack update..."
        while true; do
            STATUS=$(aws cloudformation describe-stacks \
                --stack-name "$PIPELINE_STACK_NAME" \
                --region "$REGION" \
                --query "Stacks[0].StackStatus" \
                --output text 2>/dev/null)

            case "$STATUS" in
                UPDATE_COMPLETE)
                    echo ""
                    success "Pipeline stack updated successfully!"
                    break
                    ;;
                UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS)
                    echo -n "."
                    sleep 10
                    ;;
                UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_IN_PROGRESS|UPDATE_FAILED|UPDATE_ROLLBACK_FAILED)
                    echo ""
                    fail "Pipeline stack update failed (status: $STATUS). Check the CloudFormation console."
                    ;;
                *)
                    echo ""
                    fail "Unexpected stack status: $STATUS"
                    ;;
            esac
        done
    fi
else
    info "Creating pipeline stack '$PIPELINE_STACK_NAME'..."

    aws cloudformation create-stack \
        --region "$REGION" \
        --template-body "file://${PIPELINE_TEMPLATE}" \
        --stack-name "$PIPELINE_STACK_NAME" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameters "ParameterKey=IoTTopicName,ParameterValue=${IOT_TOPIC}" \
        --tags "Key=Solution,Value=IoTDeviceSimulator" "Key=Version,Value=${VERSION}"

    success "Pipeline stack creation initiated"

    info "Waiting for pipeline stack..."
    while true; do
        STATUS=$(aws cloudformation describe-stacks \
            --stack-name "$PIPELINE_STACK_NAME" \
            --region "$REGION" \
            --query "Stacks[0].StackStatus" \
            --output text 2>/dev/null)

        case "$STATUS" in
            CREATE_COMPLETE)
                echo ""
                success "Pipeline stack deployed successfully!"
                break
                ;;
            CREATE_IN_PROGRESS)
                echo -n "."
                sleep 10
                ;;
            CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_IN_PROGRESS|ROLLBACK_FAILED)
                echo ""
                fail "Pipeline stack deployment failed (status: $STATUS). Check the CloudFormation console."
                ;;
            *)
                echo ""
                fail "Unexpected stack status: $STATUS"
                ;;
        esac
    done
fi

# =============================================================================
# STEP 7: Upload Glue ETL script to S3
# =============================================================================
separator "Step 7: Uploading Glue ETL script"

GLUE_SCRIPTS_BUCKET="iot-glue-scripts-${AWS_ACCOUNT_ID}"
GLUE_SCRIPT_SRC="$PROJECT_ROOT/source/glue/iot_raw_to_clean.py"

if [ ! -f "$GLUE_SCRIPT_SRC" ]; then
    fail "Glue script not found at: $GLUE_SCRIPT_SRC"
fi

info "Uploading Glue script to s3://${GLUE_SCRIPTS_BUCKET}/scripts/iot_raw_to_clean.py"
aws s3 cp "$GLUE_SCRIPT_SRC" \
    "s3://${GLUE_SCRIPTS_BUCKET}/scripts/iot_raw_to_clean.py" \
    --region "$REGION"
success "Glue ETL script uploaded"

# =============================================================================
# STEP 8: Display outputs
# =============================================================================
separator "Deployment Complete!"

CONSOLE_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='ConsoleURL'].OutputValue" \
    --output text 2>/dev/null)

API_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='APIEndpoint'].OutputValue" \
    --output text 2>/dev/null)

RAW_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$PIPELINE_STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='RawBucketName'].OutputValue" \
    --output text 2>/dev/null)

KINESIS_STREAM=$(aws cloudformation describe-stacks \
    --stack-name "$PIPELINE_STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='KinesisStreamName'].OutputValue" \
    --output text 2>/dev/null)

echo -e "${GREEN}IoT Device Simulator is ready!${NC}"
echo ""
echo "  Simulator:"
echo "    Console URL:     $CONSOLE_URL"
echo "    API Endpoint:    $API_ENDPOINT"
echo "    Admin Email:     $EMAIL"
echo ""
echo "  Data Pipeline:"
echo "    IoT Topic:       $IOT_TOPIC"
echo "    Kinesis Stream:  $KINESIS_STREAM"
echo "    Raw Data Bucket: $RAW_BUCKET"
echo ""
echo "  Infrastructure:"
echo "    Region:          $REGION"
echo "    Simulator Stack: $STACK_NAME"
echo "    Pipeline Stack:  $PIPELINE_STACK_NAME"
echo "    Deploy Bucket:   $BUCKET_NAME"
echo ""
echo "  A temporary password has been sent to $EMAIL."
echo "  Sign in at the Console URL and set a new password."
echo ""
echo "  To clean up later, run:"
echo "    ./cleanup.sh --stack-name $STACK_NAME --region $REGION --bucket $BUCKET_NAME"
echo ""
