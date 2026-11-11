# Kunskap: backup och återställning

Bakgrunden till hur Skämt & Sido Transport AB tar backup och återställer. Det här dokumentet förklarar varför. Hur det görs står i [how-to: säkerhetskopiera SRV-01-DC och återställa](how-to-backup-windows-server.md).

## Varför backup

En backup skyddar mot att data försvinner eller blir oanvändbar. De vanligaste orsakerna:

| Orsak | Exempel |
|---|---|
| Misstag | Någon raderar Ekonomi-mappen eller tar bort fel användare i AD |
| Fel i hårdvara eller programvara | En disk går sönder, en uppdatering förstör systemet |
| Angrepp | Ransomware krypterar filerna på alla delningar den kommer åt |
| Katastrof | Brand eller vattenskada i serverrummet |

En backup som aldrig har återställts är inte bevisad. Därför ingår provåterställning i rutinen, på samma sätt som i övning 2 där katalogen raderades och återställdes.

## Begrepp

| Begrepp | Betydelse | Hos Skämt & Sido |
|---|---|---|
| **RPO** (Recovery Point Objective) | Hur mycket data som högst får gå förlorad, mätt i tid | Högst ett dygn: backup varje natt kl. 03:00 |
| **RTO** (Recovery Time Objective) | Hur lång tid återställningen högst får ta | Mäts vid varje provåterställning och skrivs in i driftloggen |
| **Retention** | Hur länge gamla backuper sparas | 4 dagar i arkivet på SRV-02-LNX. Antalet dagar styrs av diskens storlek: varje kopia är cirka 13 GB |
| **Full backup** | Allt kopieras varje gång | Windows Server Backup till nätverksdelning gör alltid full backup |
| **Inkrementell backup** | Bara det som ändrats sedan förra backupen | Används inte |
| **Verifiering** | Kontroll av att backupen går att läsa och återställa | Kontrollsummor i arkivet och provåterställning varje månad |

### 3-2-1-regeln

En vanlig tumregel för backup:

* **3** kopior av datan: originalet och två backuper
* på **2** olika lagringsmedier
* varav **1** utanför huset

