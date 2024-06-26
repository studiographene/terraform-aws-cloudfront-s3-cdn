locals {
  enabled = module.this.enabled

  # Encapsulate logic here so that it is not lost/scattered among the configuration
  website_enabled           = local.enabled && var.website_enabled
  website_password_enabled  = local.website_enabled && var.s3_website_password_enabled
  s3_origin_enabled         = local.enabled && !var.website_enabled
  create_s3_origin_bucket   = local.enabled && var.origin_bucket == null
  s3_access_logging_enabled = local.enabled && (var.s3_access_logging_enabled == null ? length(var.s3_access_log_bucket_name) > 0 : var.s3_access_logging_enabled)
  create_cf_log_bucket      = local.enabled && var.cloudfront_access_logging_enabled && var.cloudfront_access_log_create_bucket

  create_cloudfront_origin_access_control = local.enabled && !var.continue_using_legacy_cloudfront_origin_access_identity && var.cloudfront_origin_access_control_id == null

  origin_id   = coalesce(var.default_origin_descriptive_name, module.this.id)
  origin_path = coalesce(var.origin_path, "/")
  # Collect the information for whichever S3 bucket we are using as the origin
  origin_bucket_placeholder = {
    arn                         = ""
    bucket                      = ""
    website_domain              = ""
    website_endpoint            = ""
    bucket_regional_domain_name = ""
  }
  origin_bucket_options = {
    new      = local.create_s3_origin_bucket ? aws_s3_bucket.origin[0] : null
    existing = local.enabled && var.origin_bucket != null ? data.aws_s3_bucket.origin[0] : null
    disabled = local.origin_bucket_placeholder
  }
  # Workaround for requirement that tertiary expression has to have exactly matching objects in both result values
  origin_bucket = local.origin_bucket_options[local.enabled ? (local.create_s3_origin_bucket ? "new" : "existing") : "disabled"]


  # Collect the information for cloudfront_origin_access_identity_iam and shorten the variable names
  legacy_cf_access_identity = {
    arn  = local.continue_using_legacy_cloudfront_origin_access_identity ? aws_cloudfront_origin_access_identity.default[0].iam_arn : ""
    path = local.continue_using_legacy_cloudfront_origin_access_identity ? aws_cloudfront_origin_access_identity.default[0].cloudfront_access_identity_path : ""
  }

  cf_access_control_id = var.cloudfront_origin_access_control_id != null ? var.cloudfront_origin_access_control_id : try(aws_cloudfront_origin_access_control.default[0].id, null)

  # Pick the IAM policy document based on whether the origin is an S3 origin or a Website origin
  iam_policy_document = local.enabled ? (
    local.website_enabled ? data.aws_iam_policy_document.s3_website_origin[0].json : data.aws_iam_policy_document.s3_origin[0].json
  ) : ""

  bucket             = local.origin_bucket.bucket
  bucket_domain_name = var.website_enabled ? local.origin_bucket.website_endpoint : local.origin_bucket.bucket_regional_domain_name

  override_origin_bucket_policy = local.enabled && var.override_origin_bucket_policy

  lookup_cf_log_bucket = var.cloudfront_access_logging_enabled && !var.cloudfront_access_log_create_bucket
  cf_log_bucket_domain = var.cloudfront_access_logging_enabled ? (
    local.lookup_cf_log_bucket ? data.aws_s3_bucket.cf_logs[0].bucket_domain_name : aws_s3_bucket.cf_log[0].bucket_domain_name
  ) : ""

  use_default_acm_certificate = var.acm_certificate_arn == ""
  minimum_protocol_version    = var.minimum_protocol_version == "" ? (local.use_default_acm_certificate ? "TLSv1" : "TLSv1.2_2021") : var.minimum_protocol_version

  # Based on https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/origin-shield.html#choose-origin-shield-region
  # If a region is not specified, we assume it supports Origin Shield.
  origin_shield_region_fallback_map = {
    "us-west-1"    = "us-west-2"
    "af-south-1"   = "eu-west-1"
    "ap-east-1"    = "ap-southeast-1"
    "ca-central-1" = "us-east-1"
    "eu-south-1"   = "eu-central-1"
    "eu-west-3"    = "eu-west-2"
    "eu-north-1"   = "eu-west-2"
    "me-south-1"   = "ap-south-1"
  }
  origin_shield_region = local.enabled ? lookup(local.origin_shield_region_fallback_map, data.aws_region.current[0].name, data.aws_region.current[0].name) : "this string is never used"
}

