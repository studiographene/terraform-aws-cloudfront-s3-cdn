locals {
  # use `local.create_cloudfront_origin_access_control` instead
  continue_using_legacy_cloudfront_origin_access_identity = local.enabled && var.continue_using_legacy_cloudfront_origin_access_identity && length(compact([var.cloudfront_origin_access_identity_iam_arn])) == 0 # "" or null
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
    Existing cloudfront origin access identity iam arn that is supplied in the s3 bucket policy
  EOF
  type        = string
  default     = null
}

variable "cloudfront_origin_access_identity_path" {
  description = <<EOF
    DEPRECATED: use `cloudfront_origin_access_control_id` instead.
    Existing cloudfront origin access identity path used in the cloudfront distribution's s3_origin_config content
EOF
  type        = string
  default     = null
}
