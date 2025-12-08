resource "aws_vpc" "vpc" {
  cidr_block       = var.vpc_cidr
  instance_tenancy = "default"
  region = var.region

  tags = {
    Name = "project-vpc"
  }
}


data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "IGW"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Public-RT"
  }
}


resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id  
  }

  tags = {
    Name = "Private-RT"
  }
}




resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 3)  # 192.168.3.0/24, 192.168.4.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "Public-AZ${count.index + 1}"
  }
}

# --- PRIVATE SUBNETS ---
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)  # 192.168.1.0/24, 192.168.2.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "Private-AZ${count.index + 1}"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "NAT-EIP-AZ"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "NAT-GW-AZ"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# --- Security Groups ---
resource "aws_security_group" "jump_server" {
  name   = "Jump-Server-SG"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # For testing only — restrict in prod!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Jump-Server-SG"
  }
}

resource "aws_security_group" "web_servers" {
  name   = "Web-Servers-SG"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = [aws_security_group.jump_server.id]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Web-Servers-SG"
  }
}



resource "aws_iam_role" "web_server_role" {
  name = "web-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })


  #Allow S3 read-only (for your S3 access need)
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]

  tags = {
    Name = "Web-Server-Role"
  }
}

resource "aws_iam_role_policy_attachment" "web_server_ssm" {
  role       = aws_iam_role.web_server_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web_server_profile" {
  name = "web-server-profile"
  role = aws_iam_role.web_server_role.name
}

resource "tls_private_key" "jump_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "jump_key" {
  key_name   = "jump-server-key"
  public_key = tls_private_key.jump_key.public_key_openssh

  tags = {
    Name = "Jump-Server-Key"
  }
}

# Save private key to file (~/.ssh/jump-server-key.pem)
resource "local_file" "private_key" {
  filename = "${pathexpand("~/.ssh/jump-server-key.pem")}"
  content  = tls_private_key.jump_key.private_key_pem

  file_permission = "0600"
}


# ========== Jump Servers (Public Subnets) ==========
resource "aws_instance" "jump_server" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jump_server.id]
  key_name               = aws_key_pair.jump_key.key_name 

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Jump Server AZ</h1>" > /var/www/html/index.html
              EOF

  tags = {
    Name = "Jump-Server-AZ"
  }

  
  provisioner "remote-exec" {
    inline = ["echo 'Instance ready!'"]

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = tls_private_key.jump_key.private_key_pem
      host        = self.public_ip
    }
  }
}



data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ALB-SG" }
}


resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false  # Public
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [
    aws_subnet.public[0].id,
    aws_subnet.public[1].id
  ]

  tags = {
    Name = "Web-ALB"
  }
}

# Target Group (يربط الـALB بالـInstances)
resource "aws_lb_target_group" "web_tg" {
  name        = "web-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "instance"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "Web-TG" }
}

# Listener (يحول الـTraffic من الـALB للـTarget Group)
resource "aws_lb_listener" "web_http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# ========== Web Servers (Private Subnets) ==========
resource "aws_launch_template" "web_server" {
  name_prefix   = "web-server-lt"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.jump_key.key_name  

  user_data = base64encode(<<-EOT
  #cloud-config
  package_update: true
  package_upgrade: true
  packages:
    - httpd

  runcmd:
    - systemctl start httpd
    - systemctl enable httpd
    - echo "<h1>Web Server $(hostname)</h1>" > /var/www/html/index.html
  EOT
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.web_server_profile.name  # ← هنعمله في الخطوة 4
  }

  network_interfaces {
    associate_public_ip_address = false  # ← مهم! web servers في private subnet
    security_groups             = [aws_security_group.web_servers.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Web-Server"
    }
  }
}

resource "aws_autoscaling_group" "web_asg" {
  name                 = "web-asg"
  max_size             = 5
  min_size             = 2
  desired_capacity     = 2
  launch_template {
    id      = aws_launch_template.web_server.id
    version = "$Latest"
  }

  vpc_zone_identifier = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id
  ]

  target_group_arns = [aws_lb_target_group.web_tg.arn]

  tag {
    key                 = "Name"
    value               = "Web-Server"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "Production"
    propagate_at_launch = true
  }
}

output "alb_url" {
  value = "http://${aws_lb.web_alb.dns_name}"
}

