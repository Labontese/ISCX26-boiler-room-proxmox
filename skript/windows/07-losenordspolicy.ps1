#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory, GroupPolicy

<#
.SYNOPSIS
    Sätter lösenords- och utlåsningspolicy i sost.local enligt CIS Microsoft Windows
    Server 2025 Benchmark v2.1.0, kapitel 1 "Account Policies".

.DESCRIPTION
    Skriptet gör tre saker:

    1. Default Domain Policy (GPO). Värdena skrivs in i GPO:ns säkerhetsmall
       (GptTmpl.inf i SYSVOL) och GPO:ns version räknas upp. Det går inte att använda
       Set-ADDefaultDomainPasswordPolicy, eftersom domänkontrollanten skriver över de
       värdena med GPO:ns värden vid nästa uppdatering av grupprinciperna.
       En backup av GPO:n tas innan något ändras.

    2. En PSO (Fine-Grained Password Policy) per avdelning, kopplad till avdelningens
       säkerhetsgrupp. Finns PSO:n redan uppdateras den i stället för att skapas.

    3. Kontroll. Allt läses tillbaka och jämförs med värdena nedan. Skriptet avslutas
       med felkod 1 om något inte stämmer.

    Kör först med -WhatIf för att se vad som skulle ändras.
    Se även docs/reference/losenordspolicy.md.

.PARAMETER SkipDefaultDomainPolicy
    Ändra inte Default Domain Policy, bara PSO:erna.

.PARAMETER SkipPso
    Ändra inte PSO:erna, bara Default Domain Policy.

.PARAMETER BackupPath
    Mapp där backupen av Default Domain Policy sparas.

.PARAMETER PolicyRoot
    Sökväg till mappen Policies i SYSVOL. Standard är \\<domän>\SYSVOL\<domän>\Policies.

.EXAMPLE
    .\Set-Losenordspolicy.ps1 -WhatIf
    Visar vad som skulle ändras utan att ändra något.

.EXAMPLE
    .\Set-Losenordspolicy.ps1
    Sätter policyn och kontrollerar resultatet.

.NOTES
    Körs som domänadministratör på domänkontrollanten SRV-01-DC i Windows PowerShell 5.1.
    Filen måste sparas som UTF-8 med BOM, annars blir "Anställd" fel i PowerShell 5.1.
    Återställ Default Domain Policy vid behov med Restore-GPO och backupen i BackupPath.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipDefaultDomainPolicy,
    [switch]$SkipPso,
    [string]$BackupPath = (Join-Path $env:SystemDrive 'GPO-Backup'),
    [string]$PolicyRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Inställningar
# ---------------------------------------------------------------------------

# Samma värden används för Default Domain Policy och alla PSO:er.
# CIS-numret står efter varje värde; kravet i CIS står inom parentes.
$Policy = [ordered]@{
    PasswordHistoryCount            = 24      # CIS 1.1.1 (24 eller fler)
    MaxPasswordAgeDays              = 100     # CIS 1.1.2 (365 eller färre, inte 0)
    MinPasswordAgeDays              = 1       # CIS 1.1.3 (1 eller mer)
    MinPasswordLength               = 14      # CIS 1.1.4 (14 eller fler)
    ComplexityEnabled               = $true   # CIS 1.1.5 (Enabled)
    ReversibleEncryptionEnabled     = $false  # CIS 1.1.7 (Disabled)
    LockoutDurationMinutes          = 30      # CIS 1.2.1 (15 eller fler)
    LockoutThreshold                = 5       # CIS 1.2.2 (5 eller färre, inte 0)
    LockoutObservationWindowMinutes = 15      # CIS 1.2.4 (15 eller fler)
}

# En PSO per avdelning. Lägst precedence vinner om en användare finns i flera grupper.
# Värdena följer tabellen "Precedence per avdelning" i losenordspolicy.md.
$PsoList = @(
    @{ Name = 'Anställd Ledning'; Group = 'gg-ledning'; Precedence = 10 }
    @{ Name = 'Anställd IT';      Group = 'gg-it';   Precedence = 20 }
    @{ Name = 'Anställd Ekonomi'; Group = 'gg-ekonomi'; Precedence = 30 }
    @{ Name = 'Anställd HR';      Group = 'gg-hr';   Precedence = 40 }
    @{ Name = 'Anställd Lager';   Group = 'gg-lager'; Precedence = 50 }
)

