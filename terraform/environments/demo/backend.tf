terraform {
  backend "s3" {
    bucket         = "oracle-cdc-demo-tfstate"
    key            = "demo/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "oracle-cdc-demo-tflock"
    encrypt        = true
  }
}