## Make up for deprecated template_file and lack of templatestring
# https://github.com/hashicorp/terraform-provider-template/issues/85
# https://github.com/hashicorp/terraform/issues/26838
locals {
  override_policy = replace(replace(replace(replace(var.additional_bucket_policy,
    "$${origin_path}", local.origin_path),
    "$${bucket_name}", local.bucket),
    "$${cloudfront_origin_access_identity_iam_arn}", local.legacy_cf_access_identity.arn),
  "$${cloudfront_arn}", aws_cloudfront_distribution.default[0].arn)
}

data "aws_partition" "current" {
  count = local.enabled ? 1 : 0
}

data "aws_region" "current" {
  count = local.enabled ? 1 : 0
}

module "origin_label" {
  source  = "app.terraform.io/studiographene/sg-label/null"
  version = "1.0.4"

  attributes = var.extra_origin_attributes

  context = module.this.context
}

resource "aws_cloudfront_origin_access_identity" "default" {
  count = local.continue_using_legacy_cloudfront_origin_access_identity ? 1 : 0

  comment = module.this.id
}

# incase of moving from `aws_cloudfront_origin_access_identity` to `aws_cloudfront_origin_access_control`
# 1. Terraform apply
# 2. Manually update the OAI to OAC from CloudFront console
# 3. Terraform apply once again
# because Terraform will try to destroy the  `aws_cloudfront_origin_access_identity` before it is replaced by `aws_cloudfront_origin_access_control`
# which causes aws_cloudfront_origin_access_control is in use by CloudFront error

resource "aws_cloudfront_origin_access_control" "default" {
  count = local.create_cloudfront_origin_access_control ? 1 : 0

  name                              = module.this.id
  origin_access_control_origin_type = "s3"
  signing_behavior                  = var.cloudfront_origin_access_control_signing_behavior
  signing_protocol                  = "sigv4"
}

resource "random_password" "referer" {
  count = local.website_password_enabled ? 1 : 0

  length  = 32
  special = false
}

data "aws_iam_policy_document" "s3_origin" {
  count = local.s3_origin_enabled ? 1 : 0

  override_policy_documents = [local.override_policy]

  statement {
    sid = "S3GetObjectForCloudFront"

    actions   = ["s3:GetObject"]
    resources = ["arn:${join("", data.aws_partition.current.*.partition)}:s3:::${local.bucket}${local.origin_path}*"]

    principals {
      type        = local.create_cloudfront_origin_access_control ? "Service" : "AWS"
      identifiers = [local.create_cloudfront_origin_access_control ? "cloudfront.amazonaws.com" : local.legacy_cf_access_identity.arn]
    }

    dynamic "condition" {
      for_each = local.create_cloudfront_origin_access_control ? [1] : []
      content {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.default[0].arn]
      }
    }
  }

  statement {
    sid = "S3ListBucketForCloudFront"

    actions   = ["s3:ListBucket"]
    resources = ["arn:${join("", data.aws_partition.current.*.partition)}:s3:::${local.bucket}"]

    principals {
      type        = local.create_cloudfront_origin_access_control ? "Service" : "AWS"
      identifiers = [local.create_cloudfront_origin_access_control ? "cloudfront.amazonaws.com" : local.legacy_cf_access_identity.arn]
    }

    dynamic "condition" {
      for_each = local.create_cloudfront_origin_access_control ? [1] : []
      content {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.default[0].arn]
      }
    }
  }
}

data "aws_iam_policy_document" "s3_website_origin" {
  count = local.website_enabled ? 1 : 0

  override_policy_documents = [local.override_policy]

  statement {
    sid = "S3GetObjectForCloudFront"

    actions   = ["s3:GetObject"]
    resources = ["arn:${join("", data.aws_partition.current.*.partition)}:s3:::${local.bucket}${local.origin_path}*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    dynamic "condition" {
      for_each = local.website_password_enabled ? ["password"] : []

      content {
        test     = "StringEquals"
        variable = "aws:referer"
        values   = [random_password.referer[0].result]
      }
    }
  }
}

