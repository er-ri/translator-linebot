#!/bin/bash

# LINE Bot Translator Deployment Script
# This script deploys the CloudFormation stack and always updates the Lambda function code

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Command line options
UPDATE_LAYER="false"
FORCE_LAMBDA_UPDATE="true"  # Always force Lambda update (no CLI argument)

# Function to load environment variables from .env file
load_env_file() {
    local env_file=".env"

    if [ -f "$env_file" ]; then
        print_status "Loading environment variables from $env_file"

        # Array to store loaded variables for printing
        local loaded_vars=()

        # Read .env file line by line
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
                continue
            fi

            # Extract key=value pairs
            if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"

                # Remove surrounding quotes from value if present
                if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                    value="${BASH_REMATCH[1]}"
                fi

                # Export the variable only if it's not already set
                if [ -z "${!key}" ]; then
                    export "$key=$value"
                    # Mask sensitive values for printing
                    if [[ "$key" =~ (TOKEN|SECRET|PASSWORD|KEY) ]]; then
                        loaded_vars+=("$key=***masked***")
                    else
                        loaded_vars+=("$key=$value")
                    fi
                    print_status "  Loaded: $key=${key=~/TOKEN|SECRET|PASSWORD|KEY/ ? "***masked***" : "$value"}"
                else
                    print_status "  Skipped: $key (already set)"
                fi
            fi
        done < "$env_file"

        print_success "Environment variables loaded from $env_file"

        # Print summary of loaded variables
        if [ ${#loaded_vars[@]} -gt 0 ]; then
            print_status "Summary of loaded environment variables:"
            for var in "${loaded_vars[@]}"; do
                print_status "  $var"
            done
        else
            print_status "No new environment variables were loaded (all were already set)"
        fi
    else
        print_warning ".env file not found. Please ensure environment variables are set manually."
    fi
}

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi

    # Check if AWS credentials are configured
    if ! aws sts get-caller-identity --profile "$PROFILE_NAME" &> /dev/null; then
        print_error "AWS credentials not configured for profile '$PROFILE_NAME'. Please run 'aws configure --profile $PROFILE_NAME'"
        exit 1
    fi
}

# Function to check if ZIP utility is installed
check_zip() {
    if ! command -v zip &> /dev/null; then
        print_error "ZIP utility is not installed. Please install it first."
        exit 1
    fi
}

# Function to check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        print_error "jq command is not installed. Please install it first (needed for JSON parsing)."
        exit 1
    fi
}

# Function to check if uv is installed (for faster dependency installation)
check_uv() {
    if ! command -v uv &> /dev/null; then
        print_warning "uv is not installed. Falling back to pip (slower)."
        return 1
    fi
    return 0
}

# Function to validate parameters
validate_parameters() {
    if [ -z "$LINE_CHANNEL_ACCESS_TOKEN" ]; then
        print_error "LINE_CHANNEL_ACCESS_TOKEN is required"
        exit 1
    fi

    if [ -z "$LINE_CHANNEL_SECRET" ]; then
        print_error "LINE_CHANNEL_SECRET is required"
        exit 1
    fi
}

