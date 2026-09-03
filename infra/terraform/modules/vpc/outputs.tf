output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "IP publique par laquelle tout le trafic sortant des nœuds privés apparaît sur Internet."
  value       = aws_eip.nat.public_ip
}
