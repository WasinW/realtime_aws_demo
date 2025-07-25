# terraform/environments/demo/backend.tf
terraform {
  backend "s3" {
    bucket     = "demo-rt-the-one-terraform-state"
    key        = "cdc-pipeline/demo/terraform.tfstate"
    region     = "ap-southeast-1"
    encrypt    = true
    # Use new parameter format
    use_lockfile = true
    dynamodb_table = "demo-rt-the-one-terraform-locks"
  }
}