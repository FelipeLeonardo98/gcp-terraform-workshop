terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
variable "project_id" {
  type    = string
  default = "workloads-98"
}

variable "app_bucket_location" {
  type    = string
  default = "us-east1"
}

provider "google" { project = var.project_id }

resource "random_id" "suffix" { byte_length = 4 }

resource "google_storage_bucket" "app" {
  name                        = "bucket-000" #"app-bucket-${random_id.suffix.hex}"
  location                    = var.app_bucket_location
  force_destroy               = true
  uniform_bucket_level_access = true
}