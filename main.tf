# ============================================================================
# Skämt & Sido Transport AB (Boiler Room), servrarna på Proxmox.
#
#   331  SRV-01-DC    Windows Server 2025   AD DS, DNS, DHCP   192.168.50.10
#   332  SRV-02-LNX   Ubuntu Server 26.04   Samba, backup      192.168.50.50
#
# Båda har två nätverkskort:
#   Produktion  den isolerade OVS-bryggan ovsbr-sstab (192.168.50.0/24)
#   Drift       VLAN 70, DHCP, för SSH/RDP från adminklienten och uppdateringar
#
# Bryggan skapas för hand på Proxmox, se driftdokumentationen:
#   ovs-vsctl --may-exist add-br ovsbr-sstab
# ============================================================================

# ------------------------------------------------------------ cloud-init ----
# ignore_changes på source_raw: cloud-init läser filerna bara vid första
# uppstart. Utan raden ersätts hela maskinen när en kommentar ändras.
resource "proxmox_virtual_environment_file" "networkdata" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve"

  source_raw {
    data      = file("${path.module}/cloud-init/linux-networkdata.yaml")
    file_name = "sstab-srv02-networkdata.yaml"
  }

  lifecycle {
    ignore_changes = [source_raw]
  }
}

resource "proxmox_virtual_environment_file" "userdata" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve"

  source_raw {
    data = templatefile("${path.module}/cloud-init/linux-userdata.yaml.tftpl", {
      ssh_public_key = var.ssh_public_key
    })
    file_name = "sstab-srv02-userdata.yaml"
  }

  lifecycle {
    ignore_changes = [source_raw]
  }
}

# ------------------------------------------------------------- SRV-02-LNX ---
resource "proxmox_virtual_environment_vm" "srv02" {
  name        = "SRV-02-LNX"
  description = "Skämt & Sido Transport: filserver och backupmål. Skapad med Terraform."
  node_name   = "pve"
  vm_id       = 332
  tags        = ["sstab"]

  clone {
    vm_id = 9001 # ubuntu-2604-cloudinit
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  # Systemdisken.
  disk {
    datastore_id = "zfs-pve"
    interface    = "scsi0"
    size         = 20
    discard      = "on"
  }

  # Backupdisken, /srv/backup. Egen disk så att en full backupdisk inte
  # fyller systemdisken, och så att den kan flyttas till en annan maskin.
  disk {
    datastore_id = "zfs-pve"
    interface    = "scsi1"
    size         = 100
    discard      = "on"
  }

  # Produktion, blir ens18.
  network_device {
    bridge      = var.brygga_produktion
    mac_address = "BC:24:11:50:00:50"
  }

  # Drift, blir ens19.
  network_device {
    bridge      = var.brygga_drift
    vlan_id     = var.vlan_drift
    mac_address = "BC:24:11:00:D3:32"
  }

  initialization {
    ip_config {
      ipv4 { address = "dhcp" }
    }
    ip_config {
      ipv4 { address = "dhcp" }
    }
    user_data_file_id    = proxmox_virtual_environment_file.userdata.id
    network_data_file_id = proxmox_virtual_environment_file.networkdata.id
  }

  agent {
    enabled = true
    timeout = "3m"
  }

  # iptag.service på Proxmox lägger maskinens IP-adress som tagg.
  lifecycle {
    ignore_changes = [tags]
  }
}

# -------------------------------------------------------------- SRV-01-DC ---
# Klonas från mallen 9010 (Server 2025, cloudbase-init, OpenSSH med nyckel,
# virtio-drivrutiner, gästagent). Datornamn, fasta adresser och AD DS sätts
# efter första start, se driftdokumentationen.
resource "proxmox_virtual_environment_vm" "srv01" {
  name        = "SRV-01-DC"
  description = "Skämt & Sido Transport: domänkontrollant sost.local. Skapad med Terraform."
  node_name   = "pve"
  vm_id       = 331
  tags        = ["sstab"]

  clone {
    vm_id        = 9010 # winserver2025-tpl
    full         = true
    datastore_id = "zfs-pve"
  }

  bios    = "ovmf"
  machine = "q35"

  operating_system {
    type = "win11"
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 8192
  }

  initialization {
    datastore_id = "zfs-pve"
    interface    = "ide2"
    ip_config {
      ipv4 { address = "dhcp" }
    }
  }

  # Drift först, så att kortet som får DHCP vid första start är det som
  # nås från adminklienten.
  network_device {
    bridge      = var.brygga_drift
    vlan_id     = var.vlan_drift
    model       = "e1000e"
    mac_address = "BC:24:11:00:D3:31"
  }

  # Produktion.
  network_device {
    bridge      = var.brygga_produktion
    model       = "e1000e"
    mac_address = "BC:24:11:50:00:10"
  }

  agent {
    enabled = true
    timeout = "3m"
  }

  lifecycle {
    ignore_changes = [machine, tags]
  }
}

output "maskiner" {
  value = {
    srv01 = { vmid = 331, namn = "SRV-01-DC", produktion = "192.168.50.10", drift_mac = "BC:24:11:00:D3:31" }
    srv02 = { vmid = 332, namn = "SRV-02-LNX", produktion = "192.168.50.50", drift_mac = "BC:24:11:00:D3:32" }
  }
}