# Function to deploy CloudFormation stack
deploy_stack() {
    print_status "Deploying CloudFormation stack: $STACK_NAME"

    # Initialize stack update flag
    STACK_UPDATED="false"

    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --profile "$PROFILE_NAME" &> /dev/null; then
        print_status "Stack exists, checking for changes..."
        ACTION="update-stack"

        # Try to update the stack
        UPDATE_OUTPUT=$(aws cloudformation $ACTION \
            --stack-name "$STACK_NAME" \
            --template-body file://cloudformation-template.yaml \
            --parameters \
                ParameterKey=LineChannelAccessToken,ParameterValue="$LINE_CHANNEL_ACCESS_TOKEN" \
                ParameterKey=LineChannelSecret,ParameterValue="$LINE_CHANNEL_SECRET" \
                ParameterKey=BedrockRegion,ParameterValue="$BEDROCK_REGION" \
                ParameterKey=BedrockModelId,ParameterValue="$BEDROCK_MODEL_ID" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$AWS_REGION" \
            --profile "$PROFILE_NAME" 2>&1) || UPDATE_EXIT_CODE=$?

        # Check if update was successful or if no changes were detected
        if [ "${UPDATE_EXIT_CODE:-0}" -eq 0 ]; then
            print_status "Stack update initiated successfully"
            STACK_UPDATED="true"

            print_status "Waiting for stack update to complete..."
            aws cloudformation wait stack-update-complete \
                --stack-name "$STACK_NAME" \
                --region "$AWS_REGION" \
                --profile "$PROFILE_NAME"

            print_success "CloudFormation stack updated successfully"
        elif echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
            print_success "No changes detected in CloudFormation template - stack is up to date"
            STACK_UPDATED="false"
        else
            print_error "Stack update failed: $UPDATE_OUTPUT"
            exit 1
        fi
    else
        print_status "Creating new stack..."
        ACTION="create-stack"
        STACK_UPDATED="true"

        # Deploy stack
        aws cloudformation $ACTION \
            --stack-name "$STACK_NAME" \
            --template-body file://cloudformation-template.yaml \
            --parameters \
                ParameterKey=LineChannelAccessToken,ParameterValue="$LINE_CHANNEL_ACCESS_TOKEN" \
                ParameterKey=LineChannelSecret,ParameterValue="$LINE_CHANNEL_SECRET" \
                ParameterKey=BedrockRegion,ParameterValue="$BEDROCK_REGION" \
                ParameterKey=BedrockModelId,ParameterValue="$BEDROCK_MODEL_ID" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$AWS_REGION" \
            --profile "$PROFILE_NAME"

        print_status "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete \
            --stack-name "$STACK_NAME" \
            --region "$AWS_REGION" \
            --profile "$PROFILE_NAME"

        print_success "CloudFormation stack created successfully"
    fi
}

# Function to create Lambda layer with dependencies
create_lambda_layer() {
    print_status "Creating Lambda layer with dependencies..."

    # Clean up previous layer package
    rm -rf layer-package
    rm -f lambda-layer.zip

    # Create layer package directory structure
    mkdir -p layer-package/python

    # Install dependencies into layer structure
    print_status "Installing Python dependencies for layer..."

    if check_uv; then
        # Use uv for faster installation
        uv pip install -r requirements-layer.txt --target layer-package/python/ --quiet
    else
        # Fall back to pip
        pip install -r requirements-layer.txt --target layer-package/python/ --quiet
    fi

    # Create layer ZIP file
    cd layer-package
    zip -r ../lambda-layer.zip . > /dev/null
    cd ..

    print_success "Lambda layer package created: lambda-layer.zip ($(du -h lambda-layer.zip | cut -f1))"
}

# Function to create function deployment package (without dependencies)
create_function_package() {
    print_status "Creating function deployment package..."

    # Clean up previous function package
    rm -rf function-package
    rm -f lambda-function.zip

    # Create function package directory
    mkdir -p function-package

    # Copy only the Lambda function (no dependencies)
    cp lambda_function.py function-package/

    # Create function ZIP file
    cd function-package
    zip -r ../lambda-function.zip . > /dev/null
    cd ..

    print_success "Function package created: lambda-function.zip ($(du -h lambda-function.zip | cut -f1))"
}

# Function to check if CloudFormation stack exists
check_stack_exists() {
    if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --profile "$PROFILE_NAME" &> /dev/null; then
        print_error "CloudFormation stack '$STACK_NAME' does not exist in region '$AWS_REGION'"
        print_error "Please deploy the stack first using ./deploy.sh"
        exit 1
    fi

    print_success "CloudFormation stack '$STACK_NAME' found"
}

# Function to get Lambda function name from CloudFormation stack
get_lambda_function_name() {
    print_status "Getting Lambda function name from CloudFormation stack..."

    FUNCTION_NAME=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
        --output text \
        --profile "$PROFILE_NAME")

    if [ -z "$FUNCTION_NAME" ] || [ "$FUNCTION_NAME" = "None" ]; then
        print_error "Could not retrieve Lambda function name from stack '$STACK_NAME'"
        print_error "Make sure the stack has a 'LambdaFunctionName' output"
        exit 1
    fi

    print_success "Found Lambda function: $FUNCTION_NAME"
}

