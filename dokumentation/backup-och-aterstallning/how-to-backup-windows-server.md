# How-to: Säkerhetskopiera SRV-01-DC till SRV-02-LNX och återställa

Planera, genomföra och verifiera säkerhetskopiering och återställning av Skämt & Sido Transports kritiska konfigurationsfiler och data på Windows Server. Backupen tas med Windows Server Backup (WSB) och sparas på Ubuntu-filservern via Samba.

Namnen följer teamets miljö: kontot `backupuser`, delningen `backups` och nätverkskortet `enp0s3`. I labbet på Proxmox heter de `svc-backup`, `backup` och `ens18`, se [02 Backupmålet SRV-02-LNX](../02-backupmal-srv-02-lnx.md) och [03 Domänkontrollanten SRV-01-DC](../03-domankontrollant-srv-01-dc.md).

**Förutsättningar:**

* SRV-01-DC är domänkontrollant för `sost.local` med `C:\Fildelning` enligt Fildelning.md i infra-sstab.
* Adresser och servernamn enligt IP-planen i infra-sstab: SRV-01-DC 192.168.50.10, SRV-02-LNX 192.168.50.50 på `enp0s3`.

## 1. Plan

| Fråga | Svar |
|---|---|
| Vad säkerhetskopieras | **System State**: AD-databasen med användare, grupper och de AD-integrerade DNS-zonerna, SYSVOL med GPO:erna (lösenordspolicy, minsta rättighet), registret och startfilerna. **`C:\Fildelning`**: avdelningarnas filer med NTFS-behörigheter. **`C:\Windows\System32\dhcp\backup`**: DHCP-databasen |
| Källa | SRV-01-DC, 192.168.50.10 |
| Destination | Samba-delningen `\\192.168.50.50\backups` på SRV-02-LNX, mappen `/srv/samba/backups` |
| Konto | `backupuser@sost.local`, medlem i Backup Operators. Samma namn och lösenord som Samba-användaren `backupuser` på SRV-02-LNX |
| Metod | Schemalagd full backup med WSB varje natt kl. 03:00 |
| Versioner | WSB skriver över förra backupen på en nätverksdelning. SRV-02-LNX kopierar därför varje ny backup till `/srv/samba/arkiv`, som inte är utdelad, och sparar kopiorna i 14 dagar |
| Nät | Bara produktionsnätet 192.168.50.0/24. Trafiken är krypterad med SMB3 |
| RPO | Högst ett dygn: data som skapas efter 03:00 finns i backupen nästa natt |
| Ansvar | IT-avdelningen (gruppen `gg-it`) |

**Varför ett konto i AD.** Kontot som WSB använder mot delningen måste vara medlem i Administrators eller Backup Operators på servern som säkerhetskopieras ([Microsoft Learn: wbadmin enable backup](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wbadmin-enable-backup)). Ett konto som bara finns på Ubuntu räcker inte. Backup Operators kan ta och återställa backup men inte administrera domänen, vilket följer minsta rättighet.

**Varför UPN.** Kontot anges som `backupuser@sost.local` (UPN), inte i det äldre formatet `SOST\backupuser`. UPN är samma som användarens inloggningsnamn och e-postformat och är Microsofts rekommenderade format.

**Varför ingen mappad enhet.** Schemat körs i bakgrunden utan att någon är inloggad, och ser då inte enheter som `B:` eller uppgifter sparade med `cmdkey` i en användares session. WSB får kontot och lösenordet direkt och sparar dem själv.

## 2. Genomförande på SRV-02-LNX

Logga in med `ssh <användare>@192.168.50.50`.

1. Skapa kontot för Samba. Det har inget skal och ingen hemkatalog, så det kan inte logga in på servern:

   ```bash
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin backupuser
   ```

2. Skapa mapparna. `backups` delas ut och ägs av `backupuser`. `arkiv` ägs av root och delas inte ut:

   ```bash
   sudo install -d -o backupuser -g backupuser -m 0700 /srv/samba/backups
   sudo install -d -o root -g root -m 0700 /srv/samba/arkiv
   ```

3. Lägg till inställningarna i `/etc/samba/smb.conf`:

   ```ini
   [global]
      server role = standalone server
      interfaces = lo enp0s3
      bind interfaces only = yes
      server min protocol = SMB3
      server smb encrypt = required
      map to guest = never
      restrict anonymous = 2
      username map = /etc/samba/anvandarnamn.map

   [backups]
      path = /srv/samba/backups
      valid users = backupuser
      hosts allow = 192.168.50.10
      hosts deny = ALL
      read only = no
      browseable = no
      create mask = 0600
      directory mask = 0700
   ```

