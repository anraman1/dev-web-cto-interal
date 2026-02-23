variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "lb-poc"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "public_subnet_a_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "public_subnet_b_cidr" {
  type    = string
  default = "10.10.2.0/24"
}

variable "my_ip_cidr" {
  type    = string
  default = ""
}

variable "key_name" {
  type    = string
  default = ""
}