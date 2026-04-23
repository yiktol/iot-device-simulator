#!/bin/bash
# =============================================================================
# IoT Device Simulator - Cleanup Script
# =============================================================================
# Usage:
#   ./cleanup.sh --stack-name <name> --region <region> --bucket <bucket-name>
#
# Examples:
#   ./cleanup.sh --stack-name iot-device-simulator --region ap-southeast-1 --bucket iot-sim-abc12345-ap-southeast-1
# =============================================================================

set -e

REGION=""
STACK_NAME=""
BUCKET_NAME=""
SKIP_CONFIRM=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --stack-name) STACK_NAME="$2"; shift 2 ;;
        --region)     REGION="$2"; shift 2 ;;
        --bucket)     BUCKET_NAME="$2"; shift 2 ;;
        --yes|-y)     SKIP_CONFIRM=true; shift ;;
        --help|-h)
            echo "Usage: ./cleanup.sh --stack-name <name> --region <region> --bucket <bucket-name> [--yes]"
            exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

PIPELINE_STACK_NAME="${STACK_NAME}-pipeline"

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }

# ---- Validate inputs ----
if [ -z "$STACK_NAME" ] || [ -z "$REGION" ]; then
    fail "Both --stack-name and --region are required."
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    fail "AWS CLI is not installed."
fi

# Verify credentials
aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1 || \
    fail "AWS credentials are not configured or are invalid."

# Check which stacks exist
SIM_EXISTS=false
PIPE_EXISTS=false

SIM_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")
if [ "$SIM_STATUS" != "DOES_NOT_EXIST" ]; then
    SIM_EXISTS=true
fi

PIPE_STATUS=$(aws cloudformation describe-stacks --stack-name "$PIPELINE_STACK_NAME" --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")
if [ "$PIPE_STATUS" != "DOES_NOT_EXIST" ]; then
    PIPE_EXISTS=true
fi

echo ""
echo "=============================================================================="
echo "  IoT Device Simulator - Cleanup"
echo "=============================================================================="
echo ""
echo "  This will permanently delete:"
if [ "$SIM_EXISTS" = true ]; then
echo "    - Simulator stack:  $STACK_NAME ($SIM_STATUS)"
fi
if [ "$PIPE_EXISTS" = true ]; then
echo "    - Pipeline stack:   $PIPELINE_STACK_NAME ($PIPE_STATUS)"
fi
if [ "$SIM_EXISTS" = false ] && [ "$PIPE_EXISTS" = false ]; then
echo "    - No stacks found to delete."
fi
if [ -n "$BUCKET_NAME" ]; then
echo "    - Deploy bucket:    $BUCKET_NAME"
fi
echo ""
echo -e "  ${RED}This action cannot be undone.${NC}"
echo ""

if [ "$SKIP_CONFIRM" = false ]; then
    read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Cleanup cancelled."
        exit 0
    fi
fi

# ---- Helper: empty and delete a stack's S3 buckets ----
empty_stack_buckets() {
    local stack="$1"
    local buckets
    buckets=$(aws cloudformation list-stack-resources \
        --stack-name "$stack" \
        --region "$REGION" \
        --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
        --output text 2>/dev/null || echo "")

    if [ -z "$buckets" ]; then
        return
    fi

    for bucket in $buckets; do
        info "Emptying bucket: $bucket"

        # Delete all object versions (needed for versioned buckets)
        aws s3api list-object-versions \
            --bucket "$bucket" \
            --region "$REGION" \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = data.get('Objects')
if objects:
    print(json.dumps({'Objects': objects, 'Quiet': True}))
else:
    sys.exit(1)
" 2>/dev/null | while read -r batch; do
            aws s3api delete-objects --bucket "$bucket" --region "$REGION" --delete "$batch" > /dev/null 2>&1
        done

        # Delete any delete markers
        aws s3api list-object-versions \
            --bucket "$bucket" \
            --region "$REGION" \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = data.get('Objects')
if objects:
    print(json.dumps({'Objects': objects, 'Quiet': True}))
else:
    sys.exit(1)
" 2>/dev/null | while read -r batch; do
            aws s3api delete-objects --bucket "$bucket" --region "$REGION" --delete "$batch" > /dev/null 2>&1
        done

        # Also try simple rm for non-versioned objects
        aws s3 rm "s3://${bucket}" --recursive --region "$REGION" 2>/dev/null || true
        success "Emptied: $bucket"
    done
}

# ---- Helper: delete a stack and wait ----
delete_stack() {
    local stack="$1"
    local label="$2"

    info "Deleting $label: $stack"

    aws cloudformation delete-stack \
        --stack-name "$stack" \
        --region "$REGION"

    info "Waiting for $label deletion..."
    while true; do
        STATUS=$(aws cloudformation describe-stacks \
            --stack-name "$stack" \
            --region "$REGION" \
            --query "Stacks[0].StackStatus" \
            --output text 2>/dev/null || echo "DELETED")

        case "$STATUS" in
            DELETED|DELETE_COMPLETE)
                success "$label deleted!"
                break
                ;;
            DELETE_IN_PROGRESS)
                echo -n "."
                sleep 10
                ;;
            DELETE_FAILED)
                echo ""
                warn "$label deletion failed. You may need to manually delete retained resources."
                break
                ;;
            *)
                success "$label deleted!"
                break
                ;;
        esac
    done
    echo ""
}

