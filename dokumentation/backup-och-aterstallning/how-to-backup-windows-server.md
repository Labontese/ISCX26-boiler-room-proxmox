# How-to: Säkerhetskopiera SRV-01-DC till SRV-02-LNX och återställa

Planera, genomföra och verifiera säkerhetskopiering och återställning av Skämt & Sido Transports kritiska konfigurationsfiler och data på Windows Server. Backupen tas med Windows Server Backup (WSB) och sparas på Ubuntu-filservern via Samba.

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
| Versioner | WSB skriver över förra backupen på en nätverksdelning. SRV-02-LNX kopierar därför varje ny backup till `/srv/samba/arkiv`, som inte är utdelad, och sparar kopiorna i 4 dagar. En backup är cirka 13 GB, så backupdisken måste rymma fem kopior och den senaste backupen, cirka 78 GB |
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

   Utan raden nekas inloggningen med `System error 1326`. Med raden: inte provad än, se [Verifiering](#4-verifiering).

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

Verifierat 2026-11-11.

### Backupen

En första backup startades manuellt kl. 10:41 med samma innehåll som schemat:

```text
The backup operation successfully completed.
The backup of volume Windows(C:) completed successfully.
The backup of the system state successfully completed [2026-11-11 11:17].
```

| Kontroll | Resultat |
|---|---|
| Tid för backupen | 98 minuter. Mest tid tog uppräkningen av drygt 153 000 filer i System State, som Microsoft Defender genomsöker en i taget |
| Storlek på SRV-02-LNX | 13 GB |
| Schemat (`Get-WBPolicy`) | Kl. 03:00, System State, `C:\Fildelning\`, `C:\Windows\System32\dhcp\backup\`, `VssFullBackup` |
| Nästa backup (`Get-WBSummary`) | 2026-11-12 03:00 |
| Kryptering (`smbstatus -S` på SRV-02-LNX) | AES-128-GCM |
| Arkivet | Kopia på 13 GB med kontrollsummor för 20 filer, kontrollerad mot källan, klar på cirka 7 minuter |

Arkivskriptet stoppade två gånger innan kopian togs, som det ska: först för att backupen fortfarande hade filer öppna, sedan för att den hade ändrats de senaste 30 minuterna.

### Återställningen

Provet: mappen `C:\Fildelning\HR` raderades och återställdes från backupen till sin ursprungliga plats, med ett provskript som sparar kontrollsummor och behörigheter före och jämför efter.

```text
Raderad: C:\Fildelning\HR finns = False
Version: 11/11/2026-09:41
Efter: 1 filer
Innehåll lika: True
NTFS-behörigheter lika: True
Tid för återställningen: 25 sekunder
C:\Fildelning\HR BUILTIN\Administrators:(F)
                 SOST\dl-hr-rw:(OI)(CI)(M)
                 CREATOR OWNER:(OI)(CI)(IO)(F)
                 BUILTIN\Administrators:(OI)(CI)(F)
                 NT AUTHORITY\SYSTEM:(OI)(CI)(F)
```

| Kontroll | Resultat |
|---|---|
| Innehåll, SHA256 före och efter | Lika |
| NTFS-behörigheter, `icacls /save` före och efter | Lika. Arvet är fortfarande brutet och `Users` saknas |
| Uppmätt RTO för en mapp | 25 sekunder från anslutning till klar återställning |
| HR-användaren efter återställningen | Kan skriva i HR, kan läsa men inte skriva i Gemensamma dokument, nekas i Ekonomi |

Versionen i `wbadmin get versions` anges i UTC: `09:41` är 10:41 svensk tid.

### Inte provat

| Vad | Varför |
|---|---|
| Namnmappningen för UPN i Samba | Att Samba nekar UPN utan den är provat. Att mappningen löser det är inte provat |
| Återställning av System State (AD) | Kräver omstart i DSRM. Stegen står i [kunskap: backup och återställning](kunskap-backup-och-aterstallning.md#typer-av-återställning) |
| Återställning från arkivet | Instruktionen finns i [rutinen](rutin-backup-och-aterstallning.md) |
