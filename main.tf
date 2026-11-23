locals {
  subnet_bits          = 28 - tonumber(split("/", var.inspection_vpc_cidr)[1])
  tgw_subnet_cidr      = cidrsubnet(var.inspection_vpc_cidr, local.subnet_bits, 0)
  firewall_subnet_cidr = cidrsubnet(var.inspection_vpc_cidr, local.subnet_bits, 1)

  spoke_route_tables = merge([
    for k, s in var.spokes : { for rt in s.route_table_ids : "${k}/${rt}" => rt }
  ]...)
}

# --- Transit gateway ---------------------------------------------------------

resource "aws_ec2_transit_gateway" "this" {
  description     = "${var.name} hub"
  amazon_side_asn = var.amazon_side_asn

  # Routing is set up explicitly below, so nothing lands in a default table.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "disable"

  tags = merge(var.tags, { Name = "${var.name}-tgw" })
}

# --- Inspection VPC ------------------------------------------------------------

resource "aws_vpc" "inspection" {
  cidr_block = var.inspection_vpc_cidr
  tags       = merge(var.tags, { Name = "${var.name}-inspection" })
}

resource "aws_subnet" "tgw" {
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.tgw_subnet_cidr
  availability_zone = var.availability_zone
  tags              = merge(var.tags, { Name = "${var.name}-inspection-tgw" })
}

resource "aws_subnet" "firewall" {
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.firewall_subnet_cidr
  availability_zone = var.availability_zone
  tags              = merge(var.tags, { Name = "${var.name}-inspection-firewall" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.inspection.id
  subnet_ids         = [aws_subnet.tgw.id]

  # Keeps both directions of a flow on the same firewall endpoint.
  appliance_mode_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.name}-inspection" })
}

# Traffic arriving from the TGW goes to the firewall endpoint.
resource "aws_route_table" "tgw" {
  vpc_id = aws_vpc.inspection.id
  tags   = merge(var.tags, { Name = "${var.name}-inspection-tgw" })
}

resource "aws_route" "tgw_to_firewall" {
  route_table_id         = aws_route_table.tgw.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoint_id

  lifecycle {
    # Without an endpoint in our AZ, inspected traffic would have nowhere to go.
    precondition {
      condition     = local.firewall_endpoint_id != null
      error_message = "The firewall has no endpoint in ${var.availability_zone}, so traffic can't be inspected."
    }
  }
}

resource "aws_route_table_association" "tgw" {
  subnet_id      = aws_subnet.tgw.id
  route_table_id = aws_route_table.tgw.id
}

# Inspected traffic goes back to the TGW.
resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.inspection.id
  tags   = merge(var.tags, { Name = "${var.name}-inspection-firewall" })
}

resource "aws_route" "firewall_to_tgw" {
  route_table_id         = aws_route_table.firewall.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

# --- Spokes ----------------------------------------------------------------------

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each = var.spokes

  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = each.value.vpc_id
  subnet_ids         = each.value.subnet_ids

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.name}-spoke-${each.key}" })
}

resource "aws_route" "spoke_to_tgw" {
  for_each = local.spoke_route_tables

  route_table_id         = each.value
  destination_cidr_block = var.spoke_route_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

# --- TGW route tables ---------------------------------------------------------------

# Spokes only know one way out: the inspection VPC.
resource "aws_ec2_transit_gateway_route_table" "spokes" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-spokes" })
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each = var.spokes

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

# After inspection, traffic goes to whichever spoke owns the destination.
resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-inspection" })
}

resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke" {
  for_each = var.spokes

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}
