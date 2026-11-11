# 02-domankontrollant.ps1
# Steg 2: rollerna AD DS, DNS, DHCP och Windows Server Backup, och ny skog
# sost.local. Servern startar om av sig själv när den blivit domänkontrollant.
#
# Körs med DSRM-lösenordet som parameter, det lagras inte i skriptet:
#   .\02-domankontrollant.ps1 -DsrmLosenord '...'
param([Parameter(Mandatory)][string]$DsrmLosenord)
$ErrorActionPreference = 'Stop'

if ($env:COMPUTERNAME -ne 'SRV-01-DC') { throw 'Kör 01-grund.ps1 och starta om först.' }

Install-WindowsFeature AD-Domain-Services, DNS, DHCP, Windows-Server-Backup, GPMC `
    -IncludeManagementTools | Format-Table FeatureResult, Success, RestartNeeded -AutoSize

# Före befordran pekar servern på sig själv som DNS. Efter befordran är den
# själv DNS-server för sost.local.
Set-DnsClientServerAddress -InterfaceAlias Produktion, Drift -ServerAddresses 127.0.0.1

Install-ADDSForest `
    -DomainName 'sost.local' `
    -DomainNetbiosName 'SOST' `
    -ForestMode 'Win2025' `
    -DomainMode 'Win2025' `
    -InstallDns `
    -SafeModeAdministratorPassword (ConvertTo-SecureString $DsrmLosenord -AsPlainText -Force) `
    -Force
