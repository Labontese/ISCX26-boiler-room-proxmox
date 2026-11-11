# 06-gpo-minsta-rattighet.ps1
# Steg 6: GPO:n "CIS - Least Privilege DC" enligt docs/reference/least-privilege.md
# (CIS Microsoft Windows Server 2025 Benchmark v2.1.0, kapitel 2.2). Länkas bara
# till OU:n Domain Controllers. Tål att köras om.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory, GroupPolicy

$namn   = 'CIS - Least Privilege DC'
$doman  = Get-ADDomain
$gpo    = Get-GPO -Name $namn -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $namn -Comment 'CIS 2.2 User Rights Assignment för domänkontrollanter' }

if (-not ((Get-GPInheritance $doman.DomainControllersContainer).GpoLinks | Where-Object DisplayName -eq $namn)) {
    New-GPLink -Name $namn -Target $doman.DomainControllersContainer | Out-Null
}
# Länkordning 1. Default Domain Controllers Policy är också länkad till
# Domain Controllers och sätter flera av samma rättigheter. Den GPO som har
# lägst länkordning vinner, och en ny länk hamnar annars sist.
Set-GPLink -Name $namn -Target $doman.DomainControllersContainer -Order 1 | Out-Null

# Kända SID: Administrators S-1-5-32-544, Guests S-1-5-32-546,
# ENTERPRISE DOMAIN CONTROLLERS S-1-5-9.
$anstallda = (Get-ADGroup 'gg-anstallda').SID.Value
$inf = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeMachineAccountPrivilege = *S-1-5-32-544
SeInteractiveLogonRight = *S-1-5-32-544,*S-1-5-9
SeRemoteInteractiveLogonRight = *S-1-5-32-544
SeDebugPrivilege = *S-1-5-32-544
SeDenyInteractiveLogonRight = *S-1-5-32-546,*$anstallda
SeDenyRemoteInteractiveLogonRight = *S-1-5-32-546,*$anstallda
SeShutdownPrivilege = *S-1-5-32-544
"@

$gpoRot = "\\$($doman.DNSRoot)\SYSVOL\$($doman.DNSRoot)\Policies\{$($gpo.Id)}"
$secedit = "$gpoRot\Machine\Microsoft\Windows NT\SecEdit"
New-Item -ItemType Directory -Path $secedit -Force | Out-Null
Set-Content -Path "$secedit\GptTmpl.inf" -Value $inf -Encoding Unicode

# Datorerna läser bara säkerhetsinställningarna om klienttillägget för
# säkerhet är registrerat på GPO:n.
$gpoDn = "CN={$($gpo.Id)},CN=Policies,CN=System,$($doman.DistinguishedName)"
Set-ADObject $gpoDn -Replace @{
    gPCMachineExtensionNames = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
}

# Räkna upp datordelen av versionen (de låga 16 bitarna), både i AD och i
# GPT.INI, annars tror domänkontrollanten att inget har ändrats.
$version = [long](Get-ADObject $gpoDn -Properties versionNumber).versionNumber
$ny = ((($version -shr 16) -band 0xFFFF) -shl 16) -bor ((($version -band 0xFFFF) + 1) -band 0xFFFF)
Set-ADObject $gpoDn -Replace @{ versionNumber = [int]$ny }
Set-Content -Path "$gpoRot\GPT.INI" -Value "[General]`r`nVersion=$ny" -Encoding ASCII

gpupdate /target:computer /force | Out-Null
(Get-GPInheritance $doman.DomainControllersContainer).GpoLinks | Format-Table Order, DisplayName -AutoSize