# Default Domain Policy har samma GUID i alla domäner.
$DefaultDomainPolicyGuid = '31B2F340-016D-11D2-945F-00C04FB984F9'

# Säkerhetsinställningarnas klienttillägg (CSE). Det måste vara registrerat på GPO:n,
# annars läser datorerna aldrig GptTmpl.inf.
$SecurityCseGuid = '827D319E-6EAC-11D2-A4EA-00C04F79F83A'

# Nycklarna i [System Access] i GptTmpl.inf. Åldrar i dagar, utlåsningstider i minuter.
$SystemAccess = [ordered]@{
    MinimumPasswordAge    = $Policy.MinPasswordAgeDays
    MaximumPasswordAge    = $Policy.MaxPasswordAgeDays
    MinimumPasswordLength = $Policy.MinPasswordLength
    PasswordComplexity    = [int]$Policy.ComplexityEnabled
    PasswordHistorySize   = $Policy.PasswordHistoryCount
    ClearTextPassword     = [int]$Policy.ReversibleEncryptionEnabled
    LockoutBadCount       = $Policy.LockoutThreshold
    ResetLockoutCount     = $Policy.LockoutObservationWindowMinutes
    LockoutDuration       = $Policy.LockoutDurationMinutes
}

# ---------------------------------------------------------------------------
# Hjälpfunktioner
# ---------------------------------------------------------------------------

function Read-TextFile {
    # Läser en textfil och tar reda på kodningen från BOM, så att filen kan skrivas
    # tillbaka i samma kodning.
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $isUtf16Le = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE
    if ($isUtf16Le) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true)
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true)
    }
    else {
        $encoding = [System.Text.Encoding]::Default
    }

    @{
        Text      = [System.IO.File]::ReadAllText($Path, $encoding)
        Encoding  = $encoding
        IsUtf16Le = $isUtf16Le
    }
}

function Split-Lines {
    # Delar en text i rader. Den sista tomma raden efter avslutande radbrytning tas bort.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = $Text -split "`r?`n"
    if ($lines.Count -gt 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    , $lines
}

function Set-InfSectionValue {
    # Sätter nycklar i en sektion i en INF-fil och returnerar de nya raderna.
    # Befintliga nycklar skrivs över, dubbletter av dem tas bort, saknade nycklar läggs
    # sist i sektionen och saknas sektionen läggs den till sist i filen.
    # Övriga rader lämnas orörda.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )

    $result = New-Object System.Collections.Generic.List[string]
    $remaining = [ordered]@{}
    foreach ($key in $Values.Keys) { $remaining[$key] = $Values[$key] }

    $sectionHeader = '[' + $Section + ']'
    $inSection = $false
    $sectionFound = $false

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
            # En ny sektion börjar. Lämnar vi målsektionen läggs saknade nycklar till först.
            if ($inSection) {
                foreach ($key in $remaining.Keys) { $result.Add("$key = $($remaining[$key])") }
                $remaining.Clear()
            }
            $inSection = ($trimmed -eq $sectionHeader)
            if ($inSection) { $sectionFound = $true }
            $result.Add($line)
            continue
        }

        if ($inSection -and $trimmed -match '^([^=;]+?)\s*=') {
            $key = $Matches[1].Trim()
            # Jämförelsen är skiftlägesokänslig, som i Windows.
            $managed = @($Values.Keys | Where-Object { $_ -eq $key }) | Select-Object -First 1
            if ($managed) {
                if ($remaining.Contains($managed)) {
                    $result.Add("$managed = $($remaining[$managed])")
                    $remaining.Remove($managed)
                }
                # En andra förekomst av samma nyckel tas bort, så att det inte finns
                # två motstridiga värden.
                continue
            }
        }

        $result.Add($line)
    }

    if ($inSection) {
        # Målsektionen var sist i filen.
        foreach ($key in $remaining.Keys) { $result.Add("$key = $($remaining[$key])") }
    }
    elseif (-not $sectionFound) {
        $result.Add($sectionHeader)
        foreach ($key in $remaining.Keys) { $result.Add("$key = $($remaining[$key])") }
    }

    , $result.ToArray()
}

