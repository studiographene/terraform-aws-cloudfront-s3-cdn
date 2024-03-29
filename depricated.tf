locals {
  # use `local.create_cloudfront_origin_access_control` instead
  continue_using_legacy_cloudfront_origin_access_identity = local.enabled && var.continue_using_legacy_cloudfront_origin_access_identity
}

variable "continue_using_legacy_cloudfront_origin_access_identity" {
  description = <<EOF
    Whether to continue using Legacy CloudFront Origin Access Identity.
    For backwards compatibility with resource `cloudfront_origin_access_identity`, set `continue_using_legacy_cloudfront_origin_access_identity = false` to continue using CloudFront Origin Access Control.
  EOF
  type        = bool
  default     = false
}

variable "cloudfront_origin_access_identity_iam_arn" {
  description = <<EOF
    DEPRECATED: use `cloudfront_origin_access_control_id` instead.
  EOF
  type        = string
  default     = null
}

variable "cloudfront_origin_access_identity_path" {
  description = <<EOF
    DEPRECATED: use `cloudfront_origin_access_control_id` instead.
EOF
  type        = string
  default     = null
}
