terraform {
  backend "gcs" {
    bucket = "tfstate-75115"
    prefix = "terraform/state"
  }
}