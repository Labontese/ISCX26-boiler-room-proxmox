# How-to: Säkerhetskopiera SRV-01-DC till SRV-02-LNX och återställa

Planera, genomföra och verifiera säkerhetskopiering och återställning av Skämt & Sido Transports kritiska konfigurationsfiler och data på Windows Server. Backupen tas med Windows Server Backup (WSB) och sparas på Ubuntu-filservern via Samba.

**Förutsättningar:**

* SRV-01-DC är domänkontrollant för `sost.local` med `C:\Fildelning`, se [03 Domänkontrollanten SRV-01-DC](../03-domankontrollant-srv-01-dc.md).
* SRV-02-LNX har en egen backupdisk monterad på `/srv/backup`, se [01 Miljön på Proxmox](../01-miljon-pa-proxmox.md).
* Adresser och servernamn enligt IP-planen i infra-sstab: SRV-01-DC 192.168.50.10, SRV-02-LNX 192.168.50.50.

## 1. Plan

| Fråga | Svar |
|---|---|
| Vad säkerhetskopieras | **System State**: AD-databasen med användare, grupper och de AD-integrerade DNS-zonerna, SYSVOL med GPO:erna (lösenordspolicy, minsta rättighet), registret och startfilerna. **`C:\Fildelning`**: avdelningarnas filer med NTFS-behörigheter. **`C:\Windows\System32\dhcp\backup`**: DHCP-databasen |
| Källa | SRV-01-DC, 192.168.50.10 |
| Destination | Samba-delningen `\\192.168.50.50\backup` på SRV-02-LNX, mappen `/srv/backup/wsb` |
| Konto | `SOST\svc-backup`, medlem i Backup Operators. Samma namn och lösenord som Samba-användaren på SRV-02-LNX |
| Metod | Schemalagd full backup med WSB varje natt kl. 03:00 |
| Versioner | WSB skriver över förra backupen på en nätverksdelning. SRV-02-LNX kopierar därför varje ny backup till `/srv/backup/arkiv`, som inte är utdelad, och sparar kopiorna i 14 dagar |
| Nät | Bara produktionsnätet 192.168.50.0/24. Trafiken är krypterad med SMB3 |
| RPO | Högst ett dygn: data som skapas efter 03:00 finns i backupen nästa natt |
| Ansvar | IT-avdelningen (gruppen `gg-it`) |

**Varför ett eget konto i AD.** Kontot som WSB använder mot delningen måste vara medlem i Administrators eller Backup Operators på servern som säkerhetskopieras ([Microsoft Learn: wbadmin enable backup](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wbadmin-enable-backup)). Ett konto som bara finns på Ubuntu räcker inte. Backup Operators kan ta och återställa backup men inte administrera domänen, vilket följer minsta rättighet.

**Varför ingen mappad enhet.** Schemat körs i bakgrunden utan att någon är inloggad, och ser då inte enheter som `B:` eller uppgifter sparade med `cmdkey` i en användares session. WSB får kontot och lösenordet direkt och sparar dem själv.

## 2. Genomförande på SRV-02-LNX

Logga in med `ssh daniel@<SRV-02-LNX driftadress>`. Stegen nedan är samma som skriptet `skript/linux/01-samba-backup.sh` gör.

1. Skapa systemkontot för Samba. Det har inget skal och ingen hemkatalog:

   ```bash
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin svc-backup
   ```

2. Skapa mapparna. `wsb` delas ut och ägs av `svc-backup`. `arkiv` ägs av root och delas inte ut:

   ```bash
   sudo install -d -o svc-backup -g svc-backup -m 0700 /srv/backup/wsb
   sudo install -d -o root -g root -m 0700 /srv/backup/arkiv
   ```

3. Lägg till delningen i `/etc/samba/smb.conf`:

   ```ini
   [global]
      server role = standalone server
      interfaces = lo ens18
      bind interfaces only = yes
      server min protocol = SMB3
      server smb encrypt = required
      map to guest = never
      restrict anonymous = 2

   [backup]
      path = /srv/backup/wsb
      valid users = svc-backup
      hosts allow = 192.168.50.10
      hosts deny = ALL
      read only = no
      browseable = no
      create mask = 0600
      directory mask = 0700
   ```

