terraform {
  backend "s3" {
    bucket         = "solana-cluster-tfstate-692046684301"
    key            = "solana-cluster/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "solana-cluster-tfstate-lock"
    encrypt        = true
  }
}
