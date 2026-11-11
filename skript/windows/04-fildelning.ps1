# 04-fildelning.ps1
# Steg 4: C:\Fildelning med NTFS-behörigheter och SMB-delningar enligt
# docs/reference/Fildelning.md, plus testfiler. Tål att köras om.
$ErrorActionPreference = 'Stop'

$rot = 'C:\Fildelning'
$mappar = [ordered]@{
    'HR'                  = @{ Grupp = 'dl-hr-rw';        Ntfs = 'M';  Smb = 'Change' }
    'Ledning'             = @{ Grupp = 'dl-ledning-rw';   Ntfs = 'M';  Smb = 'Change' }
    'Ekonomi'             = @{ Grupp = 'dl-ekonomi-rw';   Ntfs = 'M';  Smb = 'Change' }
    'Lager'               = @{ Grupp = 'dl-lager-rw';     Ntfs = 'M';  Smb = 'Change' }
    'IT'                  = @{ Grupp = 'dl-it-rw';        Ntfs = 'M';  Smb = 'Change' }
    'Gemensamma dokument' = @{ Grupp = 'dl-gemensamt-ro'; Ntfs = 'RX'; Smb = 'Read' }
}

New-Item -ItemType Directory -Path $rot -Force | Out-Null

foreach ($namn in $mappar.Keys) {
    $m = $mappar[$namn]
    $mappen = Join-Path $rot $namn
    New-Item -ItemType Directory -Path $mappen -Force | Out-Null

    # NTFS (Fildelning.md steg 2): bryt arvet, ta bort Users, behåll SYSTEM,
    # Administrators och CREATOR OWNER, ge den domänlokala gruppen rätt.
    icacls $mappen /inheritance:r | Out-Null
    icacls $mappen /grant:r 'SYSTEM:(OI)(CI)F' | Out-Null
    icacls $mappen /grant:r 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
    icacls $mappen /grant:r 'CREATOR OWNER:(OI)(CI)(IO)F' | Out-Null
    icacls $mappen /grant:r "SOST\$($m.Grupp):(OI)(CI)$($m.Ntfs)" | Out-Null

    # SMB (Fildelning.md steg 3): bara den domänlokala gruppen, inte Everyone.
    if (-not (Get-SmbShare -Name $namn -ErrorAction SilentlyContinue)) {
        if ($m.Smb -eq 'Change') {
            New-SmbShare -Name $namn -Path $mappen -ChangeAccess "SOST\$($m.Grupp)" -FolderEnumerationMode AccessBased | Out-Null
        } else {
            New-SmbShare -Name $namn -Path $mappen -ReadAccess "SOST\$($m.Grupp)" -FolderEnumerationMode AccessBased | Out-Null
        }
    }
}

# Testfiler, så att backup och återställning gäller verkliga filer.
$testfiler = @{
    'HR\personalregister.csv'                    = "Namn;Avdelning;Anställd`nTest HR;HR;2026-10-01"
    'Ledning\styrelseprotokoll-2026-11.txt'      = 'Protokoll från styrelsemötet i november.'
    'Ekonomi\budget-2027.csv'                    = "Konto;Belopp`nIT;450000`nLager;1200000"
    'Lager\lagersaldo.csv'                       = "Artikel;Antal`nPall EUR;340`nSträckfilm;55"
    'IT\driftlogg.txt'                           = 'Driftlogg för SRV-01-DC och SRV-02-LNX.'
    'Gemensamma dokument\personalhandbok.txt'    = 'Personalhandbok för Skämt & Sido Transport AB.'
}
foreach ($f in $testfiler.Keys) {
    $p = Join-Path $rot $f
    if (-not (Test-Path $p)) { Set-Content -Path $p -Value $testfiler[$f] -Encoding UTF8 }
}

Get-SmbShare | Where-Object Path -like "$rot*" | ForEach-Object {
    [pscustomobject]@{
        Delning = $_.Name
        Smb     = ((Get-SmbShareAccess $_.Name | ForEach-Object { "$($_.AccountName) $($_.AccessRight)" }) -join ', ')
    } } | Format-Table -AutoSize
