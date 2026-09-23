variable "resource_group_name" {
  description = "Resource group that holds this region's resources."
  type        = string
}

variable "location" {
  description = "Azure region for this stack."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this region."
  type        = map(string)
  default     = {}
}

variable "vnet_name" {
  description = "Name of the regional virtual network."
  type        = string
}

variable "vnet_address_space" {
  description = "Address space of the regional virtual network."
  type        = list(string)
}

variable "appgw_subnet_name" {
  description = "Name of the Application Gateway subnet."
  type        = string
}

variable "appgw_subnet_prefix" {
  description = "CIDR of the Application Gateway subnet."
  type        = string
}

variable "aci_subnet_name" {
  description = "Name of the Container Instances subnet."
  type        = string
}

variable "aci_subnet_prefix" {
  description = "CIDR of the Container Instances subnet."
  type        = string
}

variable "nat_gateway_name" {
  description = "Name of the NAT gateway that gives the ACI subnet outbound access."
  type        = string
}

variable "nat_public_ip_name" {
  description = "Name of the NAT gateway public IP."
  type        = string
}

variable "container_group_name" {
  description = "Name of the backend container group."
  type        = string
}

variable "container_image" {
  description = "Backend container image."
  type        = string
}

variable "container_port" {
  description = "Port the backend container listens on."
  type        = number
}

variable "container_cpu" {
  description = "vCPU allocated to the backend container."
  type        = number
}

variable "container_memory_in_gb" {
  description = "Memory in GB allocated to the backend container."
  type        = number
}

variable "appgw_name" {
  description = "Name of the Application Gateway."
  type        = string
}

variable "appgw_private_ip" {
  description = "Static private frontend IP, which must fall inside appgw_subnet_prefix."
  type        = string
}

variable "appgw_capacity" {
  description = "Fixed instance count for the Application Gateway."
  type        = number
}

variable "health_probe_path" {
  description = "Path the Application Gateway probes on the backend."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Shared workspace that receives this gateway's metrics and access logs, which the dashboard queries."
  type        = string
}
