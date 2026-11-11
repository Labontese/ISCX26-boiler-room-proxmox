# 05-dns-och-dhcp.ps1
# Steg 5: DNS och DHCP lyssnar bara i produktionsnätet 192.168.50.0/24, aldrig
# på driftnätet (VLAN 70). Där finns redan pfSense, och SRV-01-DC ska inte svara
# på frågor från hemnätet. DHCP-poolen följer docs/reference/ip-plan.md.
$ErrorActionPreference = 'Stop'

# --- DNS ---------------------------------------------------------------------
# DNS-servern lyssnar bara på 192.168.50.10, och servern använder den adressen
# som DNS på båda korten.
dnscmd /ResetListenAddresses 192.168.50.10 | Out-Null
Set-DnsClientServerAddress -InterfaceAlias Produktion, Drift -ServerAddresses 192.168.50.10
Restart-Service DNS

# --- DHCP --------------------------------------------------------------------

if (-not (Get-DhcpServerInDC | Where-Object DnsName -like 'SRV-01-DC*')) {
    Add-DhcpServerInDC -DnsName 'SRV-01-DC.sost.local' -IPAddress 192.168.50.10
}
Set-DhcpServerv4Binding -InterfaceAlias 'Produktion' -BindingState $true
# Drift får sin adress via DHCP och finns därför inte ens bland DHCP-serverns
# bindningar. Raden behövs bara om kortet någon gång får fast adress.
if (Get-DhcpServerv4Binding | Where-Object InterfaceAlias -eq 'Drift') {
    Set-DhcpServerv4Binding -InterfaceAlias 'Drift' -BindingState $false
}

if (-not (Get-DhcpServerv4Scope -ScopeId 192.168.50.0 -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name 'Klienter produktion' -StartRange 192.168.50.100 `
        -EndRange 192.168.50.254 -SubnetMask 255.255.255.0 -LeaseDuration 8.00:00:00 -State Active
}
Set-DhcpServerv4OptionValue -ScopeId 192.168.50.0 -Router 192.168.50.1 `
    -DnsServer 192.168.50.10 -DnsDomain 'sost.local'

# Server Manager slutar varna för att DHCP-konfigurationen inte är klar.
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2

(Get-DnsServerSetting -All -WarningAction SilentlyContinue).ListeningIPAddress
Resolve-DnsName srv-01-dc.sost.local -Server 192.168.50.10 | Format-Table Name, IPAddress -AutoSize
Get-DhcpServerv4Binding | Format-Table InterfaceAlias, IPAddress, BindingState -AutoSize
Get-DhcpServerv4Scope   | Format-Table ScopeId, StartRange, EndRange, State -AutoSize
