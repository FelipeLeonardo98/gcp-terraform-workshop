terraform {
  backend "gcs" {
    bucket = "tfstate-14892"
    prefix = "terraform/state"
  }
}