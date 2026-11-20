output "transit_gateway_id" {
  description = "ID of the transit gateway."
  value       = aws_ec2_transit_gateway.this.id
}

output "inspection_vpc_id" {
  description = "ID of the inspection VPC."
  value       = aws_vpc.inspection.id
}

output "firewall_endpoint_id" {
  description = "VPC endpoint ID of the firewall in the chosen AZ."
  value       = local.firewall_endpoint_id
}

output "spoke_attachment_ids" {
  description = "TGW attachment ID per spoke."
  value       = { for k, a in aws_ec2_transit_gateway_vpc_attachment.spoke : k => a.id }
}

output "route_table_ids" {
  description = "TGW route tables for spokes and for the inspection attachment."
  value = {
    spokes     = aws_ec2_transit_gateway_route_table.spokes.id
    inspection = aws_ec2_transit_gateway_route_table.inspection.id
  }
}
