#!/bin/bash
# 02-testa-delningar.sh
# Provar behörigheterna på SRV-01-DC:s delningar som testanvändarna, enligt
# behörighetsmatrisen i docs/reference/acl/acc-plan.md. Körs på SRV-02-LNX.
# Testanvändarnas lösenord läses från standard in:
#   ./02-testa-delningar.sh < testanvandare-losenord.txt
set -uo pipefail

read -r LOSEN
# PowerShell lägger en BOM först och CRLF sist när text pipas till ssh.
LOSEN=${LOSEN#$'\xef\xbb\xbf'}
LOSEN=${LOSEN%$'\r'}
DC=//192.168.50.10
AUTH=$(mktemp); chmod 600 "$AUTH"; trap 'rm -f "$AUTH" /tmp/provfil.txt' EXIT
echo "prov $(date +%T)" > /tmp/provfil.txt
FEL=0

prova() {   # användare, delning, läs|skriv, väntat ja|nej
    printf 'username = %s\npassword = %s\ndomain = SOST\n' "$1" "$LOSEN" > "$AUTH"
    if [[ $3 == läs ]]; then kmd='ls'; else kmd="put /tmp/provfil.txt prov-$1.txt; del prov-$1.txt"; fi
    if smbclient "$DC/$2" -A "$AUTH" -m SMB3 -c "$kmd" > /dev/null 2>&1; then fick=ja; else fick=nej; fi
    [[ $fick == "$4" ]] && res=OK || { res=FEL; FEL=1; }
    printf '%-4s %-13s %-20s %-5s väntat %-3s fick %s\n' "$res" "$1" "$2" "$3" "$4" "$fick"
}

prova test-hr      HR                    skriv ja
prova test-hr      Ekonomi               läs   nej
prova test-hr      'Gemensamma dokument' läs   ja
prova test-hr      'Gemensamma dokument' skriv nej
prova test-ekonomi Ekonomi               skriv ja
prova test-ekonomi Lager                 skriv ja
prova test-lager   Lager                 skriv ja
prova test-lager   Ekonomi               läs   nej
prova test-it      IT                    skriv ja
prova test-it      Ledning               läs   nej
prova test-ledning Ledning               skriv ja
prova test-ledning HR                    läs   nej
exit $FEL
