#!/bin/bash
# arkivera-wsb.sh
# Sparar en daterad kopia av Windows Server Backup från SRV-01-DC.
#
# Windows Server Backup skriver alltid till samma mapp på delningen
# /srv/backup/wsb och skriver över förra backupen varje gång. Misslyckas en
# körning kan den enda backupen vara förstörd. Det här skriptet kopierar därför
# den senaste lyckade backupen till /srv/backup/arkiv, som inte är utdelad och
# inte kan ändras från Windows.
#
# Varje körning skapar i /srv/backup/arkiv:
#   SRV-01-DC_ÅÅÅÅ-MM-DD_TTMM/          kopia av WindowsImageBackup
#   SRV-01-DC_ÅÅÅÅ-MM-DD_TTMM.sha256    kontrollsummor för varje fil
#
# Körs av systemd-timern arkivera-wsb.timer, se driftdokumentationen.

set -euo pipefail

DELNING=/srv/backup/wsb                  # där Windows Server Backup skriver
KALLA=$DELNING/WindowsImageBackup/SRV-01-DC
ARKIV=/srv/backup/arkiv                  # daterade kopior, inte utdelad
SPARA_DAGAR=4                            # hur länge kopior sparas, se steg 4
VILA_MINUTER=30                          # backupen ska ha legat orörd så här länge

DATUM=$(date +%F_%H%M)
NAMN="SRV-01-DC_$DATUM"

# 1. Stoppa om backupdisken inte är monterad
mountpoint -q /srv/backup || { echo "FEL: /srv/backup är inte monterad" >&2; exit 1; }
[[ -d "$KALLA" ]] || { echo "FEL: $KALLA finns inte, ingen backup har tagits" >&2; exit 1; }

# 2. Stoppa om Windows håller på att skriva. Då är backupen inte färdig.
#    Windows håller kvar läsöppna kataloger (RDONLY) efter backupen, så bara
#    filer som är öppna för skrivning (RDWR) räknas.
if smbstatus -L 2>/dev/null | grep "$DELNING" | grep -q 'RDWR'; then
    echo "FEL: filer på $DELNING är öppna för skrivning, backupen pågår" >&2; exit 1
fi
if [[ -n $(find "$KALLA" -newermt "$VILA_MINUTER minutes ago" -print -quit) ]]; then
    echo "FEL: $KALLA ändrades för mindre än $VILA_MINUTER minuter sedan" >&2; exit 1
fi

# 3. Hoppa över om den senaste kopian redan är samma backup
SENASTE=$(ls -1d "$ARKIV"/SRV-01-DC_*/ 2>/dev/null | tail -n 1 || true)
if [[ -n "$SENASTE" ]] && diff -rq "$KALLA" "$SENASTE" > /dev/null 2>&1; then
    echo "$(date '+%F %T') OK: ingen ny backup sedan $(basename "$SENASTE")"
    exit 0
fi

# 4. Ta bort gamla kopior, och stoppa om utrymmet ändå inte räcker.
#    En backup av SRV-01-DC är cirka 13 GB och backupdisken 98 GB. Med
#    SPARA_DAGAR=4 finns högst fem kopior och den senaste backupen på delningen,
#    cirka 78 GB.
find "$ARKIV" -maxdepth 1 -name 'SRV-01-DC_*' -mtime +"$SPARA_DAGAR" -exec rm -rf {} +
BEHOV=$(( $(du -sb "$KALLA" | cut -f1) * 11 / 10 ))
LEDIGT=$(df -B1 --output=avail /srv/backup | tail -n 1)
if (( LEDIGT < BEHOV )); then
    echo "FEL: $((LEDIGT / 1024**3)) GB ledigt, kopian behöver $((BEHOV / 1024**3)) GB" >&2; exit 1
fi

# 5. Kopiera och skriv kontrollsummor
mkdir -p "$ARKIV"
cp -a "$KALLA" "$ARKIV/$NAMN"
( cd "$ARKIV/$NAMN" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) > "$ARKIV/$NAMN.sha256"

# 6. Kontrollera kopian mot källan
( cd "$KALLA" && sha256sum --quiet -c "$ARKIV/$NAMN.sha256" ) \
    || { echo "FEL: kopian stämmer inte med källan" >&2; exit 1; }

echo "$(date '+%F %T') OK: $ARKIV/$NAMN ($(du -sh "$ARKIV/$NAMN" | cut -f1))"
