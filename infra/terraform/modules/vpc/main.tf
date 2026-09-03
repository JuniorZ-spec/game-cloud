# VPC : le réseau privé isolé qui contiendra tout le cluster.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name}-vpc"
  }
}

# Porte d'entrée/sortie vers Internet, attachée au VPC. Utilisée par les
# sous-réseaux PUBLICS (bastion, ALB) uniquement.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

# --- Sous-réseaux publics (1 par AZ) : bastion, ALB ---
resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.name}-public-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Indique à l'AWS Load Balancer Controller (phase 5) que ce subnet peut
    # accueillir un Application Load Balancer externe.
    "kubernetes.io/role/elb" = "1"
  }
}

# --- Sous-réseaux privés (1 par AZ) : nœuds EKS ---
resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.name}-private-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Pour un éventuel ALB/NLB interne plus tard.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# IP publique fixe pour la NAT Gateway.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-nat-eip"
  }
}

# 1 SEULE NAT Gateway (pas 1 par AZ) : économie assumée pour ce projet démo.
# Placée dans le premier sous-réseau public. Permet aux nœuds EKS (privés) de
# sortir vers Internet (tirer des images Docker, appeler des APIs AWS) sans
# être eux-mêmes joignables depuis l'extérieur.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# --- Table de routage publique : tout le trafic sortant passe par l'IGW ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Table de routage privée : tout le trafic sortant passe par la NAT ---
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
