variable "subscription_id" {
  description = "Target subscription ID. Falls back to the ARM_SUBSCRIPTION_ID environment variable when null."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Resource groups
#
# Three groups: one per region so a region can be torn down independently, plus
# a shared group for the resources that must outlive either region (DNS, the
# watchdog, and all monitoring).
# ---------------------------------------------------------------------------

variable "primary_resource_group_name" {
  description = "Resource group for primary region infrastructure."
  type        = string
  default     = "rg-appgw-primary-eus"
}

variable "secondary_resource_group_name" {
  description = "Resource group for secondary region infrastructure."
  type        = string
  default     = "rg-appgw-secondary-cus"
}

variable "shared_resource_group_name" {
  description = "Resource group for private DNS, the watchdog Function App, and monitoring."
  type        = string
  default     = "rg-appgw-dr-shared"
}

variable "primary_location" {
  description = "Primary region. Serves traffic while healthy."
  type        = string
  default     = "eastus"
}

variable "secondary_location" {
  description = "Secondary (DR) region. Receives traffic when the primary fails."
  type        = string
  default     = "centralus"
}

variable "shared_location" {
  description = "Region for the shared resource group. Defaults to the primary region when null."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    businessUnit = "OMP"
    costCenter   = "CIS"
    env          = "Dev"
    owner        = "chase.goebel@ibm.com"
  }
}

# ---------------------------------------------------------------------------
# Addressing
# ---------------------------------------------------------------------------

variable "primary_vnet_address_space" {
  description = "Address space of the primary VNet."
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "secondary_vnet_address_space" {
  description = "Address space of the secondary VNet."
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "primary_appgw_subnet_prefix" {
  description = "Subnet dedicated to the primary Application Gateway."
  type        = string
  default     = "10.1.1.0/24"
}

variable "secondary_appgw_subnet_prefix" {
  description = "Subnet dedicated to the secondary Application Gateway."
  type        = string
  default     = "10.2.1.0/24"
}

variable "primary_aci_subnet_prefix" {
  description = "Subnet delegated to Container Instances in the primary region."
  type        = string
  default     = "10.1.2.0/24"
}

variable "secondary_aci_subnet_prefix" {
  description = "Subnet delegated to Container Instances in the secondary region."
  type        = string
  default     = "10.2.2.0/24"
}

variable "client_subnet_prefix" {
  description = "Subnet for the optional test VM in the primary region."
  type        = string
  default     = "10.1.10.0/24"
}

variable "primary_appgw_private_ip" {
  description = "Static private frontend IP of the primary Application Gateway. Must sit inside primary_appgw_subnet_prefix."
  type        = string
  default     = "10.1.1.10"
}

variable "secondary_appgw_private_ip" {
  description = "Static private frontend IP of the secondary Application Gateway. Must sit inside secondary_appgw_subnet_prefix."
  type        = string
  default     = "10.2.1.10"
}

# ---------------------------------------------------------------------------
# Workload
# ---------------------------------------------------------------------------

variable "container_image" {
  description = "Backend container image. Must serve HTTP 200 on the probe path."
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld"
}

variable "container_port" {
  description = "Port the backend container listens on."
  type        = number
  default     = 80
}

variable "container_cpu" {
  description = "vCPU allocated to each backend container."
  type        = number
  default     = 1
}

variable "container_memory_in_gb" {
  description = "Memory in GB allocated to each backend container."
  type        = number
  default     = 1
}

variable "appgw_capacity" {
  description = "Fixed instance count for each Application Gateway."
  type        = number
  default     = 1
}

variable "health_probe_path" {
  description = "Path the Application Gateway custom probe requests on the backend."
  type        = string
  default     = "/"
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

variable "private_dns_zone_name" {
  description = "Private DNS zone linked to both VNets."
  type        = string
  default     = "internal.contoso.com"
}

variable "dns_record_name" {
  description = "A record the watchdog repoints between regions."
  type        = string
  default     = "app"
}

variable "dns_record_ttl" {
  description = "TTL of the failover A record. Keep it low so clients pick up the swap quickly."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Watchdog Function App
# ---------------------------------------------------------------------------

variable "app_service_plan_sku" {
  description = "App Service plan SKU. Must be a tier that supports Always On so the timer stays warm."
  type        = string
  default     = "B1"
}

variable "python_version" {
  description = "Python version for the Function App runtime."
  type        = string
  default     = "3.11"
}

variable "watchdog_schedule" {
  description = "NCRONTAB schedule for the watchdog. Six fields, so the leading field is seconds."
  type        = string
  default     = "*/30 * * * * *"
}

variable "backend_healthy_states" {
  description = "Application Gateway backend server health values the watchdog treats as up."
  type        = list(string)
  default     = ["Up", "Healthy"]
}

variable "deploy_function_code" {
  description = "Publish the watchdog with an Oryx remote build after the Function App exists. Requires az on PATH."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

variable "log_retention_in_days" {
  description = "Retention for the shared Log Analytics workspace."
  type        = number
  default     = 30
}

variable "alert_email_address" {
  description = "Email notified when the primary custom probe is down. The same action group calls the watchdog webhook, which fails traffic over to the secondary region. Leave empty to keep the webhook and skip email."
  type        = string
  default     = "chase.goebel@ibm.com"
}

variable "unhealthy_host_threshold" {
  description = "UnhealthyHostCount value that trips the failover alert."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Optional test client
# ---------------------------------------------------------------------------

variable "deploy_test_vm" {
  description = "Create a Linux VM in the primary region for curl-based validation. Off by default because of core quota."
  type        = bool
  default     = false
}

variable "test_vm_size" {
  description = "Size of the optional test VM."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "test_vm_admin_username" {
  description = "Admin username on the optional test VM."
  type        = string
  default     = "azureuser"
}

variable "test_vm_ssh_public_key" {
  description = "OpenSSH public key for the test VM. Required when deploy_test_vm is true."
  type        = string
  default     = ""
}
