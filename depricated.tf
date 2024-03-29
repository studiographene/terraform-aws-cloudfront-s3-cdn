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
  description = "DEPRECATED: use `cloudfront_origin_access_control_id` instead."
  type        = string
  default     = null
}

variable "cloudfront_origin_access_identity_path" {
  description = "DEPRECATED: use `cloudfront_origin_access_control_id` instead."
  type        = string
  default     = null
}

variable "forward_query_string" {
  description = "DEPRECATED: Use `cache_policy_id` instead"
  type        = bool
  default     = false
}

variable "query_string_cache_keys" {
  description = "DEPRECATED: Use `cache_policy_id` instead"
  type        = list(string)
  default     = []
}

variable "forward_header_values" {
  description = "DEPRECATED: Use `cache_policy_id` instead"
  type        = list(string)
  default     = ["Access-Control-Request-Headers", "Access-Control-Request-Method", "Origin"]
}

variable "forward_cookies" {
  description = "DEPRECATED: Use `cache_policy_id` instead"
  type        = string
  default     = "none"
}
