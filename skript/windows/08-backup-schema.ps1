# 08-backup-schema.ps1
# Steg 8: schemalagd backup med Windows Server Backup till delningen
# \\192.168.50.50\backup på SRV-02-LNX.
#
# Med i backupen:
#   System State   AD-databasen (NTDS.dit) med de AD-integrerade DNS-zonerna,
#                  SYSVOL med GPO:erna, registret och startfilerna
#   C:\Fildelning  avdelningarnas filer med NTFS-behörigheter
#   C:\Windows\System32\dhcp\backup
#                  DHCP-tjänstens egen kopia av DHCP-databasen, som tjänsten
#                  skriver varje timme
#
#   .\08-backup-schema.ps1 -SvcBackupLosenord '...' [-Tider '03:00']
param(
    [Parameter(Mandatory)][string]$SvcBackupLosenord,
    [string]$Tider = '03:00'
)
$ErrorActionPreference = 'Stop'
$mal = '\\192.168.50.50\backup'

# Ett befintligt schema tas bort först, så att skriptet kan köras om med nya tider.
if (Get-WBPolicy -ErrorAction SilentlyContinue) {
    wbadmin disable backup -quiet | Out-Null
}

wbadmin enable backup `
    "-addtarget:$mal" `
    -user:SOST\svc-backup `
    "-password:$SvcBackupLosenord" `
    -systemState `
    "-include:C:\Fildelning,C:\Windows\System32\dhcp\backup" `
    -vssFull `
    "-schedule:$Tider" `
    -quiet
if ($LASTEXITCODE -ne 0) { throw "wbadmin enable backup avslutades med kod $LASTEXITCODE" }

Get-WBPolicy | Format-List
Get-WBSchedule
