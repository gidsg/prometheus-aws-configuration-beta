/**
* ECS service that runs alertmanager
*
* This service consists of two containers.  The first, `s3-config-grabber`, fetches alertmanager configuration from our config S3 bucket, and stores it on a shared volume.  Then `alertmanager` runs and consumes that config.
*
* There is a known race condition between the two tasks - there is no guarantee that `s3-config-grabber` will grab the config before `alertmanager` starts.
*
*/

## Variables
variable "mesh_urls" {
  type = "list"

  default = ["mesh-1", "mesh-2", "mesh-3"]
}

variable "prometheis_total" {
  type        = "string"
  description = "Desired number of prometheus servers.  Maximum 3."
  default     = "3"
}

## Locals
locals {
  alertmanager_public_fqdns = "${data.terraform_remote_state.app_ecs_albs.alerts_public_record_fqdns}"
  alertmanager_mesh         = "${formatlist("--cluster.peer=%s.${local.private_subdomain}:9094", var.mesh_urls)}"

  #We have to define alert manager args counts on at template definition level since we have no local instance
  private_subdomain = "${data.terraform_remote_state.infra_networking.private_subdomain}"
  flattened_args    = "${local.alertmanager_mesh}"
}

### container, task, service definitions

data "template_file" "alertmanager_container_defn" {
  count    = "${length(local.alertmanager_public_fqdns)}"
  template = "${file("${path.module}/task-definitions/alertmanager-server.json")}"

  vars {
    alertmanager_config_base64 = "${
      base64encode(var.dev_environment == "true"
                   ? data.template_file.alertmanager_dev_config_file.rendered
                   : data.template_file.alertmanager_config_file.rendered)
    }"

    alertmanager_url = "--web.external-url=https://${local.alertmanager_public_fqdns[count.index]}"
    commands         = "${join(" ", local.flattened_args)}"

    log_group = "${aws_cloudwatch_log_group.task_logs.name}"
    region    = "${var.aws_region}"
  }
}

resource "aws_ecs_task_definition" "alertmanager_server" {
  count                 = "${length(local.alertmanager_public_fqdns)}"
  family                = "${var.stack_name}-alertmanager-server-${count.index + 1}"
  container_definitions = "${element(data.template_file.alertmanager_container_defn.*.rendered, count.index)}"
  network_mode          = "host"
}

resource "aws_ecs_service" "alertmanager_server" {
  count = "${length(data.terraform_remote_state.app_ecs_instances.available_azs)}"

  name            = "${var.stack_name}-alertmanager-server-${count.index + 1}"
  cluster         = "${var.stack_name}-ecs-monitoring"
  task_definition = "${element(aws_ecs_task_definition.alertmanager_server.*.arn, count.index)}"
  desired_count   = 1

  load_balancer {
    target_group_arn = "${element(data.terraform_remote_state.app_ecs_albs.alertmanager_target_group_arns, count.index)}"
    container_name   = "alertmanager"
    container_port   = 9093
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.availability-zone == ${data.terraform_remote_state.app_ecs_instances.available_azs[count.index]}"
  }

  depends_on = ["aws_ecs_task_definition.alertmanager_server"]
}

#### alertmanager

data "pass_password" "observe_pagerduty_key" {
  path = "pagerduty/integration-keys/production"
}

data "pass_password" "dgu_pagerduty_key" {
  path = "pagerduty/integration-keys/dgu"
}

data "pass_password" "verify_p1_pagerduty_key" {
  path = "pagerduty/integration-keys/verify-p1"
}

data "pass_password" "verify_p2_pagerduty_key" {
  path = "pagerduty/integration-keys/verify-p2"
}

data "pass_password" "slack_api_url" {
  path = "slack-api-url"
}

data "pass_password" "registers_zendesk" {
  path = "receivers/registers/zendesk"
}

data "pass_password" "observe_zendesk" {
  path = "receivers/observe/zendesk"
}

data "pass_password" "verify_joint_cronitor" {
  path = "cronitor/verify-joint-url"
}

data "pass_password" "verify_staging_cronitor" {
  path = "cronitor/verify-staging-url"
}

data "pass_password" "verify_integration_cronitor" {
  path = "cronitor/verify-integration-url"
}

data "pass_password" "verify_prod_cronitor" {
  path = "cronitor/verify-prod-url"
}