| | Hos Skämt & Sido |
|---|---|
| Original | SRV-01-DC |
| Kopia 1 | Senaste backupen på delningen `/srv/samba/backups` på SRV-02-LNX |
| Kopia 2 | Daterade kopior i `/srv/samba/arkiv` på SRV-02-LNX |
| Utanför huset | **Saknas.** Båda servrarna står i samma serverrum. Se [Kvarstående risker](#kvarstående-risker) |

## Vad som är kritiskt

| Data | Var den finns | Varför den är kritisk |
|---|---|---|
| Active Directory | `C:\Windows\NTDS\ntds.dit` | Alla konton, grupper och lösenord. Utan AD kan ingen logga in |
| Grupprinciper (GPO) | `C:\Windows\SYSVOL` | Lösenordspolicy och minsta rättighet enligt CIS |
| DNS | AD-integrerade zoner, lagras i AD | Klienterna hittar inte domänkontrollanten utan DNS |
| DHCP | `C:\Windows\System32\dhcp` | Klienternas adresser och reservationer |
| Avdelningarnas filer | `C:\Fildelning` | Personalregister, budget, lagersaldo med mera |
| NTFS-behörigheter | Lagras på varje mapp och fil | Utan dem kan alla anställda läsa HR:s och Ekonomis filer |

## Windows Server Backup

Windows Server Backup (WSB) är Windows Servers inbyggda backupfunktion. Den styrs med `wbadmin` på kommandoraden eller med `wbadmin.msc`.

### Vad som säkerhetskopieras

**System State** är en samling av det som behövs för att återskapa serverns roll. På en domänkontrollant ingår AD-databasen, SYSVOL, registret och startfilerna ([Microsoft Learn: wbadmin enable backup](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wbadmin-enable-backup)). AD-integrerade DNS-zoner följer med AD-databasen.

Utöver System State tar Skämt & Sido med `C:\Fildelning` och DHCP-tjänstens egen backupmapp `C:\Windows\System32\dhcp\backup`.

### Hur det fungerar

1. WSB tar en ögonblicksbild med VSS (Volume Shadow Copy Service). Filerna kan vara öppna och AD kan vara igång medan backupen tas.
2. Datan skrivs till en virtuell disk (`.vhdx`) i mappen `WindowsImageBackup\SRV-01-DC\` på backupmålet, tillsammans med en katalog över vad backupen innehåller.
3. NTFS-behörigheterna följer med filerna och återställs som standard.

### En version på nätverksdelning

Till en nätverksdelning sparar WSB bara den senaste backupen. Microsoft skriver att en ny backup skriver över den gamla, och att en misslyckad körning kan lämna ingen användbar backup alls. Det går heller inte att ange fler mål tillsammans med en delning.

Därför finns arkivet på SRV-02-LNX. Linux kopierar varje ny backup till en daterad mapp som inte är utdelad. Det ger flera versioner, och en angripare som tar över SRV-01-DC och kontot `backupuser` kan skriva över den senaste backupen men inte radera arkivet.

### Tjänstekontot

`backupuser` är medlem i Backup Operators, inte i Domain Admins. Det är minsta möjliga rättighet: kontot kan ta och återställa backup men inte administrera domänen. Samma konto, med samma lösenord, finns som Samba-användare på SRV-02-LNX, och det är det enda kontot som får skriva i delningen `backups`.

## Typer av återställning

| Typ | När | Hur |
|---|---|---|
| Fil eller mapp | En fil eller mapp är raderad eller förstörd | `wbadmin start recovery -itemType:File`, servern är igång |
| GPO | En grupprincip är felaktigt ändrad | Återställ mappen i SYSVOL, eller GPO-backup med `Restore-GPO` |
| AD-objekt | En användare eller grupp är raderad | AD:s papperskorg om den är påslagen, annars System State i DSRM med auktoritativ återställning |
| System State | AD eller registret är förstört | Starta i DSRM (Directory Services Restore Mode), `wbadmin start systemstaterecovery` |
| Hela servern | Servern går inte att starta | Ny server installeras enligt installationsdokumentationen, sedan System State och filer från backupen |

**DSRM** är ett felsäkert läge för domänkontrollanter där AD inte körs. Det har ett eget lösenord, som sattes när servern blev domänkontrollant. Lösenordet förvaras utanför servern.

**Icke-auktoritativ** återställning lägger tillbaka AD som det var vid backupen. Finns fler domänkontrollanter skriver de sedan över med nyare data. **Auktoritativ** återställning markerar återställda objekt som nyast, så att de vinner. Skämt & Sido har bara en domänkontrollant, så återställd AD gäller direkt.

## Från övning 2 till Windows Server

| Övning 2, Ubuntu | Skämt & Sido, Windows Server |
|---|---|
| `tar -czf` packar katalogen | `wbadmin` tar en VSS-ögonblicksbild till `.vhdx` |
| Filnamn med datum, `viktig_data_ÅÅÅÅ-MM-DD_TTMM.tar.gz` | WSB:s egna mappar, arkivet får datum: `SRV-01-DC_ÅÅÅÅ-MM-DD_TTMM` |
| Separat backupdisk `/mnt/backup` | Separat server, SRV-02-LNX |
| `cron` | WSB:s schema på Windows och `systemd`-timer på Linux |
| `sha256sum -c` | Kontrollsummor i arkivet, och hash före och efter provåterställning |
| `tar -xzf` till ursprunglig plats | `wbadmin start recovery` till ursprunglig plats |
| Behörigheter följer inte alltid med | NTFS-behörigheterna återställs som standard och kontrolleras med `icacls` |

## Kvarstående risker

| Risk | Följd | Åtgärd som föreslås |
|---|---|---|
| Ingen kopia utanför huset | Brand eller stöld i serverrummet tar både servrar och backup | Kopiera arkivet till molnlagring eller en disk som förvaras på annan plats |
| En domänkontrollant | Går SRV-01-DC sönder går ingen inloggning tills den är återställd | En andra domänkontrollant |
| Backupen är inte krypterad på disken | Den som kommer åt SRV-02-LNX kan läsa AD-databasen | Kryptera backupdisken |

Trafiken mellan servrarna är krypterad med SMB3, och delningen nås bara från SRV-01-DC.