function Get-InfSectionValue {
    # Läser nycklarna i en sektion i en INF-fil som en hashtabell (nyckel -> text).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section
    )

    $values = @{}
    $inSection = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
            $inSection = ($trimmed -eq "[$Section]")
            continue
        }
        if ($inSection -and $trimmed -match '^([^=;]+?)\s*=\s*(.*)$') {
            $values[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    $values
}

function Get-GptIniVersion {
    # Läser Version under [General] i GPT.INI. Stoppar om sektionen eller nyckeln saknas,
    # finns flera gånger eller inte är ett giltigt tal, i stället för att gissa.
    param([Parameter(Mandatory)][string]$Text)

    $sections = 0
    $values = @()
    $inGeneral = $false
    foreach ($line in (Split-Lines $Text)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
            $inGeneral = ($trimmed -eq '[General]')
            if ($inGeneral) { $sections++ }
            continue
        }
        if ($inGeneral -and $trimmed -match '^Version\s*=\s*(.*)$') { $values += $Matches[1].Trim() }
    }
    if ($sections -ne 1) { throw "GPT.INI har $sections [General]-sektioner, ska ha 1." }
    if ($values.Count -ne 1) { throw "GPT.INI har $($values.Count) Version-rader under [General], ska ha 1." }
    if ($values[0] -notmatch '^\d{1,10}$' -or [long]$values[0] -gt [uint32]::MaxValue) {
        throw "Versionen i GPT.INI är inte ett giltigt tal: '$($values[0])'."
    }
    [long]$values[0]
}

function Set-GptIniVersion {
    # Byter värdet på Version under [General] i GPT.INI och returnerar den nya texten.
    # Övriga rader och radbrytningar lämnas orörda.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][long]$Version
    )

    $inGeneral = $false
    $lines = foreach ($line in (Split-Lines $Text)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
            $inGeneral = ($trimmed -eq '[General]')
        }
        elseif ($inGeneral -and $trimmed -match '^(Version\s*=\s*)') {
            $line = $Matches[1] + $Version
        }
        $line
    }
    ($lines -join "`r`n") + "`r`n"
}

function Step-ComputerVersion {
    # GPO-versionen består av två delar: användarversionen i de höga 16 bitarna och
    # datorversionen i de låga. Säkerhetsinställningar är datorinställningar, så bara
    # den låga delen räknas upp. Användardelen lämnas orörd.
    param([Parameter(Mandatory)][long]$Version)

    $user = ($Version -shr 16) -band 0xFFFF
    $computer = ($Version -band 0xFFFF) + 1
    if ($computer -gt 0xFFFF) { $computer = 1 }
    ([long]$user -shl 16) -bor $computer
}

function ConvertFrom-AdVersion {
    # versionNumber lagras som ett 32-bitars heltal med tecken i AD. Gör om till
    # samma positiva tal som i GPT.INI.
    param([Parameter(Mandatory)][long]$Value)
    if ($Value -lt 0) { $Value + 4294967296 } else { $Value }
}

function ConvertTo-AdVersion {
    param([Parameter(Mandatory)][long]$Value)
    if ($Value -gt [int]::MaxValue) { [int]($Value - 4294967296) } else { [int]$Value }
}

