#!/bin/bash
# 01-samba-backup.sh
# Gör SRV-02-LNX till backupmål för Windows Server Backup på SRV-01-DC.
# Körs med sudo. Lösenordet för svc-backup läses från standard in, så att det
# inte hamnar i skalhistoriken:
#   sudo ./01-samba-backup.sh < svc-backup-losenord.txt
set -euo pipefail

mountpoint -q /srv/backup || { echo "FEL: /srv/backup är inte monterad" >&2; exit 1; }

# 1. Tjänstekontot. Bara för Samba: inget skal, ingen hemkatalog.
id svc-backup &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin svc-backup

# 2. Mapparna. wsb är utdelad och ägs av svc-backup. arkiv ägs av root och är
#    inte utdelad, så Windows kan inte radera de daterade kopiorna.
install -d -o svc-backup -g svc-backup -m 0700 /srv/backup/wsb
install -d -o root -g root -m 0700 /srv/backup/arkiv

# 3. Samba. Originalet sparas en gång.
[[ -f /etc/samba/smb.conf.orig ]] || cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
cat > /etc/samba/smb.conf <<'CONF'
[global]
   workgroup = SOST
   server string = SRV-02-LNX backup
   server role = standalone server
   # Lyssna bara i produktionsnätet, inte på driftnätet (ens19).
   interfaces = lo ens18
   bind interfaces only = yes
   smb ports = 445
   disable netbios = yes
   # Bara SMB3, och all trafik krypterad.
   server min protocol = SMB3
   server smb encrypt = required
   # Inga gäster och ingen anonym listning.
   map to guest = never
   restrict anonymous = 2
   load printers = no
   printing = bsd
   printcap name = /dev/null
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

[backup]
   comment = Windows Server Backup från SRV-01-DC
   path = /srv/backup/wsb
   valid users = svc-backup
   hosts allow = 192.168.50.10
   hosts deny = ALL
   read only = no
   browseable = no
   create mask = 0600
   directory mask = 0700
CONF
testparm -s > /dev/null

# 4. Sambalösenordet för svc-backup.
read -r LOSEN
LOSEN=${LOSEN%$'\r'}   # ta bort CR om lösenordet skickas från Windows
printf '%s\n%s\n' "$LOSEN" "$LOSEN" | smbpasswd -s -a svc-backup > /dev/null
smbpasswd -e svc-backup > /dev/null

systemctl enable --now smbd > /dev/null 2>&1
systemctl disable --now nmbd > /dev/null 2>&1 || true
systemctl restart smbd

# 5. Brandväggen: SMB bara från domänkontrollanten, SSH bara på driftnätet.
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow in on ens19 to any port 22 proto tcp comment 'SSH från driftnätet' > /dev/null
ufw allow in on ens18 from 192.168.50.10 to any port 445 proto tcp comment 'SMB från SRV-01-DC' > /dev/null
ufw --force enable > /dev/null

ufw status verbose
ss -tlnp | grep -E ':(445|22)\b'