data "aws_iam_policy_document" "deployment" {
  for_each = local.enabled ? var.deployment_principal_arns : {}

  statement {
    actions = var.deployment_actions

    resources = distinct(flatten([
      [local.origin_bucket.arn],
      formatlist("${local.origin_bucket.arn}/%s*", each.value),
    ]))

    principals {
      type        = "AWS"
      identifiers = [each.key]
    }
  }
}

data "aws_iam_policy_document" "s3_ssl_only" {
  count = var.allow_ssl_requests_only ? 1 : 0
  statement {
    sid     = "ForceSSLOnlyAccess"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      local.origin_bucket.arn,
      "${local.origin_bucket.arn}/*"
    ]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "Bool"
      values   = ["false"]
      variable = "aws:SecureTransport"
    }
  }
}

data "aws_iam_policy_document" "combined" {
  count = local.enabled ? 1 : 0

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.s3_origin.*.json,
    data.aws_iam_policy_document.s3_website_origin.*.json,
    data.aws_iam_policy_document.s3_ssl_only.*.json,
    values(data.aws_iam_policy_document.deployment)[*].json
  ))
}

resource "aws_s3_bucket_policy" "default" {
  count = local.create_s3_origin_bucket || local.override_origin_bucket_policy ? 1 : 0

  bucket = local.origin_bucket.bucket
  policy = join("", data.aws_iam_policy_document.combined.*.json)
}

resource "aws_s3_bucket" "origin" {
  #bridgecrew:skip=BC_AWS_S3_13:Skipping `Enable S3 Bucket Logging` because we cannot enable it by default because we do not have a default destination for it.
  #bridgecrew:skip=CKV_AWS_52:Skipping `Ensure S3 bucket has MFA delete enabled` due to issue in terraform (https://github.com/hashicorp/terraform-provider-aws/issues/629).
  #bridgecrew:skip=BC_AWS_NETWORKING_52:Skipping `Ensure S3 Bucket has public access blocks` because we have an `aws_s3_bucket_public_access_block` resource rather than inline `block_public_*` attributes.
  #bridgecrew:skip=BC_AWS_GENERAL_72:Skipping `Ensure S3 bucket has cross-region replication enabled` because this is out of scope of this module's use case.
  #bridgecrew:skip=BC_AWS_GENERAL_56:Skipping `Ensure S3 buckets are encrypted with KMS by default` because this module has configurable encryption via `var.encryption_enabled`.
  count = local.create_s3_origin_bucket ? 1 : 0

  bucket        = coalesce(var.default_origin_bucket_custom_name, module.origin_label.id)
  tags          = module.origin_label.tags
  force_destroy = var.origin_force_destroy
}