function ConvertTo-PolicyState {
    # Gör om ett policyobjekt från AD (Default Domain Policy eller PSO) till samma
    # form som $Policy, så att de kan jämföras. Tiderna avrundas inte, så att till
    # exempel 100 dagar och 11 timmar inte räknas som 100 dagar.
    param([Parameter(Mandatory)]$PolicyObject)

    [ordered]@{
        PasswordHistoryCount            = [int]$PolicyObject.PasswordHistoryCount
        MaxPasswordAgeDays              = [double]$PolicyObject.MaxPasswordAge.TotalDays
        MinPasswordAgeDays              = [double]$PolicyObject.MinPasswordAge.TotalDays
        MinPasswordLength               = [int]$PolicyObject.MinPasswordLength
        ComplexityEnabled               = [bool]$PolicyObject.ComplexityEnabled
        ReversibleEncryptionEnabled     = [bool]$PolicyObject.ReversibleEncryptionEnabled
        LockoutDurationMinutes          = [double]$PolicyObject.LockoutDuration.TotalMinutes
        LockoutThreshold                = [int]$PolicyObject.LockoutThreshold
        LockoutObservationWindowMinutes = [double]$PolicyObject.LockoutObservationWindow.TotalMinutes
    }
}

function Compare-PolicyState {
    # Returnerar en text per värde som skiljer sig, eller ingenting om allt stämmer.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Expected,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Actual
    )

    foreach ($key in $Expected.Keys) {
        if ("$($Actual[$key])" -ne "$($Expected[$key])") {
            "$key är $($Actual[$key]), ska vara $($Expected[$key])"
        }
    }
}

function Get-PsoParameter {
    # Parametrar till New-/Set-ADFineGrainedPasswordPolicy utifrån $Policy.
    @{
        PasswordHistoryCount        = $Policy.PasswordHistoryCount
        MaxPasswordAge              = New-TimeSpan -Days $Policy.MaxPasswordAgeDays
        MinPasswordAge              = New-TimeSpan -Days $Policy.MinPasswordAgeDays
        MinPasswordLength           = $Policy.MinPasswordLength
        ComplexityEnabled           = $Policy.ComplexityEnabled
        ReversibleEncryptionEnabled = $Policy.ReversibleEncryptionEnabled
        LockoutDuration             = New-TimeSpan -Minutes $Policy.LockoutDurationMinutes
        LockoutThreshold            = $Policy.LockoutThreshold
        LockoutObservationWindow    = New-TimeSpan -Minutes $Policy.LockoutObservationWindowMinutes
    }
}

function Invoke-GpUpdate {
    # Tillämpar datorns grupprinciper direkt i stället för att vänta 90-120 minuter.
    # Returnerar $true om gpupdate lyckades.
    gpupdate /target:computer /force | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gpupdate avslutades med kod $LASTEXITCODE."
        return $false
    }
    $true
}

# Resultatet av kontrollen samlas här och skrivs ut som tabell till sist.
$Checks = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param([string]$Check, [bool]$Ok, [string]$Detail = '')
    $Checks.Add([pscustomobject]@{
        Kontroll = $Check
        Resultat = $(if ($Ok) { 'OK' } else { 'FEL' })
        Detalj   = $Detail
    })
}

# ---------------------------------------------------------------------------
# Förkontroller: stoppa innan något ändras om förutsättningarna inte stämmer
# ---------------------------------------------------------------------------

$domain = Get-ADDomain
if (-not $PolicyRoot) {
    $PolicyRoot = "\\$($domain.DNSRoot)\SYSVOL\$($domain.DNSRoot)\Policies"
}
Write-Host "Domän: $($domain.DNSRoot)"

# CIS 1.2.4: räknaren för misslyckade försök får inte nollställas efter längre tid än
# kontot är utlåst. AD vägrar annars spara PSO:n.
if ($Policy.LockoutObservationWindowMinutes -gt $Policy.LockoutDurationMinutes) {
    throw 'LockoutObservationWindowMinutes får inte vara större än LockoutDurationMinutes.'
}

if (-not $SkipDefaultDomainPolicy) {
    # Default Domain Policy gäller adminkontona. Ett lösenord som är äldre än den nya
    # maxåldern måste bytas vid nästa inloggning. Varna innan, så att det inte kommer
    # som en överraskning på den enda domänkontrollanten.
    $limit = (Get-Date).AddDays(-$Policy.MaxPasswordAgeDays)
    $admins = @(Get-ADGroupMember -Identity "$($domain.DomainSID)-512" -Recursive |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object { Get-ADUser -Identity $_.DistinguishedName -Properties PasswordLastSet, PasswordNeverExpires, Enabled } |
        Where-Object { $_.Enabled -and -not $_.PasswordNeverExpires -and $_.PasswordLastSet -and $_.PasswordLastSet -lt $limit })
    foreach ($admin in $admins) {
        Write-Warning "$($admin.SamAccountName) i Domain Admins har ett lösenord från $($admin.PasswordLastSet.ToString('yyyy-MM-dd')). Det måste bytas vid nästa inloggning. Se till att ni kan logga in vid konsolen."
    }
}

