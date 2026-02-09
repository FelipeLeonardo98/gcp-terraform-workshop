terraform {
  backend "gcs" {
    bucket = "bucket-000"
    prefix = "terraform/state"
  }
}