# Function to create or update Lambda layer
create_or_update_layer() {
    print_status "Creating or updating Lambda layer..."

    local layer_name="${STACK_NAME}-dependencies"

    # Check if layer already exists
    local layer_exists=false
    if aws lambda list-layers --region "$AWS_REGION" --profile "$PROFILE_NAME" --query "Layers[?LayerName=='$layer_name']" --output text | grep -q "$layer_name"; then
        layer_exists=true
        print_status "Layer '$layer_name' already exists, publishing new version..."
    else
        print_status "Creating new layer '$layer_name'..."
    fi

    # Publish layer version
    LAYER_RESULT=$(aws lambda publish-layer-version \
        --layer-name "$layer_name" \
        --description "Dependencies for $STACK_NAME Lambda function" \
        --zip-file fileb://lambda-layer.zip \
        --compatible-runtimes python3.9 python3.10 python3.11 python3.12 \
        --region "$AWS_REGION" \
        --profile "$PROFILE_NAME" \
        --output json)

    # Extract layer ARN
    LAYER_ARN=$(echo "$LAYER_RESULT" | jq -r '.LayerArn' 2>/dev/null)
    LAYER_VERSION=$(echo "$LAYER_RESULT" | jq -r '.Version' 2>/dev/null)

    if [ -z "$LAYER_ARN" ] || [ "$LAYER_ARN" = "null" ]; then
        print_error "Failed to create/update Lambda layer"
        exit 1
    fi

    print_success "Layer published successfully"
    print_status "Layer ARN: $LAYER_ARN"
    print_status "Layer Version: $LAYER_VERSION"

    # Store the versioned layer ARN
    LAYER_VERSION_ARN="$LAYER_ARN:$LAYER_VERSION"
}

# Function to update Lambda function code
update_lambda_code() {
    print_status "Updating Lambda function code..."

    # Update function code
    UPDATE_RESULT=$(aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file fileb://lambda-function.zip \
        --region "$AWS_REGION" \
        --profile "$PROFILE_NAME" \
        --output json)

    # Get the update timestamp
    LAST_MODIFIED=$(echo "$UPDATE_RESULT" | jq -r '.LastModified' 2>/dev/null || echo "Unknown")

    print_success "Lambda function code updated successfully"
    print_status "Last modified: $LAST_MODIFIED"
}

# Function to update Lambda function configuration with layer
update_lambda_configuration() {
    print_status "Updating function configuration to use layer..."

    aws lambda update-function-configuration \
        --function-name "$FUNCTION_NAME" \
        --layers "$LAYER_VERSION_ARN" \
        --region "$AWS_REGION" \
        --profile "$PROFILE_NAME" \
        --output json > /dev/null

    print_success "Function configuration updated with layer"
}

# Function to wait for function update to complete
wait_for_update() {
    local operation_type="${1:-update}"
    print_status "Waiting for function ${operation_type} to complete..."

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local state=$(aws lambda get-function \
            --function-name "$FUNCTION_NAME" \
            --region "$AWS_REGION" \
            --profile "$PROFILE_NAME" \
            --query 'Configuration.State' \
            --output text 2>/dev/null || echo "Unknown")

        if [ "$state" = "Active" ]; then
            print_success "Function is now active and ready to use"
            return 0
        elif [ "$state" = "Pending" ] || [ "$state" = "InProgress" ]; then
            echo -n "."
            sleep 2
            ((attempt++))
        else
            print_warning "Function state: $state"
            sleep 2
            ((attempt++))
        fi
    done

    print_warning "Function ${operation_type} may still be in progress. Check AWS console for status."
}

# Function to get stack outputs
get_stack_outputs() {
    print_status "Getting deployment information..."

    WEBHOOK_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`WebhookUrl`].OutputValue' \
        --output text \
        --profile "$PROFILE_NAME")

    print_success "Deployment completed successfully!"
    echo ""
    echo "================================================"
    echo "DEPLOYMENT INFORMATION"
    echo "================================================"
    echo "Stack Name: $STACK_NAME"
    echo "Region: $AWS_REGION"
    echo "Webhook URL: $WEBHOOK_URL"
    echo ""
    echo "NEXT STEPS:"
    echo "1. Go to LINE Developers Console"
    echo "2. Set webhook URL: $WEBHOOK_URL"
    echo "3. Enable webhook for your LINE channel"
    echo "4. Add bot to LINE group/chat"
    echo "5. Test with: Hello world #e2j"
    echo "================================================"
}

# Function to clean up
cleanup() {
    print_status "Cleaning up temporary files..."
    rm -rf package
    rm -rf layer-package
    rm -rf function-package
    rm -f lambda-deployment.zip
    rm -f lambda-layer.zip
    rm -f lambda-function.zip
}

