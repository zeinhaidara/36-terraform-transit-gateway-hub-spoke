variable "name" {
  description = "Prefix for resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be 2-31 lowercase letters, digits or hyphens."
  }
}

variable "amazon_side_asn" {
  description = "Private BGP ASN for the transit gateway."
  type        = number
  default     = 64512

  validation {
    condition     = var.amazon_side_asn >= 64512 && var.amazon_side_asn <= 65534
    error_message = "amazon_side_asn must be a 16-bit private ASN (64512-65534)."
  }
}

variable "inspection_vpc_cidr" {
  description = "CIDR for the inspection VPC. Two /28 subnets are carved from it."
  type        = string
  default     = "100.64.0.0/26"

  validation {
    condition     = can(cidrhost(var.inspection_vpc_cidr, 0)) && tonumber(split("/", var.inspection_vpc_cidr)[1]) <= 27
    error_message = "inspection_vpc_cidr must be a valid IPv4 CIDR of /27 or larger."
  }
}

variable "availability_zone" {
  description = "The single AZ that hosts the firewall endpoint, e.g. eu-west-2a."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone must look like eu-west-2a."
  }
}

variable "spokes" {
  description = "Spoke VPCs to attach. Keys are short names."
  type = map(object({
    vpc_id          = string
    cidr            = string
    subnet_ids      = list(string)
    route_table_ids = list(string)
  }))

  validation {
    condition     = length(var.spokes) > 0
    error_message = "At least one spoke is required."
  }

  validation {
    condition     = alltrue([for s in values(var.spokes) : can(cidrhost(s.cidr, 0))])
    error_message = "Every spoke cidr must be a valid IPv4 CIDR."
  }

  validation {
    condition     = length(distinct([for s in values(var.spokes) : s.cidr])) == length(var.spokes)
    error_message = "Spoke CIDRs must be unique."
  }

  validation {
    condition     = alltrue([for s in values(var.spokes) : length(s.subnet_ids) > 0])
    error_message = "Every spoke needs at least one attachment subnet."
  }
}

variable "spoke_route_cidr" {
  description = "Destination added to spoke route tables, pointing at the TGW."
  type        = string
  default     = "10.0.0.0/8"

  validation {
    condition     = can(cidrhost(var.spoke_route_cidr, 0))
    error_message = "spoke_route_cidr must be a valid IPv4 CIDR."
  }
}

variable "allowed_tcp_port" {
  description = "Example rule: the one TCP port allowed between spokes."
  type        = number
  default     = 443

  validation {
    condition     = var.allowed_tcp_port >= 1 && var.allowed_tcp_port <= 65535
    error_message = "allowed_tcp_port must be 1-65535."
  }
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
