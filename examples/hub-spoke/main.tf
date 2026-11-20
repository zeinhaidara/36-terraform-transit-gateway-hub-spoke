# Example root: two small spoke VPCs and the hub module.
# Values are placeholders. This has never been applied.
terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

locals {
  spokes = {
    app  = "10.1.0.0/16"
    data = "10.2.0.0/16"
  }
}

resource "aws_vpc" "spoke" {
  for_each   = local.spokes
  cidr_block = each.value
  tags       = { Name = "spoke-${each.key}" }
}

resource "aws_subnet" "spoke_tgw" {
  for_each          = local.spokes
  vpc_id            = aws_vpc.spoke[each.key].id
  cidr_block        = cidrsubnet(each.value, 12, 0)
  availability_zone = "eu-west-2a"
  tags              = { Name = "spoke-${each.key}-tgw" }
}

resource "aws_route_table" "spoke" {
  for_each = local.spokes
  vpc_id   = aws_vpc.spoke[each.key].id
  tags     = { Name = "spoke-${each.key}" }
}

module "hub" {
  source = "../.."

  name              = "example-hub"
  availability_zone = "eu-west-2a"

  spokes = {
    for k, cidr in local.spokes : k => {
      vpc_id          = aws_vpc.spoke[k].id
      cidr            = cidr
      subnet_ids      = [aws_subnet.spoke_tgw[k].id]
      route_table_ids = [aws_route_table.spoke[k].id]
    }
  }

  tags = { project = "network-hub", owner = "platform@example.com" }
}

output "transit_gateway_id" {
  value = module.hub.transit_gateway_id
}
