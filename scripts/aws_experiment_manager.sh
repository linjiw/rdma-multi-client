#!/bin/bash

# AWS Experiment Manager for Secure RDMA Testing
# Manages deployment, testing, and cleanup of AWS resources

set -e

# Configuration
CONFIG_FILE="aws_experiment.conf"
STATE_FILE=".aws_experiment_state"

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_INSTANCE_TYPE="t3.large"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to show usage
usage() {
    cat << EOF
AWS Experiment Manager for Secure RDMA Testing

Usage: $0 [command] [options]

Commands:
    deploy      Launch AWS instance with Soft-RoCE
    test        Run test suite on deployed instance
    monitor     Monitor running experiment
    results     Fetch results from instance
    cleanup     Terminate instance and cleanup resources
    status      Show current deployment status
    ssh         Connect to deployed instance
    cost        Estimate costs

Options:
    -r, --region REGION         AWS region (default: $DEFAULT_REGION)
    -t, --type INSTANCE_TYPE    Instance type (default: $DEFAULT_INSTANCE_TYPE)
    -h, --help                  Show this help message

Examples:
    $0 deploy                   # Deploy with defaults
    $0 deploy -t t3.xlarge      # Deploy with larger instance
    $0 test                     # Run test suite
    $0 results                  # Download test results
    $0 cleanup                  # Terminate and cleanup

EOF
    exit 0
}

# Load state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    fi
}

# Save state
save_state() {
    cat > "$STATE_FILE" << EOF
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
KEY_NAME=$KEY_NAME
SECURITY_GROUP_ID=$SECURITY_GROUP_ID
REGION=$REGION
DEPLOY_TIME=$DEPLOY_TIME
EOF
}

# Deploy function
deploy() {
    echo -e "${BLUE}Deploying AWS instance with Soft-RoCE...${NC}"
    
    # Check for existing deployment
    load_state
    if [ ! -z "$INSTANCE_ID" ]; then
        echo -e "${YELLOW}Warning: Existing deployment found (Instance: $INSTANCE_ID)${NC}"
        read -p "Terminate existing instance and deploy new? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cleanup
        else
            echo "Deployment cancelled."
            exit 1
        fi
    fi
    
    # Set deployment time
    DEPLOY_TIME=$(date +%s)
    
    # Run deployment script
    export INSTANCE_TYPE="$INSTANCE_TYPE"
    export AWS_REGION="$REGION"
    
    bash scripts/deploy_aws_softrce.sh > deploy.log 2>&1 &
    DEPLOY_PID=$!
    
    # Show progress
    echo -n "Deploying"
    while ps -p $DEPLOY_PID > /dev/null; do
        echo -n "."
        sleep 5
    done
    echo
    
    # Check if deployment succeeded
    if wait $DEPLOY_PID; then
        echo -e "${GREEN}✓ Deployment successful!${NC}"
        
        # Extract instance details from log
        INSTANCE_ID=$(grep "Launched instance:" deploy.log | awk '{print $3}')
        PUBLIC_IP=$(grep "Public IP:" deploy.log | awk '{print $3}')
        KEY_NAME=$(grep "Created key pair:" deploy.log | awk '{print $4}')
        
        # Save state
        save_state
        
        echo "Instance ID: $INSTANCE_ID"
        echo "Public IP: $PUBLIC_IP"
        echo "SSH: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
    else
        echo -e "${RED}✗ Deployment failed! Check deploy.log for details.${NC}"
        exit 1
    fi
}

# Test function
test() {
    echo -e "${BLUE}Running test suite on AWS instance...${NC}"
    
    load_state
    if [ -z "$INSTANCE_ID" ] || [ -z "$PUBLIC_IP" ]; then
        echo -e "${RED}No deployment found. Run 'deploy' first.${NC}"
        exit 1
    fi
    
    # Copy test files
    echo "Copying test files to instance..."
    scp -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" \
        scripts/aws_rdma_test_suite.sh \
        ubuntu@"$PUBLIC_IP":~/rdma-project/ 2>/dev/null
    
    # Run tests
    echo "Running tests..."
    ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" \
        "cd rdma-project && bash aws_rdma_test_suite.sh" | tee test_results.log
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}✓ Tests completed successfully!${NC}"
    else
        echo -e "${YELLOW}⚠ Some tests failed. Check test_results.log${NC}"
    fi
}

# Monitor function
monitor() {
    echo -e "${BLUE}Monitoring experiment on AWS instance...${NC}"
    
    load_state
    if [ -z "$INSTANCE_ID" ] || [ -z "$PUBLIC_IP" ]; then
        echo -e "${RED}No deployment found. Run 'deploy' first.${NC}"
        exit 1
    fi
    
    # Copy monitoring script
    echo "Setting up monitoring..."
    scp -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" \
        scripts/monitor_rdma_experiment.sh \
        ubuntu@"$PUBLIC_IP":~/rdma-project/ 2>/dev/null
    
    # Run monitoring
    ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" \
        "cd rdma-project && bash monitor_rdma_experiment.sh"
}

