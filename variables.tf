#bash       terraform apply -var-file="variables.tfvars.json"
#PowerShell terraform apply -var-file='variables.tfvars.json'
#bash       terraform apply -var="IAM_TOKEN=$()"
#PowerShell terraform plan -var "name=value"

variable "iam_token" {
  description = "IAM Token for Yandex Cloud: $(export c)"
  type        = string
  ephemeral = true
}

variable "folder_id" {
  type    = string
}

variable "cloud_id" {
  type = string
}

variable "domain_name" {
  type = string
  nullable = false
}

variable "sa_id" {
  type = string
}