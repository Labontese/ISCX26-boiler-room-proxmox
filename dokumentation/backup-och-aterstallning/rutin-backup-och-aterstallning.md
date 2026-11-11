# Rutin: backup och återställning av SRV-01-DC

## Syfte

Säkerställa att Skämt & Sido Transports kritiska data och konfiguration på domänkontrollanten SRV-01-DC kan återställas vid dataförlust, och att arbetet görs på samma sätt varje gång.

Hur backupen är uppsatt står i [how-to: säkerhetskopiera SRV-01-DC och återställa](how-to-backup-windows-server.md). Varför den är uppsatt så står i [kunskap: backup och återställning](kunskap-backup-och-aterstallning.md).

## Ansvar

IT-avdelningen ansvarar för att backuper tas och att de fungerar.

| Roll | Ansvar |
|---|---|
| Driftansvarig (IT-tekniker i `gg-it`) | Kontrollerar backupen, gör provåterställningar och återställer vid incident |
| Ersättare | En namngiven kollega i IT som tar över vid frånvaro |
| IT-chef | Godkänner rutinen och följer upp kontrollerna |

## Så tas backup

Backupen tas automatiskt med Windows Server Backup **varje natt kl. 03:00**. Ingen behöver göra något för den schemalagda backupen.

| Vad | Innehåll |
|---|---|
| System State | AD med användare, grupper och DNS-zoner, SYSVOL med GPO:erna, registret |
| `C:\Fildelning` | Avdelningarnas filer med NTFS-behörigheter |
| `C:\Windows\System32\dhcp\backup` | DHCP-databasen |

En extra backup, till exempel före en större ändring, tas i PowerShell som administratör på SRV-01-DC:

```powershell
wbadmin start backup "-backupTarget:\\192.168.50.50\backups" -user:backupuser@sost.local "-password:<lösenordet>" -systemState "-include:C:\Fildelning,C:\Windows\System32\dhcp\backup" -vssFull -quiet
```

Den skriver över backupen på delningen, precis som den schemalagda. En backup tar ungefär 1,5 timme.

## Filnamn och var backuperna sparas

| Plats | Server | Innehåll | Namn |
|---|---|---|---|
| `\\192.168.50.50\backups` (`/srv/samba/backups`) | SRV-02-LNX | Senaste backupen. Skrivs över varje natt | `WindowsImageBackup\SRV-01-DC\Backup ÅÅÅÅ-MM-DD TTMMSS\`. Tiden i namnet är UTC |
| `/srv/samba/arkiv` | SRV-02-LNX | Daterade kopior i 4 dagar. Inte utdelad, kan inte ändras från Windows | `SRV-01-DC_ÅÅÅÅ-MM-DD_TTMM/` och `SRV-01-DC_ÅÅÅÅ-MM-DD_TTMM.sha256`, svensk tid |

Kopian till arkivet görs av `arkivera-wsb.sh` på SRV-02-LNX varje morgon kl. 07:00. Loggen finns i `/var/log/arkivera-wsb.log`.

## Så kontrolleras backupen

| När | Kontroll | Godkänt |
|---|---|---|
| Varje morgon | `Get-WBSummary` på SRV-01-DC | `LastBackupResultHR` är 0 och `LastSuccessfulBackupTime` är från natten |
| Varje morgon | `sudo tail -1 /var/log/arkivera-wsb.log` på SRV-02-LNX | Raden börjar med dagens datum och `OK` |
| Varje månad | Provåterställning enligt instruktionen nedan | Innehåll och NTFS-behörigheter lika före och efter. Resultat och tid skrivs in i driftloggen |
| Vid fel | Driftansvarig åtgärdar samma dag och informerar IT-chefen | Nästa natts backup är godkänd |

En misslyckad backup kan förstöra den senaste versionen på delningen. Kontrollera då att arkivet har en hel kopia innan något annat görs.

## Var dokumentationen finns

I teamets Git-repo och utskriven i driftpärmen i serverrummet. Den ska inte bara finnas på SRV-01-DC, eftersom den då är borta när den behövs.

Lösenorden för `backupuser` och DSRM finns i det låsta lösenordsvalvet, aldrig i repot.

## Instruktion: återställa en fil eller mapp

Exemplet återställer mappen `C:\Fildelning\HR` till sin ursprungliga plats. Kör i PowerShell som administratör på SRV-01-DC.

1. **Anslut till backupdelningen.** Kommandot frågar efter lösenordet:

   ```powershell
   net use \\192.168.50.50\backups /user:backupuser@sost.local *
   ```

2. **Välj version.** Den senaste står sist. Tiden är UTC:

   ```powershell
   wbadmin get versions "-backupTarget:\\192.168.50.50\backups" -machine:SRV-01-DC
   ```

3. **Återställ.** NTFS-behörigheterna följer med som standard:

   ```powershell
   wbadmin start recovery "-version:<MM/DD/ÅÅÅÅ-TT:MM>" -itemType:File "-items:C:\Fildelning\HR" -recursive "-backupTarget:\\192.168.50.50\backups" -machine:SRV-01-DC -overwrite:Overwrite -quiet
   net use \\192.168.50.50\backups /delete
   ```

4. **Verifiera.** Kontrollera att filerna finns, och jämför behörigheterna med [Fildelning.md i infra-sstab](https://github.com/Labontese/infra-sstab/blob/main/docs/reference/Fildelning.md):

   ```powershell
   Get-ChildItem C:\Fildelning\HR -Recurse
   icacls C:\Fildelning\HR
   ```

   `SOST\dl-hr-rw:(OI)(CI)(M)` ska finnas, och `Users` ska inte finnas.

5. **Dokumentera** datum, vem som gjorde det, vilken version som användes, hur lång tid det tog och resultatet.

Om den senaste versionen på delningen är trasig: kopiera en daterad kopia från arkivet tillbaka på SRV-02-LNX och börja om från steg 1. Det här sättet är inte provat än.

```bash
sudo mv /srv/samba/backups/WindowsImageBackup/SRV-01-DC /srv/samba/backups/WindowsImageBackup/SRV-01-DC.trasig
sudo cp -a /srv/samba/arkiv/SRV-01-DC_<ÅÅÅÅ-MM-DD_TTMM> /srv/samba/backups/WindowsImageBackup/SRV-01-DC
```
