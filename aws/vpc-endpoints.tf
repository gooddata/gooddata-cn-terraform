###
# VPC endpoints
###

# S3 gateway endpoint: routes S3 traffic (Quiver cache, datasource FS, exports,
# StarRocks) over the AWS backbone instead of the NAT gateway, eliminating NAT
# data-processing charges on blob I/O. Gateway endpoints are free. Only created
# for VPCs we manage; bring-your-own-VPC users add their own.
resource "aws_vpc_endpoint" "s3" {
  count = local.create_vpc ? 1 : 0

  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc[0].private_route_table_ids

  tags = local.common_tags
}