data "template_file" "alertmanager_config_file" {
  template = "${file("${path.module}/templates/alertmanager.tpl")}"

  vars {
    observe_pagerduty_key   = "${data.pass_password.observe_pagerduty_key.password}"
    dgu_pagerduty_key       = "${data.pass_password.dgu_pagerduty_key.password}"
    verify_p1_pagerduty_key = "${data.pass_password.verify_p1_pagerduty_key.password}"
    slack_api_url           = "${data.pass_password.slack_api_url.password}"
    registers_zendesk       = "${data.pass_password.registers_zendesk.password}"
    smtp_from               = "alerts@${data.terraform_remote_state.infra_networking.public_subdomain}"

    # Port as requested by https://docs.aws.amazon.com/ses/latest/DeveloperGuide/smtp-connect.html
    smtp_smarthost              = "email-smtp.${var.aws_region}.amazonaws.com:587"
    smtp_username               = "${aws_iam_access_key.smtp.id}"
    smtp_password               = "${aws_iam_access_key.smtp.ses_smtp_password}"
    ticket_recipient_email      = "${data.pass_password.observe_zendesk.password}"
    observe_cronitor            = "${var.observe_cronitor}"
    verify_joint_cronitor       = "${data.pass_password.verify_joint_cronitor.password}"
    verify_staging_cronitor     = "${data.pass_password.verify_staging_cronitor.password}"
    verify_integration_cronitor = "${data.pass_password.verify_integration_cronitor.password}"
    verify_prod_cronitor        = "${data.pass_password.verify_prod_cronitor.password}"
  }
}

data "template_file" "alertmanager_dev_config_file" {
  template = "${file("${path.module}/templates/alertmanager-dev.tpl")}"

  # For dev stacks, as we have not requested "AWS SES production access", by default
  # emails will not be sent unless you verify the recipient's email address
  # (e.g. your personal email for testing).
  # https://docs.aws.amazon.com/ses/latest/DeveloperGuide/verify-email-addresses-procedure.html
  vars {
    smtp_from = "alerts@${data.terraform_remote_state.infra_networking.public_subdomain}"

    # Port as requested by https://docs.aws.amazon.com/ses/latest/DeveloperGuide/smtp-connect.html
    smtp_smarthost             = "email-smtp.${var.aws_region}.amazonaws.com:587"
    smtp_username              = "${aws_iam_access_key.smtp.id}"
    smtp_password              = "${aws_iam_access_key.smtp.ses_smtp_password}"
    dev_ticket_recipient_email = "${var.dev_ticket_recipient_email}"
    observe_cronitor           = "${var.observe_cronitor}"
  }
}

## AWS SES

resource "aws_ses_domain_identity" "main" {
  domain = "${data.terraform_remote_state.infra_networking.public_subdomain}"
}

resource "aws_route53_record" "txt_amazonses_verification_record" {
  zone_id = "${data.terraform_remote_state.infra_networking.public_zone_id}"
  name    = "_amazonses.${data.terraform_remote_state.infra_networking.public_subdomain}"
  type    = "TXT"
  ttl     = "600"
  records = ["${aws_ses_domain_identity.main.verification_token}"]
}

resource "aws_ses_domain_dkim" "main" {
  domain = "${aws_ses_domain_identity.main.domain}"
}

resource "aws_route53_record" "dkim_amazonses_verification_record" {
  count   = 3
  zone_id = "${data.terraform_remote_state.infra_networking.public_zone_id}"
  name    = "${element(aws_ses_domain_dkim.main.dkim_tokens, count.index)}._domainkey.${data.terraform_remote_state.infra_networking.public_subdomain}"
  type    = "CNAME"
  ttl     = "600"
  records = ["${element(aws_ses_domain_dkim.main.dkim_tokens, count.index)}.dkim.amazonses.com"]
}

resource "aws_ses_domain_mail_from" "alerts" {
  domain           = "${aws_ses_domain_identity.main.domain}"
  mail_from_domain = "mail.${aws_ses_domain_identity.main.domain}"
}

resource "aws_route53_record" "alerts_ses_domain_mail_from_mx" {
  zone_id = "${data.terraform_remote_state.infra_networking.public_zone_id}"
  name    = "${aws_ses_domain_mail_from.alerts.mail_from_domain}"
  type    = "MX"
  ttl     = "600"
  records = ["10 feedback-smtp.${var.aws_region}.amazonses.com"]
}

resource "aws_route53_record" "alerts_ses_domain_mail_from_txt" {
  zone_id = "${data.terraform_remote_state.infra_networking.public_zone_id}"
  name    = "${aws_ses_domain_mail_from.alerts.mail_from_domain}"
  type    = "TXT"
  ttl     = "600"
  records = ["v=spf1 include:amazonses.com -all"]
}

# IAM for SMTP

resource "aws_iam_user" "smtp" {
  name = "${var.stack_name}.smtp"
  path = "/system/"
}

resource "aws_iam_access_key" "smtp" {
  user = "${aws_iam_user.smtp.name}"
}

resource "aws_iam_user_policy" "smtp_ro" {
  name = "${var.stack_name}.smtp"
  user = "${aws_iam_user.smtp.name}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ses:SendRawEmail",
      "Resource": "*"
    }
  ]
}
EOF
}