if (-not $SkipPso) {
    # Varje grupp måste finnas och vara en global säkerhetsgrupp. En PSO fungerar inte
    # på domänlokala eller universella grupper, och inte på OU:er.
    foreach ($pso in $PsoList) {
        $group = Get-ADGroup -Filter "Name -eq '$($pso.Group)'"
        if (-not $group) {
            throw "Gruppen '$($pso.Group)' finns inte i AD."
        }
        if ("$($group.GroupScope)" -ne 'Global' -or "$($group.GroupCategory)" -ne 'Security') {
            throw "Gruppen '$($pso.Group)' är $($group.GroupScope)/$($group.GroupCategory), ska vara Global/Security."
        }
        $pso.GroupObject = $group

        # En befintlig PSO som också är kopplad till andra grupper eller användare skulle
        # ändra deras policy. Stoppa, så att det hanteras medvetet.
        $existing = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($pso.Name)'"
        if ($existing) {
            $extra = @(Get-ADFineGrainedPasswordPolicySubject -Identity $existing |
                Where-Object { $_.DistinguishedName -ne $group.DistinguishedName } |
                ForEach-Object { $_.DistinguishedName })
            if ($extra.Count -gt 0) {
                throw "$($pso.Name) är också kopplad till: $($extra -join '; '). Ta bort kopplingen eller ändra skriptet."
            }
        }
    }

    # Två PSO:er med samma precedence avgörs av GUID, alltså slumpmässigt. Stoppa om en
    # PSO som inte hör till skriptet redan använder något av värdena.
    $ownNames = $PsoList | ForEach-Object { $_.Name }
    $ownPrecedence = $PsoList | ForEach-Object { $_.Precedence }
    $others = @(Get-ADFineGrainedPasswordPolicy -Filter * |
        Where-Object { $ownNames -notcontains $_.Name -and $ownPrecedence -contains $_.Precedence })
    if ($others.Count -gt 0) {
        $list = ($others | ForEach-Object { "$($_.Name) ($($_.Precedence))" }) -join ', '
        throw "Andra PSO:er använder samma precedence: $list"
    }
}

# ---------------------------------------------------------------------------
# Steg 1: Default Domain Policy
# ---------------------------------------------------------------------------

$gpUpdateOk = $true

