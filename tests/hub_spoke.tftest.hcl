# Runs against a mocked AWS provider. Nothing is created in AWS.
mock_provider "aws" {
  # Give the firewall a sync state so the endpoint lookup has something to find.
  mock_resource "aws_networkfirewall_firewall" {
    defaults = {
      firewall_status = [{
        sync_states = [{
          availability_zone = "eu-west-2a"
          attachment = [{
            endpoint_id = "vpce-0123456789abcdef0"
            subnet_id   = "subnet-0f00000000000000f"
            status      = "READY"
          }]
        }]
        capacity_usage_summary                 = []
        configuration_sync_state_summary       = "IN_SYNC"
        status                                 = "READY"
        transit_gateway_attachment_sync_states = []
      }]
    }
  }

  # The provider checks ARN format, so random mock strings won't do.
  mock_resource "aws_networkfirewall_rule_group" {
    defaults = {
      arn = "arn:aws:network-firewall:eu-west-2:123456789012:stateful-rulegroup/hub-example"
    }
  }

  mock_resource "aws_networkfirewall_firewall_policy" {
    defaults = {
      arn = "arn:aws:network-firewall:eu-west-2:123456789012:firewall-policy/hub-policy"
    }
  }
}

variables {
  name              = "hub"
  availability_zone = "eu-west-2a"
  spokes = {
    app = {
      vpc_id          = "vpc-0aaaaaaaaaaaaaaa1"
      cidr            = "10.1.0.0/16"
      subnet_ids      = ["subnet-0aaaaaaaaaaaaaa01", "subnet-0aaaaaaaaaaaaaa02"]
      route_table_ids = ["rtb-0aaaaaaaaaaaaaa01"]
    }
    data = {
      vpc_id          = "vpc-0bbbbbbbbbbbbbbb1"
      cidr            = "10.2.0.0/16"
      subnet_ids      = ["subnet-0bbbbbbbbbbbbbb01"]
      route_table_ids = ["rtb-0bbbbbbbbbbbbbb01", "rtb-0bbbbbbbbbbbbbb02"]
    }
  }
}

run "routing_forces_spokes_through_inspection" {
  command = apply

  assert {
    condition     = aws_ec2_transit_gateway_vpc_attachment.inspection.appliance_mode_support == "enable"
    error_message = "appliance mode must be on for the inspection attachment"
  }

  assert {
    condition     = aws_ec2_transit_gateway.this.default_route_table_association == "disable" && aws_ec2_transit_gateway.this.default_route_table_propagation == "disable"
    error_message = "default TGW route table must not be used"
  }

  assert {
    condition     = aws_ec2_transit_gateway_route.spokes_default.transit_gateway_attachment_id == aws_ec2_transit_gateway_vpc_attachment.inspection.id
    error_message = "spoke route table default route must point at the inspection attachment"
  }

  assert {
    condition     = aws_ec2_transit_gateway_route.spokes_default.transit_gateway_route_table_id == aws_ec2_transit_gateway_route_table.spokes.id
    error_message = "default route must live in the spokes route table"
  }

  assert {
    condition = alltrue([
      for a in aws_ec2_transit_gateway_route_table_association.spoke :
      a.transit_gateway_route_table_id == aws_ec2_transit_gateway_route_table.spokes.id
    ])
    error_message = "every spoke must be associated with the spokes route table"
  }

  assert {
    condition     = aws_ec2_transit_gateway_route_table_association.inspection.transit_gateway_route_table_id == aws_ec2_transit_gateway_route_table.inspection.id
    error_message = "inspection attachment must use the inspection route table"
  }

  assert {
    condition = alltrue([
      for p in aws_ec2_transit_gateway_route_table_propagation.spoke :
      p.transit_gateway_route_table_id == aws_ec2_transit_gateway_route_table.inspection.id
    ])
    error_message = "spokes must propagate only into the inspection route table"
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_route_table_propagation.spoke) == 2
    error_message = "one propagation per spoke expected"
  }

  assert {
    condition     = aws_route.tgw_to_firewall.vpc_endpoint_id == "vpce-0123456789abcdef0"
    error_message = "TGW subnet must send traffic to the firewall endpoint"
  }

  assert {
    condition     = aws_route.firewall_to_tgw.transit_gateway_id == aws_ec2_transit_gateway.this.id
    error_message = "firewall subnet must return traffic to the TGW"
  }

  assert {
    condition     = length(aws_route.spoke_to_tgw) == 3
    error_message = "one route per spoke route table expected"
  }

  assert {
    condition     = aws_subnet.tgw.cidr_block == "100.64.0.0/28" && aws_subnet.firewall.cidr_block == "100.64.0.16/28"
    error_message = "inspection subnets carved from the wrong range"
  }

  assert {
    condition     = output.firewall_endpoint_id == "vpce-0123456789abcdef0"
    error_message = "firewall endpoint output wrong"
  }
}

