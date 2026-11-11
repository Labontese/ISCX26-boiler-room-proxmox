# ISCX26 Boiler Room på Proxmox

Servermiljön för det fiktiva logistikföretaget Skämt & Sido Transport AB, byggd i mitt hemlabb på Proxmox VE. Kurs 2 i ISCX26 (IT Infrastructure Secure Cloud, Chas Academy), teamprojektet Boiler Room, delarna C (härdning) och D (backup och katastrofåterställning), kursmål 10 och 11.

Allt här är utfört och provat på riktiga virtuella maskiner. Utskrifterna i dokumentationen kommer från dem.

## Miljön

| Server | Operativsystem | Roll | Produktion |
|---|---|---|---|
| SRV-01-DC | Windows Server 2025 | Domänkontrollant `sost.local`, DNS, DHCP, Windows Server Backup | 192.168.50.10 |
| SRV-02-LNX | Ubuntu Server 26.04 LTS | Samba, backupmål | 192.168.50.50 |

Produktionsnätet 192.168.50.0/24 är en isolerad virtuell switch på Proxmox. Varje server har också ett kort på driftnätet för administration.

## Dokumentation

| Dokument | Innehåll |
|---|---|
| [01 Miljön på Proxmox](dokumentation/01-miljon-pa-proxmox.md) | Virtuella switchen, Terraform, nätverkskorten, första steget på SRV-01-DC |
| [02 Backupmålet SRV-02-LNX](dokumentation/02-backupmal-srv-02-lnx.md) | Backupdisken, Samba-delningen och brandväggen |
| [03 Domänkontrollanten SRV-01-DC](dokumentation/03-domankontrollant-srv-01-dc.md) | AD DS, OU:er och grupper, fildelning, DNS och DHCP, minsta rättighet, lösenordspolicy, prov av behörigheterna |
| [Det som saknas i infra-sstab](dokumentation/guide-det-som-saknas-i-infra-sstab.md) | Arbetslista för teamets officiella repo, jämfört med uppgiften och kursmålen |

## Filer

| Sökväg | Innehåll |
|---|---|
| `main.tf`, `variables.tf`, `providers.tf` | Terraform för de två servrarna (provider `bpg/proxmox`) |
| `terraform.tfvars.exempel` | Mall för de hemliga värdena. Den riktiga `terraform.tfvars` finns aldrig i repot |
| `cloud-init/` | Nätverk, användare och backupdisk för SRV-02-LNX |
| `skript/linux/` | Skript som körs på SRV-02-LNX |
| `skript/windows/` | Skript som körs på SRV-01-DC |

## Hemligheter

Lösenord, API-token och privata nycklar finns aldrig i repot. Skripten tar lösenord som parameter eller läser dem från standard in.