if (-not $SkipDefaultDomainPolicy) {
    Write-Host ''
    Write-Host '== Default Domain Policy =='

    $gpo = Get-GPO -Guid $DefaultDomainPolicyGuid
    $gpoFolder = Join-Path $PolicyRoot "{$DefaultDomainPolicyGuid}"
    $templatePath = Join-Path $gpoFolder 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
    $gptIniPath = Join-Path $gpoFolder 'GPT.INI'
    $gpoDn = "CN={$DefaultDomainPolicyGuid},CN=Policies,CN=System,$($domain.DistinguishedName)"
    # Läs och skriv GPO-objektet på samma domänkontrollant hela tiden.
    $dc = $domain.PDCEmulator

    # Läs och kontrollera allt innan något skrivs, så att GPO:n inte lämnas halvt ändrad.
    $gpoAd = Get-ADObject -Identity $gpoDn -Server $dc -Properties versionNumber, gPCMachineExtensionNames
    if ("$($gpoAd.gPCMachineExtensionNames)" -notmatch $SecurityCseGuid) {
        throw 'Default Domain Policy saknar säkerhetsinställningarnas klienttillägg. Kontrollera GPO:n i Group Policy Management innan skriptet körs.'
    }
    $template = Read-TextFile -Path $templatePath
    $gptIni = Read-TextFile -Path $gptIniPath
    $adVersion = ConvertFrom-AdVersion $gpoAd.versionNumber
    $iniVersion = Get-GptIniVersion -Text $gptIni.Text
    if ($adVersion -ne $iniVersion) {
        throw "GPO-versionen skiljer sig: $adVersion i AD och $iniVersion i GPT.INI. Ändra inget förrän de stämmer."
    }

    $newLines = Set-InfSectionValue -Lines (Split-Lines $template.Text) -Section 'System Access' -Values $SystemAccess
    $newText = ($newLines -join "`r`n") + "`r`n"
    # Säkerhetsmallen ska alltid vara UTF-16 LE med BOM.
    $needsWrite = ($newText -ne $template.Text) -or -not $template.IsUtf16Le

    $current = ConvertTo-PolicyState (Get-ADDefaultDomainPasswordPolicy)
    $domainDiff = @(Compare-PolicyState -Expected $Policy -Actual $current)

    if (-not $needsWrite -and $domainDiff.Count -eq 0) {
        Write-Host 'Default Domain Policy har redan rätt värden.'
    }
    elseif (-not $needsWrite) {
        # GPO:n är rätt men domänen har inte tillämpat den än.
        if ($PSCmdlet.ShouldProcess($gpo.DisplayName, 'Tillämpa GPO:n igen: ' + ($domainDiff -join '; '))) {
            $gpUpdateOk = Invoke-GpUpdate
        }
    }
    elseif ($PSCmdlet.ShouldProcess($gpo.DisplayName, 'Sätt lösenords- och utlåsningspolicy')) {
        # Backup först, så att GPO:n kan återställas med Restore-GPO.
        if (-not (Test-Path $BackupPath)) { New-Item -ItemType Directory -Path $BackupPath | Out-Null }
        $backup = Backup-GPO -Guid $DefaultDomainPolicyGuid -Path $BackupPath -Comment 'Före Set-Losenordspolicy.ps1'
        Write-Host "Backup sparad i $BackupPath (Id $($backup.Id))."

        # Versionen räknas upp både i GPT.INI och på GPO-objektet i AD, annars hämtar
        # datorerna inte ändringen.
        $newVersion = Step-ComputerVersion $iniVersion
        $newGptIni = Set-GptIniVersion -Text $gptIni.Text -Version $newVersion
        # Kontrollera den nya texten innan något skrivs.
        if ((Get-GptIniVersion -Text $newGptIni) -ne $newVersion) {
            throw 'Kunde inte räkna upp versionen i GPT.INI. Ingenting har ändrats.'
        }
        $unicode = New-Object System.Text.UnicodeEncoding($false, $true)

        # Versionen i AD skrivs sist och läses tillbaka. Går något fel läggs filerna och
        # versionen tillbaka som de var, så att GPO:n inte lämnas halvt ändrad.
        try {
            [System.IO.File]::WriteAllText($templatePath, $newText, $unicode)
            [System.IO.File]::WriteAllText($gptIniPath, $newGptIni, $gptIni.Encoding)
            # -Confirm:$false: ändringen är redan godkänd ovan och får inte stoppas halvvägs.
            Set-ADObject -Identity $gpoDn -Server $dc -Replace @{ versionNumber = (ConvertTo-AdVersion $newVersion) } -Confirm:$false
            $written = ConvertFrom-AdVersion (Get-ADObject -Identity $gpoDn -Server $dc -Properties versionNumber).versionNumber
            if ($written -ne $newVersion) { throw "Versionen i AD blev $written, inte $newVersion." }
        }
        catch {
            $failure = $_
            Write-Warning "Ändringen misslyckades, återställer GPO:n: $($failure.Exception.Message)"
            $restoreFailed = $false

            # Varje del återställs för sig, så att ett fel i en del inte hindrar de andra.
            try { [System.IO.File]::WriteAllText($templatePath, $template.Text, $template.Encoding) }
            catch { $restoreFailed = $true; Write-Warning "Kunde inte återställa GptTmpl.inf: $($_.Exception.Message)" }

            try { [System.IO.File]::WriteAllText($gptIniPath, $gptIni.Text, $gptIni.Encoding) }
            catch { $restoreFailed = $true; Write-Warning "Kunde inte återställa GPT.INI: $($_.Exception.Message)" }

            # AD kan ha tagit emot den nya versionen även om anropet rapporterade fel.
            try {
                $nowAd = ConvertFrom-AdVersion (Get-ADObject -Identity $gpoDn -Server $dc -Properties versionNumber).versionNumber
                if ($nowAd -ne $adVersion) {
                    Set-ADObject -Identity $gpoDn -Server $dc -Replace @{ versionNumber = (ConvertTo-AdVersion $adVersion) } -Confirm:$false
                }
            }
            catch { $restoreFailed = $true; Write-Warning "Kunde inte återställa versionen i AD: $($_.Exception.Message)" }

            if ($restoreFailed) {
                Write-Warning "GPO:n kan vara halvt ändrad. Återställ den med: Restore-GPO -BackupId $($backup.Id) -Path '$BackupPath'"
            }
            throw $failure
        }
        Write-Host "GPO-versionen räknades upp från $iniVersion till $newVersion."

        $gpUpdateOk = Invoke-GpUpdate
    }
}