# Results function
results() {
    echo -e "${BLUE}Fetching results from AWS instance...${NC}"
    
    load_state
    if [ -z "$INSTANCE_ID" ] || [ -z "$PUBLIC_IP" ]; then
        echo -e "${RED}No deployment found.${NC}"
        exit 1
    fi
    
    # Create local results directory
    RESULTS_DIR="aws_results_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$RESULTS_DIR"
    
    # Download results
    echo "Downloading results to $RESULTS_DIR..."
    scp -r -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" \
        ubuntu@"$PUBLIC_IP":~/rdma-project/experiment_results/* \
        "$RESULTS_DIR/" 2>/dev/null || true
    
    scp -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" \
        ubuntu@"$PUBLIC_IP":~/rdma-project/*.log \
        "$RESULTS_DIR/" 2>/dev/null || true
    
    echo -e "${GREEN}✓ Results downloaded to $RESULTS_DIR${NC}"
    
    # Display summary if available
    if [ -f "$RESULTS_DIR/*/summary.md" ]; then
        echo
        echo "=== Test Summary ==="
        cat "$RESULTS_DIR"/*/summary.md
    fi
}

# Cleanup function
cleanup() {
    echo -e "${BLUE}Cleaning up AWS resources...${NC}"
    
    load_state
    if [ -z "$INSTANCE_ID" ]; then
        echo "No deployment to cleanup."
        return
    fi
    
    # Terminate instance
    echo "Terminating instance $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
    
    # Wait for termination
    echo "Waiting for instance termination..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
    
    # Delete security group
    if [ ! -z "$SECURITY_GROUP_ID" ]; then
        echo "Deleting security group..."
        aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" --region "$REGION" 2>/dev/null || true
    fi
    
    # Delete key pair
    if [ ! -z "$KEY_NAME" ]; then
        echo "Deleting key pair..."
        aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>/dev/null || true
        rm -f "${KEY_NAME}.pem"
    fi
    
    # Clear state
    rm -f "$STATE_FILE"
    
    echo -e "${GREEN}✓ Cleanup complete!${NC}"
}

# Status function
status() {
    echo -e "${BLUE}AWS Deployment Status${NC}"
    echo "═══════════════════════════════════"
    
    load_state
    if [ -z "$INSTANCE_ID" ]; then
        echo "No active deployment."
        exit 0
    fi
    
    # Get instance status
    STATUS=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "unknown")
    
    echo "Instance ID: $INSTANCE_ID"
    echo "Status: $STATUS"
    echo "Public IP: $PUBLIC_IP"
    echo "Region: $REGION"
    
    if [ ! -z "$DEPLOY_TIME" ]; then
        RUNTIME=$(( ($(date +%s) - DEPLOY_TIME) / 60 ))
        COST=$(echo "scale=2; $RUNTIME * 0.0882 / 60" | bc)
        echo "Runtime: ${RUNTIME} minutes"
        echo "Estimated cost: \$${COST}"
    fi
    
    echo
    echo "SSH: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
}

# SSH function
ssh_connect() {
    load_state
    if [ -z "$PUBLIC_IP" ] || [ -z "$KEY_NAME" ]; then
        echo -e "${RED}No deployment found. Run 'deploy' first.${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Connecting to AWS instance...${NC}"
    ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP"
}

# Cost estimation
cost() {
    echo -e "${BLUE}AWS Cost Estimation${NC}"
    echo "═══════════════════════════════════"
    
    echo "Instance costs (per hour):"
    echo "  t3.large:  \$0.0882"
    echo "  t3.xlarge: \$0.1763"
    echo
    echo "Typical experiment duration: 1-2 hours"
    echo "Estimated total cost: \$0.09 - \$0.35"
    echo
    echo "Note: Soft-RoCE uses standard instances,"
    echo "avoiding expensive EFA instances (\$20+/hour)"
}

# Parse arguments
INSTANCE_TYPE="$DEFAULT_INSTANCE_TYPE"
REGION="$DEFAULT_REGION"

while [[ $# -gt 0 ]]; do
    case $1 in
        deploy|test|monitor|results|cleanup|status|ssh|cost)
            COMMAND=$1
            shift
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -t|--type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Execute command
case $COMMAND in
    deploy)
        deploy
        ;;
    test)
        test
        ;;
    monitor)
        monitor
        ;;
    results)
        results
        ;;
    cleanup)
        cleanup
        ;;
    status)
        status
        ;;
    ssh)
        ssh_connect
        ;;
    cost)
        cost
        ;;
    *)
        usage
        ;;
esac