4. Kontrollera filen, sätt Samba-lösenordet och starta om:

   ```bash
   sudo testparm -s
   sudo smbpasswd -a svc-backup
   sudo systemctl restart smbd
   ```

5. Öppna brandväggen för SMB bara från SRV-01-DC:

   ```bash
   sudo ufw allow in on ens18 from 192.168.50.10 to any port 445 proto tcp comment 'SMB från SRV-01-DC'
   sudo ufw status numbered
   ```

**Kontroll:**

```text
$ ss -tlnp | grep ':445'
LISTEN 0      50         127.0.0.1:445       0.0.0.0:*    users:(("smbd",pid=3929,fd=29))
LISTEN 0      50     192.168.50.50:445       0.0.0.0:*    users:(("smbd",pid=3929,fd=28))
```

Samba lyssnar bara i produktionsnätet och på loopback. `sudo smbclient -L localhost -N` ska ge `NT_STATUS_ACCESS_DENIED`, eftersom anonym listning är avstängd.

## 3. Genomförande på SRV-01-DC

Logga in som domänadministratör och öppna PowerShell som administratör.

1. Skapa tjänstekontot i OU:n `Tjänstekonton` och lägg det i Backup Operators. Använd samma lösenord som Samba-användaren:

   ```powershell
   New-ADUser -SamAccountName svc-backup -UserPrincipalName svc-backup@sost.local `
       -Name 'Tjänstekonto backup' -Path 'OU=Tjänstekonton,DC=sost,DC=local' -Enabled $true `
       -AccountPassword (Read-Host -AsSecureString 'Lösenord')
   Add-ADGroupMember 'Backup Operators' -Members svc-backup
   Set-ADUser svc-backup -PasswordNeverExpires $true -CannotChangePassword $true
   ```

   Kontot ligger utanför `SkamtSidoTransport`, där gruppen `gg-it` har delegerad rätt att byta lösenord.

2. Kontrollera att kontot kommer åt delningen:

   ```powershell
   net use \\192.168.50.50\backup /user:SOST\svc-backup
   Get-SmbConnection -ServerName 192.168.50.50 | Format-Table ShareName, Dialect, Encrypted
   net use \\192.168.50.50\backup /delete
   ```

   ```text
   ShareName Dialect Encrypted
   --------- ------- ---------
   backup    3.1.1        True
   IPC$      3.1.1        True
   ```

   `Encrypted True` visar att trafiken är krypterad, eftersom SRV-02-LNX kräver det.

3. Installera Windows Server Backup om den saknas:

   ```powershell
   Install-WindowsFeature Windows-Server-Backup -IncludeManagementTools
   ```

4. Schemalägg backupen. Skriptet `skript/windows/08-backup-schema.ps1` kör samma kommando:

   ```powershell
   wbadmin enable backup `
       "-addtarget:\\192.168.50.50\backup" `
       -user:SOST\svc-backup `
       "-password:<lösenordet>" `
       -systemState `
       "-include:C:\Fildelning,C:\Windows\System32\dhcp\backup" `
       -vssFull `
       -schedule:03:00 `
       -quiet
   ```

   `-vssFull` gör en fullständig VSS-backup, vilket är rätt när WSB är det enda backupprogrammet på servern.

## 4. Verifiering

**Pågår.** Första backupen startades manuellt 2026-11-11 kl. 10:41 med samma innehåll som schemat. Den första fasen, där WSB räknar upp filerna i System State, hade efter 46 minuter kommit till 153 305 filer. Schemat kl. 03:00 slås på när den första backupen är klar, eftersom WSB inte ändrar schemat medan en backup körs.

När backupen är klar verifieras den i två delar, och resultatet förs in här:

1. **Backupen:** att versionen finns på delningen (`wbadmin get versions`), att arkivet på SRV-02-LNX har fått en daterad kopia med kontrollsummor, och hur lång tid backupen tog.
2. **Återställningen:** en avdelningsmapp i `C:\Fildelning` raderas och återställs från backupen. Innehållet jämförs med kontrollsummor (`Get-FileHash`) och NTFS-behörigheterna med `icacls`, före och efter. Tiden mäts och blir det uppmätta RTO-värdet.

Exakta värden för Samba-konfigurationen och brandväggen finns i [02 Backupmålet SRV-02-LNX](../02-backupmal-srv-02-lnx.md).
