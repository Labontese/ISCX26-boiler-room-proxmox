# Domänkontrollanten SRV-01-DC

SRV-01-DC är domänkontrollant för `sost.local` med DNS och DHCP. Konfigurationen följer teamets driftdokumentation i repot infra-sstab: OU-strukturen, behörighetsmatrisen, minsta rättighet och lösenordspolicyn. Avvikelser från den står i [Avvikelser från teamets dokumentation](#avvikelser-från-teamets-dokumentation).

**Förutsättningar:** SRV-01-DC skapad och steg 1 kört enligt [01 Miljön på Proxmox](01-miljon-pa-proxmox.md).

## Steg

Skripten ligger i `skript/windows/`, sparas som UTF-8 med BOM (annars blir å, ä och ö fel i Windows PowerShell 5.1) och tål att köras om. De kopieras till servern och körs över SSH från adminklienten:

```powershell
scp skript\windows\*.ps1 Administrator@10.10.70.125:C:/sstab-skript/
ssh Administrator@10.10.70.125 "powershell -NoProfile -ExecutionPolicy Bypass -File C:\sstab-skript\<skript>.ps1 <parametrar>"
```

Lösenord ges som parametrar och finns aldrig i skripten.

| Steg | Skript | Gör |
|---|---|---|
| 1 | `01-grund.ps1` | Nätverkskort, fast adress, tidszon, datornamn |
| 2 | `02-domankontrollant.ps1` | Rollerna AD DS, DNS, DHCP, Windows Server Backup och GPMC. Ny skog `sost.local`, NetBIOS `SOST`, funktionsnivå Windows Server 2025 |
| 3 | `03-ad-struktur.ps1` | OU:er, grupper, testanvändare, adminkonto, tjänstekonto, delegering till IT |
| 4 | `04-fildelning.ps1` | `C:\Fildelning` med NTFS-behörigheter, SMB-delningar och testfiler |
| 5 | `05-dns-och-dhcp.ps1` | DNS och DHCP bara i produktionsnätet, DHCP-pool för klienter |
| 6 | `06-gpo-minsta-rattighet.ps1` | GPO:n `CIS - Least Privilege DC` |
| 7 | `07-losenordspolicy.ps1` | Default Domain Policy och en PSO per avdelning |

### Steg 2: domänkontrollant

```powershell
.\02-domankontrollant.ps1 -DsrmLosenord '...'
```

Det lokala kontot Administrator blir domänens Administrator. Efter kloning från mallen har det tomt lösenord, och då stoppar förkontrollen befordran:

```text
The new domain cannot be created because the local Administrator account password does not meet requirements.
Currently, the local Administrator password is blank
```

Sätt ett starkt lösenord med `net user Administrator '...'` innan steg 2. Efter omstarten:

```text
sost\administrator
DomainRole 5    (primär domänkontrollant)
NTDS, DNS, Netlogon, DHCPServer: Running
Windows2025Forest, Windows2025Domain
```

### Steg 3: AD-strukturen

```powershell
.\03-ad-struktur.ps1 -TestLosenord '...' -AdmLosenord '...' -SvcBackupLosenord '...'
```

OU-struktur:

```text
SkamtSidoTransport
├── Användare
│   ├── HR, Ledning, Ekonomi, Lager, IT
├── Grupper
│   ├── Globala
│   └── DomanLokala
└── Datorer
Adminkonton
Tjänstekonton
```

Grupperna följer AGDLP: användare i globala grupper (`gg-`), globala grupper i domänlokala (`dl-`), och behörigheter bara på domänlokala grupper.

```text
Grupp           Medlemmar
-----           ---------
dl-ekonomi-rw   gg-ekonomi
dl-gemensamt-ro gg-anstallda
dl-hr-rw        gg-hr
dl-it-rw        gg-it
dl-lager-rw     gg-lager, gg-ekonomi
dl-ledning-rw   gg-ledning
gg-anstallda    gg-hr, gg-ledning, gg-ekonomi, gg-lager, gg-it
gg-ekonomi      Test Ekonomi
gg-hr           Test HR
gg-it           Test IT
gg-lager        Test Lager
gg-ledning      Test Ledning
```

| Konto | OU | Grupper | Syfte |
|---|---|---|---|
| `test-hr`, `test-ledning`, `test-ekonomi`, `test-lager`, `test-it` | Avdelningens OU | Avdelningens `gg-` | Testa behörigheterna |
| `adm-daniel` | Adminkonton | Domain Admins | Administration. Inte med i `gg-anstallda` |
| `svc-backup` | Tjänstekonton | Backup Operators | Windows Server Backup och backupdelningen på SRV-02-LNX |

Adminkonton och tjänstekonton ligger utanför `SkamtSidoTransport`. Gruppen `gg-it` har delegerad rätt att skapa, ta bort och hantera användare i `SkamtSidoTransport`. Låg adminkontot där skulle IT kunna byta lösenord på ett administratörskonto.

### Steg 4: fildelning

```text
Delning             Smb
-------             ---
Ekonomi             SOST\dl-ekonomi-rw Change
Gemensamma dokument SOST\dl-gemensamt-ro Read
HR                  SOST\dl-hr-rw Change
IT                  SOST\dl-it-rw Change
Lager               SOST\dl-lager-rw Change
Ledning             SOST\dl-ledning-rw Change
```

NTFS på varje mapp: arvet brutet, `SYSTEM` och `Administrators` fullständig behörighet, `CREATOR OWNER` fullständig behörighet på det användaren själv skapar, och den domänlokala gruppen Modify (Read & execute för Gemensamma dokument). Delningarna har åtkomstbaserad uppräkning, så en användare ser bara mappar den har rätt till.

### Steg 5: DNS och DHCP

Servern har två nätverkskort, men DNS och DHCP ska bara finnas i produktionsnätet:

| Kontroll | Resultat |
|---|---|
| DNS lyssnar på | `192.168.50.10` |
| A-poster i `sost.local` | Bara `192.168.50.10` |
| Driftkortet registreras i DNS | Nej, `RegisterThisConnectionsAddress` är av |
| DHCP-bindning | Bara Produktion |
| DHCP-pool | 192.168.50.100 till 192.168.50.254, router 192.168.50.1, DNS 192.168.50.10 |

### Steg 6: minsta rättighet

GPO:n `CIS - Least Privilege DC` länkas till Domain Controllers med **länkordning 1**. Default Domain Controllers Policy är länkad till samma OU och sätter flera av samma rättigheter, och den GPO som har lägst länkordning vinner. Med vår GPO på plats 2 fick Authenticated Users fortfarande ansluta datorer och operatörsgrupperna logga in lokalt och stänga av servern.

Kontrollerat med `secedit /export /areas USER_RIGHTS`:

```text
SeMachineAccountPrivilege = *S-1-5-32-544
SeDebugPrivilege = *S-1-5-32-544
SeInteractiveLogonRight = *S-1-5-32-544,*S-1-5-9
SeShutdownPrivilege = *S-1-5-32-544
SeDenyInteractiveLogonRight = gg-anstallda,*S-1-5-32-546
SeRemoteInteractiveLogonRight = *S-1-5-32-544
SeDenyRemoteInteractiveLogonRight = gg-anstallda,*S-1-5-32-546
```

`S-1-5-32-544` är Administrators, `S-1-5-9` Enterprise Domain Controllers och `S-1-5-32-546` Guests.

### Steg 7: lösenordspolicy

Skriptet är teamets `Set-Losenordspolicy.ps1` med gruppnamnen ändrade till `gg-`. Kör först med `-WhatIf`.

```text
Name             Precedence MinPasswordLength LockoutThreshold MaxPasswordAge
----             ---------- ----------------- ---------------- --------------
Anställd Ledning         10                14                5 100.00:00:00
Anställd IT              20                14                5 100.00:00:00
Anställd Ekonomi         30                14                5 100.00:00:00
Anställd HR              40                14                5 100.00:00:00
Anställd Lager           50                14                5 100.00:00:00
```

Default Domain Policy: minst 14 tecken, 24 i historik, högst 100 dagar, utlåsning efter 5 försök i 30 minuter.

## Prov av behörigheterna

`skript/linux/02-testa-delningar.sh` provar delningarna som testanvändarna från SRV-02-LNX:

```text
OK   test-hr       HR                   skriv väntat ja  fick ja
OK   test-hr       Ekonomi              läs  väntat nej fick nej
OK   test-hr       Gemensamma dokument  läs  väntat ja  fick ja
OK   test-hr       Gemensamma dokument  skriv väntat nej fick nej
OK   test-ekonomi  Ekonomi              skriv väntat ja  fick ja
OK   test-ekonomi  Lager                skriv väntat ja  fick ja
OK   test-lager    Lager                skriv väntat ja  fick ja
OK   test-lager    Ekonomi              läs  väntat nej fick nej
OK   test-it       IT                   skriv väntat ja  fick ja
OK   test-it       Ledning              läs  väntat nej fick nej
OK   test-ledning  Ledning              skriv väntat ja  fick ja
OK   test-ledning  HR                   läs  väntat nej fick nej
slutkod 0
```

Under felsökningen blev `test-hr` utelåst efter fem misslyckade inloggningar, med `badPwdCount 5` och PSO:n `Anställd HR` som gällande policy. Det visar att utlåsningen fungerar. Kontot låstes upp med `Unlock-ADAccount test-hr`.

## Avvikelser från teamets dokumentation

| Teamets dokument | Står där | Gjort här | Varför |
|---|---|---|---|
| `OU.md` | `chaslab.local` på flera ställen | `sost.local` | README och IP-planen säger `sost.local` |
| `OU.md` | Både `gg-anstallda` och `gg-anställda` | `gg-anstallda` | Ett namn, utan å ä ö i gruppnamn |
| `OU.md` | `dl-lager-rw` innehåller bara `gg-lager` | Även `gg-ekonomi` | Behörighetsmatrisen ger Ekonomi RW på Lager |
| `OU.md` | Användare läggs direkt i `gg-anstallda` | Avdelningsgrupperna ligger i `gg-anstallda` | Nya anställda behöver bara en grupp |
| `least-privilege.md`, `losenordspolicy.md` | Grupperna `Ledning`, `IT`, `Anställda` och så vidare | `gg-ledning`, `gg-it`, `gg-anstallda` | Samma grupper som i `OU.md`, inga dubbletter |
| `least-privilege.md` | GPO:n länkas till Domain Controllers | Länkordning 1 | Annars vinner Default Domain Controllers Policy, se steg 6 |
| `002.md` | DNS `127.0.0.1` och `1.1.1.1` | `192.168.50.10` på båda korten | DNS lyssnar bara i produktionsnätet. En extern DNS som andra server gör att AD-uppslag kan gå fel |
| `least-privilege.md` | `adm-<namn>` i Administrators | `adm-daniel` i Domain Admins, i egen OU | Domain Admins ingår i Administrators. Egen OU utanför IT:s delegering |