# ---------------------------------------------------------------------------
# Steg 2: PSO per avdelning
# ---------------------------------------------------------------------------

if (-not $SkipPso) {
    Write-Host ''
    Write-Host '== PSO per avdelning =='
    $psoParameters = Get-PsoParameter

    foreach ($pso in $PsoList) {
        $existing = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($pso.Name)'"

        if (-not $existing) {
            if ($PSCmdlet.ShouldProcess($pso.Name, "Skapa PSO med precedence $($pso.Precedence)")) {
                New-ADFineGrainedPasswordPolicy -Name $pso.Name -Precedence $pso.Precedence `
                    -Description "För samtliga $($pso.Group) arbetare" `
                    -ProtectedFromAccidentalDeletion $true @psoParameters
                Write-Host "Skapade $($pso.Name)."
            }
        }
        else {
            # Uppdatera bara om något skiljer sig, så att utskriften visar vad som ändrats.
            $diff = @(Compare-PolicyState -Expected $Policy -Actual (ConvertTo-PolicyState $existing))
            if ($existing.Precedence -ne $pso.Precedence) {
                $diff += "Precedence är $($existing.Precedence), ska vara $($pso.Precedence)"
            }
            if ($diff.Count -eq 0) {
                Write-Host "$($pso.Name) har redan rätt värden."
            }
            elseif ($PSCmdlet.ShouldProcess($pso.Name, 'Uppdatera PSO: ' + ($diff -join '; '))) {
                Set-ADFineGrainedPasswordPolicy -Identity $existing -Precedence $pso.Precedence @psoParameters
                Write-Host "Uppdaterade $($pso.Name): $($diff -join '; ')."
            }
        }

        # Koppla PSO:n till gruppen om den inte redan är kopplad.
        $subjects = @()
        if ($existing) {
            $subjects = @(Get-ADFineGrainedPasswordPolicySubject -Identity $existing |
                ForEach-Object { $_.DistinguishedName })
        }
        if ($subjects -notcontains $pso.GroupObject.DistinguishedName) {
            if ($PSCmdlet.ShouldProcess($pso.Name, "Koppla till gruppen $($pso.Group)")) {
                Add-ADFineGrainedPasswordPolicySubject -Identity $pso.Name -Subjects $pso.GroupObject
                Write-Host "Kopplade $($pso.Name) till $($pso.Group)."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Steg 3: Kontroll
# ---------------------------------------------------------------------------

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host 'Körningen gjordes med -WhatIf, så ingenting ändrades och kontrollen hoppas över.'
    return
}

Write-Host ''
Write-Host '== Kontroll =='

if (-not $SkipDefaultDomainPolicy) {
    # 1. Det som står i GPO:n: säkerhetsmallen och versionen.
    $template = Read-TextFile -Path $templatePath
    $stored = Get-InfSectionValue -Lines (Split-Lines $template.Text) -Section 'System Access'
    $templateDiff = @(foreach ($key in $SystemAccess.Keys) {
        if ("$($stored[$key])" -ne "$($SystemAccess[$key])") { "$key är '$($stored[$key])', ska vara $($SystemAccess[$key])" }
    })
    if (-not $template.IsUtf16Le) { $templateDiff += 'filen är inte UTF-16 LE med BOM' }
    Add-Check -Check 'Default Domain Policy: GptTmpl.inf' -Ok ($templateDiff.Count -eq 0) -Detail ($templateDiff -join '; ')

    $adVersionNow = ConvertFrom-AdVersion (Get-ADObject -Identity $gpoDn -Server $dc -Properties versionNumber).versionNumber
    $iniVersionNow = Get-GptIniVersion -Text (Read-TextFile -Path $gptIniPath).Text
    Add-Check -Check 'Default Domain Policy: version AD = GPT.INI' -Ok ($adVersionNow -eq $iniVersionNow) `
        -Detail "AD $adVersionNow, GPT.INI $iniVersionNow"

    Add-Check -Check 'Default Domain Policy: gpupdate' -Ok $gpUpdateOk

    # 2. Det som domänen faktiskt tillämpar. Värdena uppdateras när domänkontrollanten
    # har bearbetat GPO:n, så vänta upp till en minut.
    $diff = @()
    for ($i = 0; $i -lt 12; $i++) {
        $diff = @(Compare-PolicyState -Expected $Policy -Actual (ConvertTo-PolicyState (Get-ADDefaultDomainPasswordPolicy)))
        if ($diff.Count -eq 0) { break }
        Start-Sleep -Seconds 5
    }
    Add-Check -Check 'Default Domain Policy: tillämpad i domänen' -Ok ($diff.Count -eq 0) -Detail ($diff -join '; ')
}

if (-not $SkipPso) {
    foreach ($pso in $PsoList) {
        $current = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($pso.Name)'"
        if (-not $current) {
            Add-Check -Check $pso.Name -Ok $false -Detail 'PSO:n finns inte'
            continue
        }

        $diff = @(Compare-PolicyState -Expected $Policy -Actual (ConvertTo-PolicyState $current))
        if ($current.Precedence -ne $pso.Precedence) {
            $diff += "Precedence är $($current.Precedence), ska vara $($pso.Precedence)"
        }
        Add-Check -Check "$($pso.Name): värden" -Ok ($diff.Count -eq 0) -Detail ($diff -join '; ')

        # PSO:n ska vara kopplad till avdelningens grupp och inget annat.
        $subjects = @(Get-ADFineGrainedPasswordPolicySubject -Identity $current |
            ForEach-Object { $_.DistinguishedName })
        $subjectsOk = $subjects.Count -eq 1 -and $subjects[0] -eq $pso.GroupObject.DistinguishedName
        Add-Check -Check "$($pso.Name): kopplad till $($pso.Group)" -Ok $subjectsOk -Detail ($subjects -join '; ')

        # Stickprov: vilken policy gäller för en användare i gruppen? En användare som
        # också är med i en grupp med lägre precedence får den gruppens PSO, så det
        # räknas som en varning och inte som ett fel.
        $member = Get-ADGroupMember -Identity $pso.GroupObject |
            Where-Object { $_.objectClass -eq 'user' } | Select-Object -First 1
        if ($member) {
            $resultant = Get-ADUserResultantPasswordPolicy -Identity $member.DistinguishedName
            $resultantName = if ($resultant) { $resultant.Name } else { 'Default Domain Policy' }
            if ($resultantName -ne $pso.Name) {
                Write-Warning "$($member.SamAccountName) i $($pso.Group) får '$resultantName', inte '$($pso.Name)'. Är användaren med i flera avdelningsgrupper?"
            }
        }
    }
}

$Checks | Format-Table -AutoSize -Wrap

$failed = @($Checks | Where-Object { $_.Resultat -eq 'FEL' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) kontroller misslyckades." -ForegroundColor Red
    exit 1
}
Write-Host 'Alla kontroller OK.' -ForegroundColor Green
exit 0