4. Skapa `/etc/samba/anvandarnamn.map` med en rad. Samba på SRV-02-LNX är inte med i domänen och känner bara till den lokala användaren `backupuser`. Raden översätter UPN-namnet som Windows skickar till den lokala användaren:

   ```text
   backupuser = backupuser@sost.local
   ```

   Utan raden nekas inloggningen med `System error 1326`, vilket är provat i labbet. Med raden: inte provad än, se [Verifiering](#4-verifiering).

5. Kontrollera filen, sätt Samba-lösenordet och starta om:

   ```bash
   sudo testparm -s
   sudo smbpasswd -a backupuser
   sudo systemctl restart smbd
   ```

6. Öppna brandväggen för SMB bara från SRV-01-DC:

   ```bash
   sudo ufw allow in on enp0s3 from 192.168.50.10 to any port 445 proto tcp comment 'SMB från SRV-01-DC'
   sudo ufw status numbered
   ```

**Kontroll:**

```bash
ss -tlnp | grep ':445'
sudo smbclient -L localhost -N
```

Samba ska bara lyssna på `192.168.50.50:445` och loopback. Anonym listning ska ge `NT_STATUS_ACCESS_DENIED`.

## 3. Genomförande på SRV-01-DC

Logga in som domänadministratör och öppna PowerShell som administratör.

1. Skapa kontot i OU:n `Tjänstekonton` och lägg det i Backup Operators. Använd samma lösenord som Samba-användaren:

   ```powershell
   New-ADUser -SamAccountName backupuser -UserPrincipalName backupuser@sost.local `
       -Name 'Backupkonto' -Path 'OU=Tjänstekonton,DC=sost,DC=local' -Enabled $true `
       -AccountPassword (Read-Host -AsSecureString 'Lösenord')
   Add-ADGroupMember 'Backup Operators' -Members backupuser
   Set-ADUser backupuser -PasswordNeverExpires $true -CannotChangePassword $true
   ```

   Kontot ligger utanför `SkamtSidoTransport`, där gruppen `gg-it` har delegerad rätt att byta lösenord.

2. Kontrollera att kontot kommer åt delningen. `*` gör att lösenordet frågas efter och inte står på kommandoraden:

   ```powershell
   net use \\192.168.50.50\backups /user:backupuser@sost.local *
   Get-SmbConnection -ServerName 192.168.50.50 | Format-Table ShareName, Dialect, Encrypted
   net use \\192.168.50.50\backups /delete
   ```

   Förväntat: `Dialect 3.1.1` och `Encrypted True`, som visar att trafiken är krypterad.

3. Installera Windows Server Backup om den saknas:

   ```powershell
   Install-WindowsFeature Windows-Server-Backup -IncludeManagementTools
   ```

4. Schemalägg backupen:

   ```powershell
   wbadmin enable backup `
       "-addtarget:\\192.168.50.50\backups" `
       -user:backupuser@sost.local `
       "-password:<lösenordet>" `
       -systemState `
       "-include:C:\Fildelning,C:\Windows\System32\dhcp\backup" `
       -vssFull `
       -schedule:03:00 `
       -quiet
   ```

   `-vssFull` gör en fullständig VSS-backup, vilket är rätt när WSB är det enda backupprogrammet på servern.

## 4. Verifiering

**Pågår.** Första backupen i labbet startades manuellt 2026-11-11 kl. 10:41 med samma innehåll som schemat. Den första fasen, där WSB räknar upp filerna i System State, hade efter 46 minuter kommit till 153 305 filer.

När backupen är klar verifieras den i två delar, och resultatet förs in här:

1. **Backupen:** att versionen finns på delningen (`wbadmin get versions`), att arkivet på SRV-02-LNX har fått en daterad kopia med kontrollsummor, och hur lång tid backupen tog.
2. **Återställningen:** en avdelningsmapp i `C:\Fildelning` raderas och återställs från backupen. Innehållet jämförs med kontrollsummor (`Get-FileHash`) och NTFS-behörigheterna med `icacls`, före och efter. Tiden mäts och blir det uppmätta RTO-värdet.
