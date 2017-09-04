resource "aws_alb" "alb" {
  name = "${var.env_name}-${var.app_name}"
  internal = "${var.internal_alb}"
  subnets = ["${data.terraform_remote_state.infrastructure_state.public_subnets}"]
  security_groups = ["${aws_security_group.alb-application.id}"]

  enable_deletion_protection = "${var.delete_protection}"

  access_logs {
    bucket = "${aws_s3_bucket.alb_logs.bucket}"
    prefix = "/"
  }

  tags {
    ManagedBy = "Terraform"
    Name = "${var.env_name}-${var.app_name}"
    Env = "${var.env_name}"
    App = "${var.app_name}"
  }

  provisioner "local-exec" {
    command = "sleep 10"
  }
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.env_name}-${var.app_name}-alb-logs"
  acl    = "private"

  // @todo add lifecycle rules to archive stuff

  tags {
    ManagedBy = "Terraform"
    Name = "${var.env_name}-${var.app_name}-alb-logs"
    Env = "${var.env_name}"
    App = "${var.app_name}"
  }
}

resource "aws_alb_target_group" "application" {
  name = "${var.env_name}-${var.app_name}"
  port = 80
  protocol = "HTTP"
  vpc_id = "${data.terraform_remote_state.infrastructure_state.vpc_id}"
  tags {
    ManagedBy = "Terraform"
    Name = "${var.env_name}-${var.app_name}"
    Env = "${var.env_name}"
    App = "${var.app_name}"
  }
  provisioner "local-exec" {
    command = "sleep 10"
  }
}

resource "aws_alb_listener" "application" {
  load_balancer_arn = "${aws_alb.alb.arn}"
  port = "80"
  protocol = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.application.arn}"
    type = "forward"
  }
}

data "template_file" "service_task" {
  template = "${file("${path.module}/service.json")}"

  vars = {
    env_name = "${var.env_name}"
    region = "${var.region}"
    app_name = "${var.app_name}"
    image_name = "${var.image_name}"
    docker_tag = "${var.docker_tag}"
    max_memory = "${var.max_memory}"
    reserved_memory = "${var.reserved_memory}"
  }
}

resource "aws_ecs_task_definition" "application" {
  family = "${var.env_name}-${var.app_name}"
  container_definitions = "${data.template_file.service_task.rendered}"
}

// Check this out if you want HTTPS - https://www.terraform.io/docs/providers/aws/r/alb_listener.html
// Howver, this requires you have an aws managed certificate ARN for a domain you own.

resource "aws_ecs_service" "application" {
  name = "${var.env_name}-${var.app_name}"
  cluster = "${data.terraform_remote_state.infrastructure_state.cluster_id}"
  task_definition = "${aws_ecs_task_definition.application.family}:${aws_ecs_task_definition.application.revision}"
  desired_count = "${var.service_desired}"
  iam_role = "${var.ecs_iam_role}"

  load_balancer {
    target_group_arn = "${aws_alb_target_group.application.arn}"
    container_name = "${var.env_name}-${var.app_name}"
    container_port = 80
  }

  placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  depends_on = [
    "aws_ecs_task_definition.application",
    "aws_alb_target_group.application",
    "aws_alb.alb",
    "aws_alb_listener.application"
  ]
}

resource "aws_security_group" "alb-application" {
  name = "${var.env_name}-${var.app_name}-alb-sg"
  description = "Controls all access to the ALB"
  vpc_id = "${data.terraform_remote_state.infrastructure_state.vpc_id}"

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags {
    ManagedBy = "Terraform"
    Name = "${var.env_name}-${var.app_name}-alb-sg"
    Env = "${var.env_name}"
    App = "${var.app_name}"
  }
}

resource "aws_appautoscaling_target" "application" {
  service_namespace = "ecs"
  resource_id = "service/${data.terraform_remote_state.infrastructure_state.ecs_cluster_name}/${aws_ecs_service.application.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = "${var.ecs_as_iam_role}"
  min_capacity = "${var.service_min}"
  max_capacity = "${var.service_max}"

  depends_on = ["aws_ecs_service.application"]
}

resource "aws_appautoscaling_policy" "scale-up" {
  name = "${var.env_name}-${var.app_name}-scale-up"
  service_namespace = "ecs"
  resource_id = "service/${data.terraform_remote_state.infrastructure_state.ecs_cluster_name}/${aws_ecs_service.application.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  adjustment_type = "ChangeInCapacity"
  cooldown = 60
  metric_aggregation_type = "Maximum"

  step_adjustment {
    metric_interval_lower_bound = 0
    scaling_adjustment = 1
  }

  depends_on = ["aws_appautoscaling_target.application"]
}

resource "aws_cloudwatch_metric_alarm" "application-cpu-scale-up" {
  alarm_name = "${var.env_name}-${var.app_name}-cpu-up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "1"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "300"
  statistic = "Average"
  threshold = "${var.cpu_scale_up}"
  alarm_description = "Monitors ECS CPU Utilization"
  alarm_actions = ["${aws_appautoscaling_policy.scale-up.arn}"]

  dimensions {
    ClusterName = "${data.terraform_remote_state.infrastructure_state.ecs_cluster_name}"
    ServiceName = "${aws_ecs_service.application.name}"
  }

  depends_on = ["aws_appautoscaling_policy.scale-up"]
}

resource "aws_appautoscaling_policy" "scale-down" {
  name = "${var.env_name}-${var.app_name}-scale-down"
  service_namespace = "ecs"
  resource_id = "service/${data.terraform_remote_state.infrastructure_state.ecs_cluster_name}/${aws_ecs_service.application.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  adjustment_type = "ChangeInCapacity"
  cooldown = 60
  metric_aggregation_type = "Maximum"

  step_adjustment {
    metric_interval_lower_bound = 0
    scaling_adjustment = -1
  }

  depends_on = ["aws_appautoscaling_target.application"]
}

resource "aws_cloudwatch_metric_alarm" "application-scale-down" {
  alarm_name = "${var.env_name}-${var.app_name}-cpu-down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "1"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "300"
  statistic = "Average"
  threshold = "${var.cpu_scale_down}"
  alarm_description = "Monitors ECS CPU Utilization"
  alarm_actions = ["${aws_appautoscaling_policy.scale-down.arn}"]

  dimensions {
    ClusterName = "${data.terraform_remote_state.infrastructure_state.ecs_cluster_name}"
    ServiceName = "${aws_ecs_service.application.name}"
  }

  depends_on = [
    "aws_appautoscaling_policy.scale-down",
    "aws_cloudwatch_metric_alarm.application-cpu-scale-up"
  ]
}
