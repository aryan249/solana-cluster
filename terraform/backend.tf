terraform {
  backend "s3" {
    bucket         = "solana-cluster-tfstate"
    key            = "solana-cluster/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "solana-cluster-tfstate-lock"
    encrypt        = true
  }
}
