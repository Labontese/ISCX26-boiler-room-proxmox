# Backupmålet SRV-02-LNX

SRV-02-LNX tar emot Windows Server Backup från SRV-01-DC via en Samba-delning och sparar daterade kopior som Windows inte kan ändra.

**Förutsättningar:** SRV-02-LNX skapad enligt [01 Miljön på Proxmox](01-miljon-pa-proxmox.md), backupdisken monterad på `/srv/backup`.

## Så är det uppbyggt

| Sökväg | Ägare | Rättigheter | Utdelad | Innehåll |
|---|---|---|---|---|
| `/srv/backup` | root | | Nej | Backupdisken `/dev/sdb1`, ext4, etikett `backup` |
| `/srv/backup/wsb` | `svc-backup` | 0700 | Ja, som `backup` | Senaste backupen. Windows skriver över den varje gång |
| `/srv/backup/arkiv` | root | 0700 | Nej | Daterade kopior av backupen |

Backupdisken monteras med `nodev,nosuid,noexec`. Där ska bara ligga data, aldrig program.

Varför två mappar: Windows Server Backup sparar bara en version på en nätverksdelning. Varje backup skriver över den förra, och om en körning misslyckas kan den enda backupen vara förstörd ([Microsoft Learn: wbadmin enable backup](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wbadmin-enable-backup)). Därför ska SRV-02-LNX kopiera den senaste backupen till `arkiv`. Den mappen är inte utdelad, så inte ens den som har lösenordet till `svc-backup` kan radera de gamla kopiorna från Windows.

## Steg 1: Samba och brandvägg

Skriptet `skript/linux/01-samba-backup.sh` gör allt i det här steget och tål att köras om. Lösenordet till `svc-backup` läses från standard in, så att det inte hamnar i skalhistoriken:

```powershell
scp skript\linux\01-samba-backup.sh daniel@10.10.70.124:/tmp/
Get-Content svc-backup-losenord.txt | ssh daniel@10.10.70.124 'sudo bash /tmp/01-samba-backup.sh'
```

Skriptet:

1. Skapar systemkontot `svc-backup` utan skal och utan hemkatalog. Kontot finns bara för Samba.
2. Skapar `/srv/backup/wsb` och `/srv/backup/arkiv` med ägare och rättigheter enligt tabellen ovan.
3. Skriver `/etc/samba/smb.conf`, originalet sparas som `smb.conf.orig`.
4. Sätter Samba-lösenordet för `svc-backup`.
5. Startar `smbd`, stänger av `nmbd` och sätter upp brandväggen.

### Samba

Kontrollerad med `sudo testparm -s`:

```text
[global]
	bind interfaces only = Yes
	disable netbios = Yes
	interfaces = lo ens18
	restrict anonymous = 2
	server min protocol = SMB3
	server role = standalone server
	server smb encrypt = required
	server smb transports = 445
	workgroup = SOST

[backup]
	browseable = No
	create mask = 0600
	directory mask = 0700
	hosts allow = 192.168.50.10
	hosts deny = ALL
	path = /srv/backup/wsb
	read only = No
	valid users = svc-backup
```

| Inställning | Varför |
|---|---|
| `interfaces = lo ens18`, `bind interfaces only` | Samba lyssnar bara i produktionsnätet, inte på driftnätet |
| `server min protocol = SMB3`, `server smb encrypt = required` | Inga gamla protokoll, och backuptrafiken är krypterad på nätet |
| `restrict anonymous = 2`, `disable netbios` | Ingen anonym listning, ingen NetBIOS |
| `valid users = svc-backup`, `hosts allow = 192.168.50.10` | Bara backupkontot, och bara från domänkontrollanten |
| `browseable = No` | Delningen syns inte i listor |
| `create mask = 0600`, `directory mask = 0700` | Bara `svc-backup` kan läsa backupfilerna på Linux |

### Brandväggen

```text
     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp on ens19            ALLOW IN    Anywhere                   # SSH från driftnätet
[ 2] 445/tcp on ens18           ALLOW IN    192.168.50.10              # SMB från SRV-01-DC
[ 3] 22/tcp (v6) on ens19       ALLOW IN    Anywhere (v6)              # SSH från driftnätet
```

Allt annat inkommande nekas.

### Kontroll

```bash
ss -tlnp | grep ':445'
sudo smbclient -L localhost -N
```

Samba ska bara lyssna på `192.168.50.50:445` och loopback. Anonym listning ska ge `NT_STATUS_ACCESS_DENIED`.
