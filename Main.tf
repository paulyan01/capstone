provider "aws" {
  region = "us-east-1"  # Set your desired region
}

resource "aws_iam_role" "s3_role" {
  name = "S3Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "s3_policy" {
  name        = "S3Policy"
  description = "Allow S3 access"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = ["s3:GetObject", "s3:PutObject"],
        Effect = "Allow",
        Resource = "arn:aws:s3:::casptone2023/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_policy_attach" {
  policy_arn = aws_iam_policy.s3_policy.arn
  role       = aws_iam_role.s3_role.name
}

resource "aws_iam_instance_profile" "s3_instance_profile" {
  name = "S3InstanceProfile"
  roles = [aws_iam_role.s3_role.name]
}

resource "aws_iam_policy" "ssm_policy" {
  name        = "SSMPolicy"
  description = "Allow SSM access"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = ["ssm:StartSession"],
        Effect = "Allow",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  policy_arn = aws_iam_policy.ssm_policy.arn
  role       = aws_iam_role.s3_role.name
}

resource "aws_launch_configuration" "web_server_lc" {
  name_prefix   = "web-server-lc-"
  image_id      = "<ami-id>"
  instance_type = "t2.micro"

  security_groups = ["<security-group-id>"]
  iam_instance_profile = aws_iam_instance_profile.s3_instance_profile.name

  user_data = <<-EOF
              #!/bin/bash
              aws s3 cp s3://<your-bucket-name>/index.html /var/www/html/
              systemctl start httpd
              EOF
}

resource "aws_autoscaling_group" "web_server_asg" {
  name                 = "web-server-asg"
  launch_configuration = aws_launch_configuration.web_server_lc.name
  min_size             = 1
  max_size             = 1
  desired_capacity     = 1
  vpc_zone_identifier = ["<private-subnet-id>"]

  health_check_type        = "EC2"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "web-server"
    propagate_at_launch = true
  }
}

resource "aws_lb_target_group" "web_server_tg" {
  name     = "web-server-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "<your-vpc-id>"

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    path                = "/"
    matcher             = "200-299"
  }
}

resource "aws_lb_listener" "web_server_listener" {
  load_balancer_arn = "<your-lb-arn>"
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.web_server_tg.arn
    type             = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Hello, world!"
      status_code  = "200"
    }
  }
}

resource "aws_route53_record" "alias_record" {
  zone_id = "<your-hosted-zone-id>"
  name    = "example.com"
  type    = "A"

  alias {
    name                   = aws_lb.web_server_lb.dns_name
    zone_id                = aws_lb.web_server_lb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_cloudwatch_metric_alarm" "asg_alarm" {
  alarm_name          = "ASGStateChangeAlarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "1"
  metric_name        = "GroupInServiceInstances"
  namespace          = "AWS/AutoScaling"
  period             = "60"
  statistic          = "SampleCount"
  threshold          = "1"
  alarm_description = "This metric checks if the ASG state changes."
  alarm_actions = []

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_server_asg.name
  }
}

resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "ScaleOutPolicy"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web_server_asg.name

  policy_type = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "scale_out_alarm" {
  alarm_name          = "ScaleOutAlarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "1"
  metric_name        = "CPUUtilization"
  namespace          = "AWS/EC2"
  period             = "60"
  statistic          = "Average"
  threshold          = "80"
  alarm_description = "This metric triggers scale out when CPU utilization is high."
  alarm_actions = [aws_autoscaling_policy.scale_out_policy.arn]
}
