provider "aws" {
}

resource "aws_cloudfront_distribution" "distribution" {
  origin {
    domain_name = "${aws_s3_bucket.bucket.bucket_regional_domain_name}"
    origin_id   = "s3"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.OAI.cloudfront_access_identity_path}"
    }
  }
  origin {
    domain_name = replace(aws_api_gateway_deployment.deployment.invoke_url, "/^https?://([^/]*).*/", "$1")
    origin_id   = "apigw"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "apigw"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "domain" {
  value = "${aws_cloudfront_distribution.distribution.domain_name}"
}

# -------------- Origin resources --------------

# s3 origin
resource "aws_s3_bucket" "bucket" {
  force_destroy = true
}

resource "aws_s3_bucket_object" "object" {
  bucket = "${aws_s3_bucket.bucket.bucket}"
  key    = "index.html"

  content      = <<EOF
<script>
const call = (path) => async () => {
	[...document.querySelectorAll("button")].forEach((b) => b.disabled = true);
	const result = await (await fetch(path)).text();
	document.querySelector("#result").innerText = result;
	[...document.querySelectorAll("button")].forEach((b) => b.disabled = false);
}
const call_api = call("/api/");
const call_api_path = call("/api/path");
</script>
<button onclick="call_api()">call /api/</button>
<button onclick="call_api_path()">call /api/path</button>
<p id="result"></p>
EOF
  content_type = "text/html"
}

resource "aws_s3_bucket_policy" "OAI_policy" {
  bucket = "${aws_s3_bucket.bucket.id}"
  policy = "${data.aws_iam_policy_document.s3_policy.json}"
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.OAI.iam_arn}"]
    }
  }
}

resource "aws_cloudfront_origin_access_identity" "OAI" {
}

# signer lambda + api gw

resource "random_id" "id" {
  byte_length = 8
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/lambda.zip"
  source {
    content  = <<EOF
module.exports.handler = async (event, context, callback) => {
	const response = {
		statusCode: 200,
		body: "Hello world from API! event.path = " + event.path,
	};
	callback(null, response);
};
EOF
    filename = "main.js"
  }
}

resource "aws_lambda_function" "lambda" {
  function_name = "${random_id.id.hex}-function"

  filename         = "${data.archive_file.lambda_zip.output_path}"
  source_code_hash = "${data.archive_file.lambda_zip.output_base64sha256}"

  handler = "main.handler"
  runtime = "nodejs10.x"
  role    = "${aws_iam_role.lambda_exec.arn}"
}

data "aws_iam_policy_document" "lambda_exec_role_policy" {
  statement {
    sid = "1"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_exec_role" {
  role   = "${aws_iam_role.lambda_exec.id}"
  policy = "${data.aws_iam_policy_document.lambda_exec_role_policy.json}"
}

resource "aws_iam_role" "lambda_exec" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

# api gw

resource "aws_api_gateway_rest_api" "rest_api" {
  name = "${random_id.id.hex}-rest-api"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = "${aws_api_gateway_rest_api.rest_api.id}"
  parent_id   = "${aws_api_gateway_rest_api.rest_api.root_resource_id}"
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = "${aws_api_gateway_rest_api.rest_api.id}"
  resource_id   = "${aws_api_gateway_resource.proxy.id}"
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = "${aws_api_gateway_rest_api.rest_api.id}"
  resource_id = "${aws_api_gateway_method.proxy.resource_id}"
  http_method = "${aws_api_gateway_method.proxy.http_method}"

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "${aws_lambda_function.lambda.invoke_arn}"
}

resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = "${aws_api_gateway_rest_api.rest_api.id}"
  resource_id   = "${aws_api_gateway_rest_api.rest_api.root_resource_id}"
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = "${aws_api_gateway_rest_api.rest_api.id}"
  resource_id = "${aws_api_gateway_method.proxy_root.resource_id}"
  http_method = "${aws_api_gateway_method.proxy_root.http_method}"

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "${aws_lambda_function.lambda.invoke_arn}"
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    "aws_api_gateway_integration.lambda",
    "aws_api_gateway_integration.lambda_root",
  ]

  rest_api_id = "${aws_api_gateway_rest_api.rest_api.id}"
  stage_name  = "api"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.lambda.arn}"
  principal     = "apigateway.amazonaws.com"

  # The /*/* portion grants access from any method on any resource
  # within the API Gateway "REST API".
  source_arn = "${aws_api_gateway_deployment.deployment.execution_arn}/*/*"
}
