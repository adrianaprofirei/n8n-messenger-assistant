#!/usr/bin/env bash
#
# Curăță resturile din tabelele de grupare a mesajelor.
#
# DE UNDE APAR: dacă o execuție moare la mijlocul ferestrei de 25 de secunde
# (container omorât brutal, OOM, crash), rândurile ei din sofia_msg_buffer și
# sofia_pending rămân pe loc. Utilizatorul a văzut "Seen" și n-a primit nimic.
#
# AUTO-VINDECARE: dacă omul mai scrie o dată, interogarea de revendicare curăță
# singură revendicările mai vechi de 2 minute, un lider nou preia și adună TOATE
# mesajele lui, inclusiv cel rămas. Deci majoritatea se rezolvă de la sine.
#
# CE RĂMÂNE: cei care nu mai scriu niciodată. Rândurile lor stau la infinit.
# Puține — 8 după două reporniri — dar cresc nelimitat în timp.
#
# Pragurile sunt mult peste fereastra normală de lucru (25s), deci nu pot
# atinge o conversație vie:
#   buffer  > 1 oră     — abandonat sigur
#   pending > 10 minute — cu mult peste cele 2 minute ale auto-vindecării
#
# Cron: rulează odată pe zi, alături de backup.

set -euo pipefail
CONTAINER="n8n-postgres"

log() { echo "[$(date -Is)] $*"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  log "EROARE: $CONTAINER nu rulează — curățare anulată"
  exit 1
fi

psql() { docker exec "$CONTAINER" psql -U n8n -d n8n -tAc "$1"; }

BUF=$(psql "WITH d AS (DELETE FROM sofia_msg_buffer WHERE created_at < now() - interval '1 hour' RETURNING 1) SELECT count(*) FROM d")
PEN=$(psql "WITH d AS (DELETE FROM sofia_pending  WHERE claimed_at < now() - interval '10 minutes' RETURNING 1) SELECT count(*) FROM d")

log "curățat: $(echo "$BUF" | tr -d ' ') mesaje orfane, $(echo "$PEN" | tr -d ' ') revendicări blocate"
