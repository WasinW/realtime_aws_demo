#!/bin/bash
# scripts/generate-ssh-key.sh

KEY_NAME="oracle-cdc-demo-key"

# Generate SSH key pair
ssh-keygen -t rsa -b 4096 -f $KEY_NAME -N ""

echo "SSH key pair generated:"
echo "Private key: $KEY_NAME"
echo "Public key: $KEY_NAME.pub"
echo ""
echo "Add the following to your terraform.tfvars:"
echo "ssh_public_key = \"$(cat $KEY_NAME.pub)\""