# Spokes must never reach each other directly: no default tables, no spoke
# propagation into the spokes table, and the inspection subnets are wired in order.
run "spokes_isolated_and_inspection_subnets_wired" {
  command = apply

  assert {
    condition = alltrue([
      for a in aws_ec2_transit_gateway_vpc_attachment.spoke :
      a.transit_gateway_default_route_table_association == false && a.transit_gateway_default_route_table_propagation == false
    ])
    error_message = "spoke attachments must not use the default TGW route table"
  }

  assert {
    condition     = aws_ec2_transit_gateway_vpc_attachment.inspection.transit_gateway_default_route_table_association == false && aws_ec2_transit_gateway_vpc_attachment.inspection.transit_gateway_default_route_table_propagation == false
    error_message = "inspection attachment must not use the default TGW route table"
  }

  assert {
    condition = alltrue([
      for p in aws_ec2_transit_gateway_route_table_propagation.spoke :
      p.transit_gateway_route_table_id != aws_ec2_transit_gateway_route_table.spokes.id
    ])
    error_message = "no spoke may propagate into the spokes route table"
  }

  assert {
    condition     = aws_route_table_association.tgw.subnet_id == aws_subnet.tgw.id && aws_route_table_association.tgw.route_table_id == aws_route_table.tgw.id
    error_message = "TGW subnet must use the route table that points at the firewall"
  }

  assert {
    condition     = aws_route_table_association.firewall.subnet_id == aws_subnet.firewall.id && aws_route_table_association.firewall.route_table_id == aws_route_table.firewall.id
    error_message = "firewall subnet must use the route table that returns to the TGW"
  }

  assert {
    condition     = aws_networkfirewall_firewall_policy.this.firewall_policy[0].stateless_default_actions == toset(["aws:forward_to_sfe"])
    error_message = "stateless default must hand every packet to the stateful rules"
  }
}

run "firewall_endpoint_missing_in_az_fails" {
  command = plan
  # Fresh state, so the firewall from the earlier apply runs isn't reused.
  state_key = "missing_az"

  # The endpoint only exists in eu-west-2b; the module asked for eu-west-2a.
  override_resource {
    target          = aws_networkfirewall_firewall.this
    override_during = plan
    values = {
      firewall_status = [{
        sync_states = [{
          availability_zone = "eu-west-2b"
          attachment = [{
            endpoint_id = "vpce-0123456789abcdef0"
            subnet_id   = "subnet-0f00000000000000f"
            status      = "READY"
          }]
        }]
        capacity_usage_summary                 = []
        configuration_sync_state_summary       = "IN_SYNC"
        status                                 = "READY"
        transit_gateway_attachment_sync_states = []
      }]
    }
  }

  expect_failures = [aws_route.tgw_to_firewall]
}

run "example_rule_allows_only_the_chosen_port" {
  command = plan

  variables {
    allowed_tcp_port = 8443
  }

  assert {
    condition     = aws_networkfirewall_rule_group.example.rule_group[0].rules_source[0].stateful_rule[0].header[0].destination_port == "8443"
    error_message = "pass rule should use allowed_tcp_port"
  }

  assert {
    condition     = aws_networkfirewall_rule_group.example.rule_group[0].rules_source[0].stateful_rule[1].action == "DROP"
    error_message = "second rule should drop everything else"
  }
}

run "empty_spokes_rejected" {
  command = plan

  variables {
    spokes = {}
  }

  expect_failures = [var.spokes]
}

run "bad_spoke_cidr_rejected" {
  command = plan

  variables {
    spokes = {
      app = {
        vpc_id          = "vpc-0aaaaaaaaaaaaaaa1"
        cidr            = "10.1.0.0/33"
        subnet_ids      = ["subnet-0aaaaaaaaaaaaaa01"]
        route_table_ids = []
      }
    }
  }

  expect_failures = [var.spokes]
}

run "duplicate_spoke_cidr_rejected" {
  command = plan

  variables {
    spokes = {
      a = {
        vpc_id          = "vpc-0aaaaaaaaaaaaaaa1"
        cidr            = "10.1.0.0/16"
        subnet_ids      = ["subnet-0aaaaaaaaaaaaaa01"]
        route_table_ids = []
      }
      b = {
        vpc_id          = "vpc-0bbbbbbbbbbbbbbb1"
        cidr            = "10.1.0.0/16"
        subnet_ids      = ["subnet-0bbbbbbbbbbbbbb01"]
        route_table_ids = []
      }
    }
  }

  expect_failures = [var.spokes]
}

run "spoke_without_subnets_rejected" {
  command = plan

  variables {
    spokes = {
      app = {
        vpc_id          = "vpc-0aaaaaaaaaaaaaaa1"
        cidr            = "10.1.0.0/16"
        subnet_ids      = []
        route_table_ids = []
      }
    }
  }

  expect_failures = [var.spokes]
}

run "public_asn_rejected" {
  command = plan

  variables {
    amazon_side_asn = 16509
  }

  expect_failures = [var.amazon_side_asn]
}

run "inspection_cidr_too_small_rejected" {
  command = plan

  variables {
    inspection_vpc_cidr = "100.64.0.0/28"
  }

  expect_failures = [var.inspection_vpc_cidr]
}
