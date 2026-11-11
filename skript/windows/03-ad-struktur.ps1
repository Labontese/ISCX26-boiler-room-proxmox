# 03-ad-struktur.ps1
# Steg 3: OU:er, säkerhetsgrupper och användare enligt docs/reference/OU.md,
# behörighetsmatrisen i docs/reference/acl/acc-plan.md och minsta rättighet
# enligt docs/reference/least-privilege.md. Tål att köras om.
#
#   .\03-ad-struktur.ps1 -TestLosenord '...' -AdmLosenord '...' -SvcBackupLosenord '...'
param(
    [Parameter(Mandatory)][string]$TestLosenord,
    [Parameter(Mandatory)][string]$AdmLosenord,
    [Parameter(Mandatory)][string]$SvcBackupLosenord
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$dn   = (Get-ADDomain).DistinguishedName      # DC=sost,DC=local
$bas  = "OU=SkamtSidoTransport,$dn"
$avd  = 'HR', 'Ledning', 'Ekonomi', 'Lager', 'IT'

function Ny-OU([string]$Namn, [string]$Under) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Namn'" -SearchBase $Under -SearchScope OneLevel)) {
        New-ADOrganizationalUnit -Name $Namn -Path $Under -ProtectedFromAccidentalDeletion $true
    }
}
function Ny-Grupp([string]$Namn, [string]$Scope, [string]$Under, [string]$Beskrivning) {
    if (-not (Get-ADGroup -Filter "Name -eq '$Namn'")) {
        New-ADGroup -Name $Namn -GroupScope $Scope -GroupCategory Security -Path $Under -Description $Beskrivning
    }
}
function Ny-Anvandare([string]$Sam, [string]$Namn, [string]$Under, [string]$Losenord) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Sam'")) {
        New-ADUser -SamAccountName $Sam -UserPrincipalName "$Sam@sost.local" -Name $Namn `
            -DisplayName $Namn -Path $Under -Enabled $true `
            -AccountPassword (ConvertTo-SecureString $Losenord -AsPlainText -Force)
    }
}

# --- OU-struktur (OU.md steg 2) --------------------------------------------
Ny-OU 'SkamtSidoTransport' $dn
Ny-OU 'Användare' $bas
Ny-OU 'Grupper'   $bas
Ny-OU 'Datorer'   $bas
foreach ($a in $avd) { Ny-OU $a "OU=Användare,$bas" }
Ny-OU 'Globala'     "OU=Grupper,$bas"
Ny-OU 'DomanLokala' "OU=Grupper,$bas"

# Adminkonton och tjänstekonton ligger utanför SkamtSidoTransport. Där har
# gruppen gg-it delegerad rätt att hantera användare, och IT ska inte kunna
# byta lösenord på ett administratörskonto.
Ny-OU 'Adminkonton'  $dn
Ny-OU 'Tjänstekonton' $dn

# --- Globala grupper (OU.md steg 5) ---------------------------------------
$glob = "OU=Globala,OU=Grupper,$bas"
foreach ($a in $avd) { Ny-Grupp "gg-$($a.ToLower())" Global $glob "Personal på $a" }
Ny-Grupp 'gg-anstallda' Global $glob 'Samtliga anställda'

# --- Domänlokala grupper (OU.md steg 6) -----------------------------------
$dl = "OU=DomanLokala,OU=Grupper,$bas"
foreach ($a in $avd) { Ny-Grupp "dl-$($a.ToLower())-rw" DomainLocal $dl "Läsa och skriva i $a" }
Ny-Grupp 'dl-gemensamt-ro' DomainLocal $dl 'Läsa i Gemensamma dokument'

# --- Kopplingar (OU.md steg 8, acc-plan.md) --------------------------------
foreach ($a in $avd) {
    Add-ADGroupMember "dl-$($a.ToLower())-rw" -Members "gg-$($a.ToLower())"
    Add-ADGroupMember 'gg-anstallda' -Members "gg-$($a.ToLower())"
}
# Behörighetsmatrisen: Ekonomi får läsa och skriva i Lager.
Add-ADGroupMember 'dl-lager-rw' -Members 'gg-ekonomi'
Add-ADGroupMember 'dl-gemensamt-ro' -Members 'gg-anstallda'

# --- Testanvändare, en per avdelning (OU.md steg 3 och 7) -------------------
foreach ($a in $avd) {
    $sam = "test-$($a.ToLower())"
    Ny-Anvandare $sam "Test $a" "OU=$a,OU=Användare,$bas" $TestLosenord
    Add-ADGroupMember "gg-$($a.ToLower())" -Members $sam
}

# --- Adminkonto (least-privilege.md steg 4) ---------------------------------
Ny-Anvandare 'adm-daniel' 'Admin Daniel' "OU=Adminkonton,$dn" $AdmLosenord
Add-ADGroupMember 'Domain Admins' -Members 'adm-daniel'

# --- Tjänstekonto för Windows Server Backup --------------------------------
# Backup Operators räcker för att ta och återställa backup. Kontot används
# också mot backupdelningen på SRV-02-LNX.
Ny-Anvandare 'svc-backup' 'Tjänstekonto backup' "OU=Tjänstekonton,$dn" $SvcBackupLosenord
Add-ADGroupMember 'Backup Operators' -Members 'svc-backup'
Set-ADUser 'svc-backup' -PasswordNeverExpires $true -CannotChangePassword $true `
    -Description 'Windows Server Backup till \\192.168.50.50\backup'

# --- Delegering till IT (least-privilege.md steg 5) --------------------------
# Samma rättigheter som guiden Delegate Control ger för "Create, delete, and
# manage user accounts" och "Reset user passwords and force password change".
$ou = "OU=SkamtSidoTransport,$dn"
dsacls $ou /I:T /G "SOST\gg-it:CCDC;user"      | Out-Null
dsacls $ou /I:S /G "SOST\gg-it:GA;;user"       | Out-Null

Get-ADGroup -Filter "Name -like 'gg-*' -or Name -like 'dl-*'" -SearchBase $bas |
    ForEach-Object { [pscustomobject]@{
        Grupp = $_.Name
        Medlemmar = ((Get-ADGroupMember $_ | Select-Object -ExpandProperty Name) -join ', ') } } |
    Sort-Object Grupp | Format-Table -AutoSize
