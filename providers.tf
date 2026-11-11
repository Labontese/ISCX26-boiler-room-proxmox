terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.112"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"

  # Proxmox använder ett självsignerat certifikat. Det här stänger av
  # kontrollen av certifikatet, vilket är en medveten kvarstående brist.
  insecure = true

  # Uppladdning av cloud-init-filer sker över SSH, inte över API:et.
  ssh {
    # Windows ssh-agent nås via en named pipe, som providern inte kan
    # använda. Därför läses en egen maskinnyckel från disk.
    agent       = false
    username    = "root"
    private_key = file(var.ssh_private_key_path)

    node {
      name    = "pve"
      address = var.proxmox_node_address
    }
  }
}
