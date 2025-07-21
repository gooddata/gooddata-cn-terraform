###
# Allocate elastic IPs for ingress-nginx load balancer
###

resource "aws_eip" "lb" {
  count = length(module.vpc.public_subnets)

  tags = {
    Name = "${var.deployment_name}-ingress-lb-${count.index}"
  }
}

# HACK: AWS LB provisioned by Ingress controller may take some time
# to be destroyed when LoadBalancer service is deleted. Because 3 EIPs
# are associated to LB instances, we need to wait a while before trying
# to destroy aws_eip.lb[*]. This resource affects only destroy phase.
resource "time_sleep" "wait_2min" {
  depends_on = [aws_eip.lb]

  destroy_duration = "2m"
}
