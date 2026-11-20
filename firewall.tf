# EXAMPLE rule set only: allow one TCP port, drop everything else.
# Replace with your own rules before using this for real traffic.
resource "aws_networkfirewall_rule_group" "example" {
  name     = "${var.name}-example"
  type     = "STATEFUL"
  capacity = 10

  rule_group {
    rules_source {
      stateful_rule {
        action = "PASS"
        header {
          protocol         = "TCP"
          source           = "ANY"
          source_port      = "ANY"
          direction        = "FORWARD"
          destination      = "ANY"
          destination_port = tostring(var.allowed_tcp_port)
        }
        rule_option {
          keyword  = "sid"
          settings = ["1"]
        }
      }

      stateful_rule {
        action = "DROP"
        header {
          protocol         = "IP"
          source           = "ANY"
          source_port      = "ANY"
          direction        = "FORWARD"
          destination      = "ANY"
          destination_port = "ANY"
        }
        rule_option {
          keyword  = "sid"
          settings = ["2"]
        }
      }
    }
  }

  tags = var.tags
}

resource "aws_networkfirewall_firewall_policy" "this" {
  name = "${var.name}-policy"

  firewall_policy {
    # Send everything to the stateful engine; the rule group decides.
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.example.arn
    }
  }

  tags = var.tags
}

resource "aws_networkfirewall_firewall" "this" {
  name                = "${var.name}-firewall"
  vpc_id              = aws_vpc.inspection.id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn

  # One endpoint in one AZ. See README for the trade-off.
  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }

  tags = var.tags
}

locals {
  firewall_endpoint_id = one([
    for s in aws_networkfirewall_firewall.this.firewall_status[0].sync_states :
    s.attachment[0].endpoint_id if s.availability_zone == var.availability_zone
  ])
}
