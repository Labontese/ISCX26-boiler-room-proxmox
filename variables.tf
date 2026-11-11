variable "proxmox_endpoint" {
  description = "Proxmox API-adress, till exempel https://10.10.0.3:8006"
  type        = string
}

variable "proxmox_node_address" {
  description = "IP-adress till Proxmox-noden som providern ansluter till via SSH"
  type        = string
  default     = "10.10.0.3"
}

variable "proxmox_token_id" {
  description = "API-token på formatet användare@realm!tokennamn"
  type        = string
}

variable "proxmox_token_secret" {
  description = "Hemligheten som hör till API-token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Publik nyckel som läggs in på Linuxservern"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Sökväg till maskinnyckeln som providern använder mot Proxmox"
  type        = string
}

variable "brygga_drift" {
  description = "Bryggan till driftnätet"
  type        = string
  default     = "vmbr1"
}

variable "vlan_drift" {
  description = "VLAN-nummer på driftnätet"
  type        = number
  default     = 70
}

variable "brygga_produktion" {
  description = "Den isolerade OVS-bryggan för produktionsnätet 192.168.50.0/24"
  type        = string
  default     = "ovsbr-sstab"
}
