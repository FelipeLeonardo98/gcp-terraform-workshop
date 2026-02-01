terraform {
  backend "gcs" {
    bucket = "tfstate-69133"
    prefix = "terraform/state"
  }
}