#!/usr/bin/env bash
echo "REPOSITORY: terraform-aws-ecs-service"
echo "SCRIPT: tf-destroy.sh <tfvars file>"
echo "EXECUTING: terraform destroy"

variablesFile="$1"
if [ -z "${variablesFile}" ]; then
    echo "Please specify a variables file in argument 1 for this script"
    exit
fi

if [ ! -e "${variablesFile}" ]; then
    echo "Could not locate variables file: ${variablesFile}"
    exit
fi

# Set name of remote terraform states bucket
env_name=$(sed -n 's/^env_name = "\(.*\)"$/\1/p' $variablesFile)
if [ -z "${env_name}" ]; then
    echo "Please specify an env_name in manifest"
    exit
fi
app_name=$(sed -n 's/^app_name = "\(.*\)"$/\1/p' $variablesFile)
if [ -z "${app_name}" ]; then
    echo "Please specify an app_name in manifest"
    exit
fi
target_aws_region=$(sed -n 's/^region = "\(.*\)"$/\1/p' $variablesFile)
if [ -z "${target_aws_region}" ]; then
    echo "Please specify an target_aws_region in manifest"
    exit
fi
s3_prefix=$(sed -n 's/^s3prefix = "\(.*\)"$/\1/p' $variablesFile)
if [ -z "${s3_prefix}" ]; then
    echo "Please specify an s3prefix in manifest"
    exit
fi

terraform_remote_states_bucket=${s3_prefix}-terraform-states-${target_aws_region}

export AWS_DEFAULT_REGION=${target_aws_region}

# Uncomment if working locally and not via Jenkins
#export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
#export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)

# Uncomment for verbose terraform output
#export TF_LOG=info

# Remove the existing .terraform directory if it exists
rm -rf .terraform* terraform.tfstate.backup

echo "Setting up terraform configuration for remote s3 state file storage"
echo "terraform init -backend-config \"bucket=${terraform_remote_states_bucket}\" -backend-config \"key=${env_name}/${app_name}.tfstate\" -backend-config \"region=${target_aws_region}\""
terraform init \
    -backend-config="bucket=${terraform_remote_states_bucket}" \
    -backend-config="key=${env_name}/${app_name}.tfstate" \
    -backend-config="region=${target_aws_region}"

echo "terraform destroy -force -var-file=\"${variablesFile}\""
if terraform destroy -force -var-file="${variablesFile}"; then
    echo "Terraform destroy succeeded."
else
    echo 'Error: terraform destroy failed.' >&2
    exit 1
fi

echo "Destroy Completed";