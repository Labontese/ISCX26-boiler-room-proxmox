# 09-aterstallningsprov.ps1
# Återställningsprov: en avdelningsmapp raderas och återställs från den senaste
# backupen på \\192.168.50.50\backup. Innehåll och NTFS-behörigheter jämförs
# före och efter, och tiden mäts.
#
# Lösenordet för svc-backup läses från standard in, så att det aldrig står på
# kommandoraden eller i en felutskrift:
#   Get-Content svc-backup.txt | ssh Administrator@SRV-01-DC "powershell -File C:\sstab-skript\09-aterstallningsprov.ps1"
param([string]$Mapp = 'C:\Fildelning\HR')
$ErrorActionPreference = 'Stop'
$mal  = '\\192.168.50.50\backup'
$prov = 'C:\Aterstallningsprov'
New-Item -ItemType Directory -Path $prov -Force | Out-Null

# PowerShell lägger en BOM först när text pipas till ssh. Standard in läses
# annars med konsolens gamla teckentabell, och då blir BOM:en tre skräptecken.
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$losen = [Console]::In.ReadLine().TrimStart([char]0xFEFF).Trim()
if ($losen -notmatch '^[\x21-\x7E]+$') { throw 'Lösenordet innehåller oväntade tecken efter inläsningen.' }

function Anslut([string]$Anvandare) {
    # net.exe skriver fel till stderr. Med Stop skulle PowerShell 5.1 avbryta
    # skriptet i stället för att låta nästa försök köras.
    $ErrorActionPreference = 'Continue'
    net use $mal /user:$Anvandare $losen 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

# 1. Läget före: kontrollsummor och NTFS-behörigheter. Om mappen redan är
#    raderad av en tidigare körning används det sparade läget.
if (Test-Path $Mapp) {
    Get-ChildItem $Mapp -Recurse -File | Get-FileHash -Algorithm SHA256 |
        ForEach-Object { "$($_.Hash)  $($_.Path)" } | Set-Content "$prov\fore.sha256"
    icacls $Mapp /save "$prov\fore.acl" /t /q | Out-Null
    "Före: $((Get-Content "$prov\fore.sha256").Count) filer"

    # 2. Incidenten: mappen raderas.
    Remove-Item $Mapp -Recurse -Force
} else {
    "Mappen saknas redan, sparat läge från $((Get-Item "$prov\fore.sha256").LastWriteTime) används"
}
"Raderad: $Mapp finns = $(Test-Path $Mapp)"

# 3. Anslut till backupdelningen och hitta senaste versionen.
$start = Get-Date
if (Anslut 'svc-backup@sost.local') { 'Ansluten som svc-backup@sost.local' }
elseif (Anslut 'SOST\svc-backup') { 'UPN nekades av Samba, ansluten som SOST\svc-backup' }
else { throw "Kunde inte ansluta till $mal" }
$versioner = wbadmin get versions "-backupTarget:$mal" -machine:SRV-01-DC
$version = ($versioner | Select-String 'Version identifier: (.+)$' | Select-Object -Last 1).Matches[0].Groups[1].Value.Trim()
"Version: $version"

# 4. Återställ till ursprunglig plats, med NTFS-behörigheter (standard).
wbadmin start recovery "-version:$version" -itemType:File "-items:$Mapp" -recursive `
    "-backupTarget:$mal" -machine:SRV-01-DC -overwrite:Overwrite -quiet | Select-Object -Last 3
$tid = (Get-Date) - $start
net use $mal /delete 2>&1 | Out-Null

# 5. Jämför efter.
Get-ChildItem $Mapp -Recurse -File | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash)  $($_.Path)" } | Set-Content "$prov\efter.sha256"
icacls $Mapp /save "$prov\efter.acl" /t /q | Out-Null
$innehall = Compare-Object (Get-Content "$prov\fore.sha256") (Get-Content "$prov\efter.sha256")
$rattigheter = Compare-Object (Get-Content "$prov\fore.acl") (Get-Content "$prov\efter.acl")

"Efter: $((Get-Content "$prov\efter.sha256").Count) filer"
"Innehåll lika: $(-not $innehall)"
"NTFS-behörigheter lika: $(-not $rattigheter)"
"Tid för återställningen: $([int]$tid.TotalSeconds) sekunder"
icacls $Mapp
if ($innehall -or $rattigheter) { exit 1 }
