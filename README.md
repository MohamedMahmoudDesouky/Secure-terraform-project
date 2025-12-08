🛠️ Key Components & Architecture Highlights
✅ Network Design (VPC & Subnets)

A single VPC spanned across two Availability Zones (AZ1 & AZ2) for fault tolerance.
Public Subnets: Host ingress/access resources (Jump Server, NAT Gateway).
Private Subnets: Host the application workload (Web Servers), fully isolated from direct internet access.
✅ Secure Access Layer

Jump Server (Bastion Host) in Public Subnet (AZ1):
Acts as the only entry point for SSH management.
Protected by a strict security group (allowing SSH only from trusted IPs).
NAT Gateway in Public Subnet (AZ2):
Enables outbound internet access for private instances (e.g., for updates or S3 access), while preventing inbound connections.
✅ Application Layer (Highly Available & Scalable)

Application Load Balancer (ALB):
Distributes HTTP/HTTPS traffic across web servers.
Health checks ensure traffic routes only to healthy instances.
Auto Scaling Group (ASG) in Private Subnets (AZ1 & AZ2):
Hosts stateless web servers (e.g., Apache/Nginx + app logic).
Scales out/in automatically based on CPU/memory metrics or custom CloudWatch alarms.
Ensures zero single point of failure.
✅ Security & IAM Integration

Security Groups (SGs) enforce least-privilege access:
ALB → Web Servers (HTTP/HTTPS only).
Jump Server → Web Servers (SSH only, for admin/debugging).
IAM Role + S3 Bucket Policy:
Web servers assume an IAM role granting read-only access to a specific S3 bucket (e.g., for static assets, configs, or logs), eliminating hardcoded AWS credentials.
✅ Routing & Resilience

Public Route Table: Routes 0.0.0.0/0 → Internet Gateway (IGW).
Private Route Table: Routes 0.0.0.0/0 → NAT Gateway — enabling secure outbound traffic.
Multi-AZ deployment provides high availability and disaster recovery readiness.