# =============================================================================
# STEP 1: Delete Pipeline stack first (no dependencies on simulator)
# =============================================================================
if [ "$PIPE_EXISTS" = true ]; then
    echo ""
    info "Step 1: Deleting Pipeline stack"
    empty_stack_buckets "$PIPELINE_STACK_NAME"
    delete_stack "$PIPELINE_STACK_NAME" "Pipeline stack"
else
    info "Step 1: Pipeline stack '$PIPELINE_STACK_NAME' not found, skipping."
fi

# =============================================================================
# STEP 2: Delete Simulator stack
# =============================================================================
if [ "$SIM_EXISTS" = true ]; then
    echo ""
    info "Step 2: Deleting Simulator stack"
    empty_stack_buckets "$STACK_NAME"
    delete_stack "$STACK_NAME" "Simulator stack"
else
    info "Step 2: Simulator stack '$STACK_NAME' not found, skipping."
fi

# =============================================================================
# STEP 3: Delete the deployment S3 bucket
# =============================================================================
if [ -n "$BUCKET_NAME" ]; then
    echo ""
    info "Step 3: Deleting deployment bucket: $BUCKET_NAME"

    if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
        aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "$REGION" 2>/dev/null || true
        aws s3 rb "s3://${BUCKET_NAME}" --region "$REGION" 2>/dev/null || \
            warn "Could not delete bucket $BUCKET_NAME. Delete it manually from the S3 console."
        success "Deployment bucket deleted: $BUCKET_NAME"
    else
        warn "Bucket $BUCKET_NAME does not exist. Skipping."
    fi
else
    info "Step 3: No deployment bucket specified, skipping."
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo "=============================================================================="
echo -e "  ${GREEN}Cleanup complete!${NC}"
echo "=============================================================================="
echo ""
echo "  Deleted:"
if [ "$PIPE_EXISTS" = true ]; then
echo "    - Pipeline stack:  $PIPELINE_STACK_NAME"
fi
if [ "$SIM_EXISTS" = true ]; then
echo "    - Simulator stack: $STACK_NAME"
fi
if [ -n "$BUCKET_NAME" ]; then
echo "    - Deploy bucket:   $BUCKET_NAME"
fi
echo ""
echo "  Note: CloudWatch log groups may still exist and will expire"
echo "  based on their retention policies (3 months / 1 year)."
echo ""
