# Guide: det som saknas i infra-sstab

Arbetslista för teamets officiella repo `infra-sstab`, jämfört med uppgiften Boiler Room (delarna A till E) och kursmålen 7 till 13, 15 och 16. Läget gäller `main` den 11 november 2026 (senaste sammanslagning PR #22).

Gå igenom punkterna i ordning. Skriv in vem som tar varje punkt i kolumnen **Ansvarig**, och bocka av först när **Klart när** är uppfyllt och PR:en är granskad.

## Läget i korthet

| Del | Kursmål | Status i `main` |
|---|---|---|
| A Linux: webbserver och fildelning | 7 | Installation och nginx finns i `tutorials/001.md`. Samba bara installerad, inte konfigurerad. Felsökning saknas |
| A Windows Server med AD DS | 9 | Finns i `tutorials/002.md` |
| B Behörighetsstruktur och fildelning | 8 | Finns i `OU.md`, `Fildelning.md`, `acc-plan.md`, `least-privilege.md`. Motsägelser mellan dokumenten |
| C Härdning | 11 | Lösenordspolicy och minsta rättighet finns. `hardeingguide.md` är tom |
| D Backup och återställning | 10 | Saknas helt |
| E AI | 13 | Saknas helt |
| Dokumentation som en annan tekniker kan ta över | 12 | Struktur enligt Diátaxis finns. `explanation/` är tom |
| Git: PR med dokumenterad granskning | 15 | 19 av 20 sammanslagna PR:er saknar granskning |
| Motivera tekniska val | 16 | Saknas, hör ihop med `explanation/` |

## 1. Granskning av varje PR (mål 15)

Uppgiften kräver att sammanslagning till `main` bara sker via PR med **genomförd och dokumenterad** granskning. Av PR #3 till #22 har bara #21 en granskning i GitHub. Resten är sammanslagna utan att något syns i PR:en. Det går inte att rätta i efterhand, men från och med nu ska varje PR ha det.

| Gör | Ansvarig | Klart när |
|---|---|---|
| Granska med `gh pr review <nr> --approve -b "Läst X och Y, provat Z. Ser bra ut."` eller begär ändringar med `--request-changes -b "..."` | Alla | Varje ny PR har en granskning från någon annan än författaren innan den slås ihop |
| Skriv in regeln i `how-to/git-arbetssatt.md`: ingen slår ihop utan granskning i GitHub | | Regeln står i dokumentet |
| Nämn i slutdokumentationen att granskningen inte dokumenterades i PR #3 till #20 och när det ändrades | | Står i förklaringen om arbetssättet |

En granskning ska säga vad som är kontrollerat, inte bara "LGTM". Exempel: "Följde steg 1 till 4 i min egen VM, fick samma utskrift. Länken till ip-plan.md fungerar."

## 2. Backup och återställning (del D, mål 10)

Saknas helt. Uppgiften: planera, genomföra och verifiera backup och återställning av kritiska konfigurationsfiler och data enligt en rutin. Dagens moment: Windows Server Backup med schema, backuperna sparade på Ubuntu-filservern via Samba.

| Gör | Ansvarig | Klart när |
|---|---|---|
| Samba-delning för backup på SRV-02-LNX: eget konto, bara SRV-01-DC får ansluta, SMB3 | | `reference/` beskriver delningen, brandväggen och kontot |
| Tjänstekonto för backup i AD, medlem i Backup Operators, inte Domain Admins | | Kontot finns i `OU.md` eller eget referensdokument |
| Schemalagd backup med Windows Server Backup: System State, `C:\Fildelning`, DHCP | | Schemat och vad som ingår står i rutinen |
| Rutin enligt övning 2 del 5: hur backup tas, filnamn, var den sparas, ansvarig avdelning, hur ofta den kontrolleras, var dokumentationen finns | | `how-to/backup-och-aterstallning.md` |
| Återställningsinstruktion i 3 till 5 steg | | Står i rutinen |
| Återställningsprov: radera en mapp, återställ, jämför innehåll och NTFS-rättigheter, mät tiden | | Protokoll med datum, utskrifter och uppmätt RTO |

Backupmålet finns uppbyggt i det här repot, se [02 Backupmålet SRV-02-LNX](02-backupmal-srv-02-lnx.md). Använd det som exempel, men dokumentera teamets egen miljö.

Tänk på: Windows Server Backup sparar bara **en** version på en nätverksdelning och skriver över den förra varje gång ([Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wbadmin-enable-backup)). Rutinen måste säga hur äldre versioner sparas.

## 3. Härdning (del C, mål 11)

`docs/hardeingguide.md` är tom, och filnamnet är felstavat. Lösenordspolicy och minsta rättighet finns redan och ska länkas, inte skrivas om.

| Gör | Ansvarig | Klart när |
|---|---|---|
| Byt namn till `docs/how-to/hardning.md` och uppdatera länken i README | | Filen ligger rätt och länken fungerar |
| Checklista för Windows: lösenordspolicy och minsta rättighet (länka), brandväggen per profil, SMB1 avstängt, onödiga roller och tjänster, RDP med NLA | | Varje punkt har kommando, utskrift före och efter |
| Checklista för Linux: SSH utan lösenord och root, UFW med bara nödvändiga portar, onödiga tjänster avstängda, Lynis före och efter | | Lynis hardening index före och efter står med |
| Koppla varje punkt till CIS-numret, som `losenordspolicy.md` redan gör | | CIS-nummer i varje rad |

## 4. Linux: fildelning och felsökning (del A och B, mål 7 och 8)

| Gör | Ansvarig | Klart när |
|---|---|---|
| Bestäm vad SRV-02-LNX är. README och IP-planen säger "bara backup", uppgiften säger webbserver och fildelning | | Samma svar i README, IP-planen och `001.md` |
| Samba-konfigurationen i `acc-plan.md` är ett utkast. Antingen genomför och prova den, eller ta bort den | | `smb.conf` provad med en användare som får och en som nekas |
| `001.md`: förutsättningen säger Ubuntu **Desktop**-ISO för en server, och netplan-exemplet är för VirtualBox | | Rätt ISO och en kommentar om vad som ska bytas i annan miljö |
| Avsnitt om systematisk felsökning: ett verkligt problem, hypotes, kommando, utskrift, slutsats | | Minst ett felsökningsfall dokumenterat (mål 7 kräver det) |

## 5. AI-användning (del E, mål 13)

Uppgiften kräver att varje AI-förslag verifieras mot eget test, och att felaktiga förslag dokumenteras.

| Gör | Ansvarig | Klart när |
|---|---|---|
| `explanation/ai-anvandning.md`: vilket verktyg, till vad, och hur det verifierades | | Dokumentet finns |
| Logga minst några fall där AI hade fel, med förslaget, testet som visade felet och vad som gjordes i stället | | Varje fall har test och resultat |

Exempel från härdningsövningen med Lynis, att använda som mönster: ett AI-skrivet `grep` mot `sshd -T` hittade inget eftersom OpenSSH 10.5 skriver `PermitRootLogin`, inte `permitrootlogin`. Felet syntes först när kommandot kördes.

## 6. Motsägelser i dokumentationen (mål 12)

En annan tekniker ska kunna ta över utan frågor. Det går inte när dokumenten säger olika saker.

| Dokument | Problem | Förslag |
|---|---|---|
| `OU.md`, `Fildelning.md` | `chaslab.local` på flera ställen | Byt till `sost.local` |
| `OU.md` | Både `gg-anstallda` och `gg-anställda` | Välj ett, gärna utan å ä ö |
| `OU.md`, `acc-plan.md` | `dl-lager-rw` innehåller bara `gg-lager`, men matrisen ger Ekonomi RW på Lager | Lägg till `gg-ekonomi` i `dl-lager-rw` |
| `least-privilege.md`, `losenordspolicy.md` | Grupperna heter `Ledning`, `IT`, `Anställda`, i `OU.md` `gg-ledning`, `gg-it`, `gg-anstallda` | Använd `OU.md`:s namn överallt |
| `least-privilege.md` | GPO:n länkas till Domain Controllers utan länkordning. Då vinner Default Domain Controllers Policy för flera rättigheter | Lägg till: sätt länkordning 1, kontrollera med `secedit /export /areas USER_RIGHTS` |
| `least-privilege.md` | "Vilken server är inte bestämt än" om fildelningen | `Fildelning.md` säger SRV-01-DC, skriv det |
| `002.md` | DNS `127.0.0.1` och `1.1.1.1` som andra server | En extern DNS på en domänkontrollant kan ge fel AD-uppslag. Ta bort `1.1.1.1` |
| `Fildelning.md` | Klienten ansluts till en domän i en annan labbmiljö | Gör om provet i `sost.local` eller skriv att det är gjort i en annan miljö |
| Roten | `test.txt` är tom och oanvänd | Ta bort |
| `CHANGELOG.md` | Senaste raden är från 4 november, PR #21 och #22 saknas | Fyll i, och gör det i samma PR som ändringen |
| `incident-playbook.md` | Tom | Ta bort, eller skriv den som en del av D: vad som görs när en server är borta |

## 7. Motivera valen (mål 16)

`docs/explanation/` innehåller bara mallen. Mål 16 kräver att teamet kan motivera tekniska val, och muntliga valideringen frågar om dem.

| Gör | Ansvarig | Klart när |
|---|---|---|
| `explanation/behorighetsmodell.md`: varför AGDLP, varför domänlokala grupper på mapparna, varför Ekonomi får Lager | | Varje val har ett "därför" och ett alternativ som valdes bort |
| `explanation/segmentering.md`: varför produktion och management är separerade | | Kopplat till IP-planen |
| `explanation/backup.md`: varför backupen ligger på en annan server, RPO och RTO, retention | | Kopplat till rutinen i del D |

## Förslag på ordning

1. Punkt 1 direkt. Den kostar inget och gäller varje PR framåt.
2. Punkt 2 och 3, dagens moment, mål 10 och 11.
3. Punkt 6, eftersom flera av de andra dokumenten bygger på samma namn.
4. Punkt 4, 5 och 7.

Varje punkt blir en egen gren och en egen PR, så att varje persons bidrag syns i historiken.
