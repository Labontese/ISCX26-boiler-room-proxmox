# 01-grund.ps1
# Steg 1 på SRV-01-DC efter kloning: nätverkskort, fast adress, tidszon och
# datornamn. Datornamnet måste vara rätt innan servern blir domänkontrollant.
$ErrorActionPreference = 'Stop'

# Korten pekas ut med MAC-adressen, som är fast i Terraform.
$drift = Get-NetAdapter | Where-Object MacAddress -eq 'BC-24-11-00-D3-31'
$prod  = Get-NetAdapter | Where-Object MacAddress -eq 'BC-24-11-50-00-10'
if ($drift.Name -ne 'Drift')      { Rename-NetAdapter -Name $drift.Name -NewName 'Drift' }
if ($prod.Name  -ne 'Produktion') { Rename-NetAdapter -Name $prod.Name  -NewName 'Produktion' }

# Produktion: fast adress enligt IP-planen. Ingen gateway, nätet är isolerat.
if (-not (Get-NetIPAddress -InterfaceAlias Produktion -IPAddress 192.168.50.10 -ErrorAction SilentlyContinue)) {
    Set-NetIPInterface -InterfaceAlias Produktion -Dhcp Disabled
    New-NetIPAddress -InterfaceAlias Produktion -IPAddress 192.168.50.10 -PrefixLength 24 | Out-Null
}

# Drift: DHCP från pfSense (VLAN 70). Adressen får inte hamna i AD:s DNS,
# klienterna i produktionsnätet ska bara se 192.168.50.10.
Set-DnsClient -InterfaceAlias Drift -RegisterThisConnectionsAddress $false

Set-TimeZone -Id 'W. Europe Standard Time'

if ($env:COMPUTERNAME -ne 'SRV-01-DC') {
    Rename-Computer -NewName 'SRV-01-DC' -Force
    Write-Host 'Datornamnet ändrat till SRV-01-DC. Starta om.'
}
Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceAlias -in 'Drift','Produktion' |
    Format-Table InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin -AutoSize