# Main execution
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --update-layer)
                UPDATE_LAYER="true"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done

    echo "LINE Bot Translator Deployment Script"
    echo "====================================="

    # Check prerequisites
    check_aws_cli
    check_zip
    check_jq

    # Load environment variables from .env file
    load_env_file

    # Validate parameters
    validate_parameters

    # Verify that required files exist
    if [ ! -f "lambda_function.py" ]; then
        print_error "lambda_function.py not found in current directory"
        exit 1
    fi

    # Check requirements-layer.txt only if UPDATE_LAYER is true
    if [[ "$UPDATE_LAYER" == "true" ]] && [ ! -f "requirements-layer.txt" ]; then
        print_error "requirements-layer.txt not found in current directory (required when --update-layer is specified)"
        exit 1
    fi

    echo "Mode: Full CloudFormation deployment with Lambda update"
    echo "Configuration:"
    echo "  Stack Name: $STACK_NAME"
    echo "  Region: $AWS_REGION"
    echo "  Profile: $PROFILE_NAME"
    echo "  Update Layer: $UPDATE_LAYER"
    echo "  Force Lambda Update: $FORCE_LAMBDA_UPDATE (always enabled)"
    echo ""

    # Execute deployment steps
    deploy_stack
    get_stack_outputs

    # Update Lambda function only if stack was updated OR if user explicitly requested layer/lambda update
    if [[ "$STACK_UPDATED" == "true" ]] || [[ "$UPDATE_LAYER" == "true" ]] || [[ "$FORCE_LAMBDA_UPDATE" == "true" ]]; then
        if [[ "$STACK_UPDATED" == "true" ]]; then
            print_status "Stack was updated - updating Lambda function..."
        elif [[ "$UPDATE_LAYER" == "true" ]]; then
            print_status "Updating Lambda function (layer update requested)..."
        else
            print_status "Updating Lambda function (forced update)..."
        fi

        check_stack_exists
        get_lambda_function_name

        # Only create and update layer if UPDATE_LAYER is true
        if [[ "$UPDATE_LAYER" == "true" ]]; then
            create_lambda_layer
            create_or_update_layer
        fi

        create_function_package
        update_lambda_code
        wait_for_update "code update"

        # Only update configuration with layer if layer was updated
        if [[ "$UPDATE_LAYER" == "true" ]]; then
            update_lambda_configuration
            wait_for_update "configuration update"
        fi

        print_success "Lambda function update completed!"
    else
        print_status "Stack was not updated and no lambda/layer update requested - skipping Lambda function update"

        # Still get the function name for display purposes
        check_stack_exists
        get_lambda_function_name
    fi

    cleanup

    echo ""
    echo "================================================"
    echo "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    echo "================================================"
    echo "Stack Name: $STACK_NAME"
    echo "Function Name: $FUNCTION_NAME"
    echo "Region: $AWS_REGION"
    echo "Webhook URL: $WEBHOOK_URL"
    if [[ "$STACK_UPDATED" == "true" ]] || [[ "$UPDATE_LAYER" == "true" ]] || [[ "$FORCE_LAMBDA_UPDATE" == "true" ]]; then
        echo "Lambda Function: UPDATED"
        if [[ "$UPDATE_LAYER" == "true" ]]; then
            echo "Layer ARN: $LAYER_VERSION_ARN"
        fi
    else
        echo "Lambda Function: NOT UPDATED (no changes detected)"
    fi
    echo "================================================"
}

# Function to show help information
show_help() {
    echo "LINE Bot Translator Deployment Script"
    echo "===================================="
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "This script deploys the CloudFormation stack and updates the Lambda function when needed."
    echo "All configuration is read from the .env file."
    echo ""
    echo "Options:"
    echo "  --update-layer  Update Lambda layer with dependencies during deployment"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Required environment variables (in .env file):"
    echo "  LINE_CHANNEL_ACCESS_TOKEN    LINE Channel Access Token"
    echo "  LINE_CHANNEL_SECRET          LINE Channel Secret"
    echo ""
    echo "Optional environment variables (in .env file):"
    echo "  STACK_NAME                   CloudFormation stack name (default: translator-linebot)"
    echo "  AWS_REGION                   AWS region (default: ap-northeast-1)"
    echo "  BEDROCK_REGION               Bedrock region (default: ap-northeast-1)"
    echo "  BEDROCK_MODEL_ID             Bedrock model ID (default: apac.amazon.nova-pro-v1:0)"
    echo "  PROFILE_NAME                 AWS profile name (default: default)"
    echo ""
    echo "Example usage:"
    echo "  $0                           # Deploy stack and update Lambda if stack changes"
    echo "  $0 --update-layer            # Deploy stack and update Lambda function with layer"
    echo ""
    echo "The script will:"
    echo "  1. Deploy or update the CloudFormation stack"
    echo "  2. If stack was updated, Lambda function code will be updated automatically"
    echo "  3. If --update-layer is specified, create/update Lambda layer with dependencies"
    echo "  4. Wait for all updates to complete"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Run main function
main "$@"
