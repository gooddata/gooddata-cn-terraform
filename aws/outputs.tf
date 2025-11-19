output "aws_region" { value = var.aws_region }
output "aws_profile_name" { value = var.aws_profile_name }
output "ingress_controller" { value = var.ingress_controller }
output "enable_external_dns" { value = var.enable_external_dns }
output "base_domain" { value = module.k8s_common.base_domain }
output "auth_domain" { value = module.k8s_common.auth_domain }
output "org_domain" { value = module.k8s_common.org_domain }
output "ingress_class_name" { value = module.k8s_common.ingress_class_name }
output "alb_dns_name" {
  value = var.ingress_controller == "alb" && length(data.aws_lb.gdcn) > 0 ? data.aws_lb.gdcn[0].dns_name : ""
}