resource "aws_s3_bucket_versioning" "origin" {
  bucket = local.bucket
  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "origin" {
  count = var.encryption_enabled ? 1 : 0

  bucket = local.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_accelerate_configuration" "origin" {
  count = var.origin_s3_bucket_accelerate_enabled ? 1 : 0

  bucket = local.bucket
  status = "Enabled"
}

resource "aws_s3_bucket_logging" "origin" {
  count = local.s3_access_logging_enabled ? 1 : 0

  bucket        = local.bucket
  target_bucket = var.s3_access_log_bucket_name
  target_prefix = coalesce(var.s3_access_log_prefix, "logs/${local.origin_id}/")
}

resource "aws_s3_bucket_public_access_block" "origin" {
  count                   = (local.create_s3_origin_bucket || local.override_origin_bucket_policy) ? 1 : 0
  bucket                  = local.bucket
  block_public_acls       = var.origin_block_public_acls
  block_public_policy     = var.origin_block_public_policy
  ignore_public_acls      = var.origin_ignore_public_acls
  restrict_public_buckets = var.origin_restrict_public_buckets

  # Don't modify this bucket in two ways at the same time, S3 API will complain.
  depends_on = [aws_s3_bucket_policy.default]
}

resource "aws_s3_bucket_ownership_controls" "origin" {
  count = local.create_s3_origin_bucket ? 1 : 0

  bucket = local.bucket

  rule {
    object_ownership = var.s3_object_ownership
  }

  depends_on = [time_sleep.wait_for_aws_s3_bucket_settings]
}

resource "aws_s3_bucket_cors_configuration" "origin" {
  count  = length(distinct(compact(concat(var.cors_allowed_origins, var.aliases, var.external_aliases)))) > 0 ? 1 : 0
  bucket = local.bucket

  dynamic "cors_rule" {
    for_each = distinct(compact(concat(var.cors_allowed_origins, var.aliases, var.external_aliases)))

    content {
      allowed_headers = var.cors_allowed_headers
      allowed_methods = var.cors_allowed_methods
      allowed_origins = [cors_rule.value]
      expose_headers  = var.cors_expose_headers
      max_age_seconds = var.cors_max_age_seconds
    }
  }
}

resource "aws_s3_bucket_website_configuration" "origin" {
  count = var.website_enabled ? 1 : 0

  bucket = local.bucket

  dynamic "index_document" {
    for_each = var.s3_website_redirect_all_requests_to == null ? ["true"] : []

    content {
      suffix = var.s3_website_index_document
    }
  }

  dynamic "error_document" {
    for_each = var.s3_website_redirect_all_requests_to == null && var.s3_website_error_document != null ? ["true"] : []

    content {
      key = var.s3_website_error_document
    }
  }

  dynamic "redirect_all_requests_to" {
    for_each = var.s3_website_redirect_all_requests_to != null ? ["true"] : []

    content {
      host_name = var.s3_website_redirect_all_requests_to
    }
  }

  routing_rules = var.s3_website_routing_rules
}

# Workaround for S3 eventual consistency for settings relating to objects
resource "time_sleep" "wait_for_aws_s3_bucket_settings" {
  count = local.create_s3_origin_bucket ? 1 : 0

  create_duration  = "30s"
  destroy_duration = "30s"

  depends_on = [aws_s3_bucket_public_access_block.origin, aws_s3_bucket_policy.default]
}

#---
# Log bucket
#---

resource "aws_s3_bucket" "cf_log" {
  count = local.create_cf_log_bucket ? 1 : 0

  bucket        = "${module.this.id}-log"
  force_destroy = var.log_bucket_force_destroy

  tags = merge(
    module.this.tags,
    {
      "Name" = "${module.this.id}-log"
    },
  )
}

resource "aws_s3_bucket_versioning" "cf_log" {
  count = local.create_cf_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.cf_log[0].id
  versioning_configuration {
    status = var.log_versioning_enabled ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cf_log" {
  count = local.create_cf_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.cf_log[0].bucket
  rule {
    bucket_key_enabled = false

    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cf_log" {
  count = local.create_cf_log_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.cf_log[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cf_log" {
  count = local.create_cf_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.cf_log[0].id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "cf_log" {
  count      = local.create_cf_log_bucket ? 1 : 0
  depends_on = [aws_s3_bucket_ownership_controls.cf_log]

  bucket = aws_s3_bucket.cf_log[0].id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_lifecycle_configuration" "cf_log" {
  count      = local.create_cf_log_bucket ? 1 : 0
  depends_on = [aws_s3_bucket_versioning.cf_log]

  bucket = aws_s3_bucket.cf_log[0].id

  rule {
    id = "expiration-${var.log_expiration_days}"

    filter {
      prefix = var.cloudfront_access_log_prefix
    }

    status = "Enabled"

    transition {
      days          = var.log_glacier_transition_days
      storage_class = "GLACIER"
    }
    expiration {
      days = var.log_expiration_days
    }

    dynamic "noncurrent_version_transition" {
      for_each = var.log_versioning_enabled ? ["true"] : []

      content {
        noncurrent_days = var.log_glacier_transition_days
        storage_class   = "GLACIER"
      }
    }
    dynamic "noncurrent_version_expiration" {
      for_each = var.log_versioning_enabled ? ["true"] : []

      content {
        noncurrent_days = var.log_expiration_days
      }
    }
  }
}

data "aws_s3_bucket" "origin" {
  count  = local.enabled && (var.origin_bucket != null) ? 1 : 0
  bucket = var.origin_bucket
}

data "aws_s3_bucket" "cf_logs" {
  count  = local.lookup_cf_log_bucket ? 1 : 0
  bucket = var.cloudfront_access_log_bucket_name
}

resource "aws_cloudfront_distribution" "default" {
  #bridgecrew:skip=BC_AWS_GENERAL_27:Skipping `Ensure CloudFront distribution has WAF enabled` because AWS WAF is indeed configurable and is managed via `var.web_acl_id`.
  #bridgecrew:skip=BC_AWS_NETWORKING_63:Skipping `Verify CloudFront Distribution Viewer Certificate is using TLS v1.2` because the minimum TLS version for the viewer certificate is indeed configurable and is managed via `var.minimum_protocol_version`.
  #bridgecrew:skip=BC_AWS_NETWORKING_65:Skipping `Ensure CloudFront distribution has a strict security headers policy attached` because the response header policy is indeed configurable and is managed via `var.response_headers_policy_id`.
  count = local.enabled ? 1 : 0

  enabled             = var.distribution_enabled
  is_ipv6_enabled     = var.ipv6_enabled
  comment             = coalesce(var.cf_description, module.this.id)
  default_root_object = var.default_root_object
  price_class         = var.price_class
  depends_on          = [aws_s3_bucket.origin]
  http_version        = var.http_version

  dynamic "logging_config" {
    for_each = var.cloudfront_access_logging_enabled ? ["true"] : []

    content {
      include_cookies = var.cloudfront_access_log_include_cookies
      bucket          = local.cf_log_bucket_domain
      prefix          = var.cloudfront_access_log_prefix
    }
  }

  aliases = var.acm_certificate_arn != "" ? concat(var.aliases, var.external_aliases) : []

  dynamic "origin_group" {
    for_each = var.origin_groups
    content {
      origin_id = "${module.this.id}-group[${origin_group.key}]"

      failover_criteria {
        status_codes = origin_group.value.failover_criteria
      }

      member {
        # the following enables the use case of specifying an origin group with the origin created by this module as the
        # primary origin in the group, prior to the creation of this module.
        origin_id = try(length(origin_group.value.primary_origin_id), 0) > 0 ? origin_group.value.primary_origin_id : local.origin_id
      }

      member {
        origin_id = origin_group.value.failover_origin_id
      }
    }
  }

  origin {
    domain_name              = local.bucket_domain_name
    origin_id                = local.origin_id
    origin_path              = var.origin_path
    origin_access_control_id = local.cf_access_control_id

    dynamic "s3_origin_config" {
      for_each = !var.website_enabled && local.continue_using_legacy_cloudfront_origin_access_identity ? [1] : []
      content {
        origin_access_identity = local.legacy_cf_access_identity.path
      }
    }

    dynamic "custom_origin_config" {
      for_each = var.website_enabled ? [1] : []
      content {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = var.origin_ssl_protocols
      }
    }
    dynamic "custom_header" {
      for_each = local.website_password_enabled ? concat([{ name = "referer", value = random_password.referer[0].result }], var.custom_origin_headers) : var.custom_origin_headers

      content {
        name  = custom_header.value["name"]
        value = custom_header.value["value"]
      }
    }

    dynamic "origin_shield" {
      for_each = var.origin_shield_enabled ? [1] : []
      content {
        enabled              = true
        origin_shield_region = local.origin_shield_region
      }
    }
  }

  dynamic "origin" {
    for_each = var.custom_origins
    content {
      domain_name = origin.value.domain_name
      origin_id   = origin.value.origin_id
      origin_path = lookup(origin.value, "origin_path", "")
      dynamic "custom_header" {
        for_each = lookup(origin.value, "custom_headers", [])
        content {
          name  = custom_header.value["name"]
          value = custom_header.value["value"]
        }
      }
      custom_origin_config {
        http_port                = lookup(origin.value.custom_origin_config, "http_port", 80)
        https_port               = lookup(origin.value.custom_origin_config, "https_port", 443)
        origin_protocol_policy   = lookup(origin.value.custom_origin_config, "origin_protocol_policy", "https-only")
        origin_ssl_protocols     = lookup(origin.value.custom_origin_config, "origin_ssl_protocols", ["TLSv1.2"])
        origin_keepalive_timeout = lookup(origin.value.custom_origin_config, "origin_keepalive_timeout", 60)
        origin_read_timeout      = lookup(origin.value.custom_origin_config, "origin_read_timeout", 60)
      }
    }
  }

  dynamic "origin" {
    for_each = var.s3_origins
    content {
      domain_name              = origin.value.domain_name
      origin_id                = origin.value.origin_id
      origin_path              = lookup(origin.value, "origin_path", "")
      origin_access_control_id = origin.value.origin_access_control_id != null ? origin.value.origin_access_control_id : local.cf_access_control_id

      dynamic "s3_origin_config" {
        for_each = origin.value.origin_access_control_id == null && local.continue_using_legacy_cloudfront_origin_access_identity ? [1] : []
        content {
          origin_access_identity = local.legacy_cf_access_identity.path
        }
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = local.use_default_acm_certificate ? null : "sni-only"
    minimum_protocol_version       = local.minimum_protocol_version
    cloudfront_default_certificate = local.use_default_acm_certificate
  }

  default_cache_behavior {
    allowed_methods            = var.allowed_methods
    cached_methods             = var.cached_methods
    cache_policy_id            = var.cache_policy_id
    origin_request_policy_id   = var.origin_request_policy_id
    target_origin_id           = local.origin_id
    compress                   = var.compress
    trusted_signers            = var.trusted_signers
    trusted_key_groups         = var.trusted_key_groups
    response_headers_policy_id = var.response_headers_policy_id
    viewer_protocol_policy     = var.viewer_protocol_policy
    default_ttl                = 0
    min_ttl                    = 0
    max_ttl                    = 0
    realtime_log_config_arn    = var.realtime_log_config_arn

    dynamic "lambda_function_association" {
      for_each = var.lambda_function_association
      content {
        event_type   = lambda_function_association.value.event_type
        include_body = lookup(lambda_function_association.value, "include_body", null)
        lambda_arn   = lambda_function_association.value.lambda_arn
      }
    }

    dynamic "function_association" {
      for_each = var.function_association
      content {
        event_type   = function_association.value.event_type
        function_arn = function_association.value.function_arn
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.ordered_cache

    content {
      path_pattern = ordered_cache_behavior.value.path_pattern

      allowed_methods    = ordered_cache_behavior.value.allowed_methods
      cached_methods     = ordered_cache_behavior.value.cached_methods
      target_origin_id   = ordered_cache_behavior.value.target_origin_id == "" ? local.origin_id : ordered_cache_behavior.value.target_origin_id
      compress           = ordered_cache_behavior.value.compress
      trusted_signers    = ordered_cache_behavior.value.trusted_signers
      trusted_key_groups = ordered_cache_behavior.value.trusted_key_groups

      cache_policy_id            = coalesce(ordered_cache_behavior.value.cache_policy_id, "658327ea-f89d-4fab-a63d-7e88639e58f6")          # AWS Managed-CachingOptimized policy
      origin_request_policy_id   = coalesce(ordered_cache_behavior.value.origin_request_policy_id, "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf") # AWS Managed-CORS-S3Origin policy
      response_headers_policy_id = ordered_cache_behavior.value.response_headers_policy_id

      viewer_protocol_policy = ordered_cache_behavior.value.viewer_protocol_policy
      default_ttl            = 0
      min_ttl                = 0
      max_ttl                = 0

      dynamic "lambda_function_association" {
        for_each = coalesce(ordered_cache_behavior.value.lambda_function_association, [])
        content {
          event_type   = lambda_function_association.value.event_type
          include_body = lookup(lambda_function_association.value, "include_body", null)
          lambda_arn   = lambda_function_association.value.lambda_arn
        }
      }

      dynamic "function_association" {
        for_each = coalesce(ordered_cache_behavior.value.function_association, [])
        content {
          event_type   = function_association.value.event_type
          function_arn = function_association.value.function_arn
        }
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  dynamic "custom_error_response" {
    for_each = var.custom_error_response
    content {
      error_caching_min_ttl = lookup(custom_error_response.value, "error_caching_min_ttl", null)
      error_code            = custom_error_response.value.error_code
      response_code         = lookup(custom_error_response.value, "response_code", null)
      response_page_path    = lookup(custom_error_response.value, "response_page_path", null)
    }
  }

  web_acl_id          = var.web_acl_id
  wait_for_deployment = var.wait_for_deployment

  tags = module.this.tags
}

module "dns" {
  source           = "cloudposse/route53-alias/aws"
  version          = "0.13.0"
  enabled          = (local.enabled && var.dns_alias_enabled)
  aliases          = var.aliases
  allow_overwrite  = var.dns_allow_overwrite
  parent_zone_id   = var.parent_zone_id
  parent_zone_name = var.parent_zone_name
  target_dns_name  = try(aws_cloudfront_distribution.default[0].domain_name, "")
  target_zone_id   = try(aws_cloudfront_distribution.default[0].hosted_zone_id, "")
  ipv6_enabled     = var.ipv6_enabled

  context = module.this.context
}
