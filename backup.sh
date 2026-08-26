#!/usr/bin/env bash
#
# Backup n8n — snapshot consistent, luat cu stiva pornită.
#
# Rulează ca utilizatorul `ubuntu` (e în grupul docker, nu are nevoie de sudo).
# Cron: 30 3 * * *   — vezi `crontab -l`
# Manual: /home/ubuntu/n8n-stack/backup.sh
#
# ============================================================================
#  REScris pe 2026-07-30. Versiunea anterioară făcea `VACUUM INTO` pe
#  /home/node/.n8n/database.sqlite — fișierul SQLite abandonat la migrarea pe
#  Postgres din 2026-07-27. Timp de trei zile logul a scris "backup ok" în
#  fiecare noapte, iar toate cele 14 arhive aveau exact 364K și același
#  md5 pentru database.sqlite: același fișier înghețat, copiat iar și iar.
#
#  Ce lipsea din ele, la momentul descoperirii: 23 din 43 de pagini Facebook
#  (inclusiv toate cele 4 spaniole) și întreg workflow-ul `SofiaFollowup01`.
#  Postgres nu avea NICIUN backup.
#
#  De aici vine `MANIFEST.txt`: un backup care minte trebuie să fie evident la
#  citirea logului, nu descoperit trei zile mai târziu. Numărul de pagini și de
#  workflow-uri se scrie în log la fiecare rulare.
# ============================================================================
#
# Ce conține fiecare arhivă:
#   n8n.dump      — pg_dump format custom: workflow-uri, credențiale (criptate),
#                   Data Tables, sofia_followups, setări, useri
#   config        — CHEIA DE CRIPTARE (32 chars) din volumul n8n_data
#   MANIFEST.txt  — ce e în dump, verificabil fără restaurare
#
# De ce și `config`: credențialele din dump sunt criptate cu cheia din acest
# fișier, iar cheia NU e în baza de date. Un dump fără ea pare complet, dar la
# restaurare pe o mașină nouă toate credențialele rămân nedecriptabile
# definitiv. Cele două trebuie să călătorească împreună.
#
# Cheia efectivă vine din .env (N8N_ENCRYPTION_KEY). Scriptul verifică la
# fiecare rulare că .env și volumul au ACEEAȘI cheie și refuză să continue
# altfel — o arhivă cu cheia greșită e mai rea decât niciuna, pentru că pare
# validă.
#
# Ce NU se salvează (date, nu schemă): execution_entity, execution_data și
# tabelele de lucru sofia_msg_buffer / sofia_pending. Primele două erau 1,1 GB
# din 1,16 GB ai bazei și se șterg oricum în 24h; ultimele două sunt ferestre
# de grupare de 25 de secunde. Schema lor rămâne în dump, deci restaurarea dă
# o bază funcțională, doar fără istoricul de execuții.
#
# RESTAURARE pe o mașină nouă:
#   1. docker volume create n8n_data
#   2. pune `config` din arhivă în volum, la /home/node/.n8n/config (chmod 600)
#   3. pune aceeași cheie în .env ca N8N_ENCRYPTION_KEY
#   4. docker compose up -d postgres && sleep 15
#   5. docker exec -i n8n-postgres pg_restore -U n8n -d n8n --clean --if-exists \
#        --no-owner < n8n.dump
#   6. docker compose up -d

set -euo pipefail

STACK_DIR="/home/ubuntu/n8n-stack"
BACKUP_DIR="$STACK_DIR/backups"
PG_CONTAINER="n8n-postgres"
KEEP=14

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/n8n-$TS.tar.gz"
WORK="$(mktemp -d /tmp/n8n-backup-XXXXXX)"

log() { echo "[$(date -Is)] $*"; }
fail() { log "EROARE: $*"; exit 1; }

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"   # arhivele conțin cheia de criptare

trap 'rm -rf "$WORK"' EXIT

docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
  || fail "containerul '$PG_CONTAINER' nu rulează — backup anulat"

# --- 1. cheia de criptare, cu verificare de concordanță -----------------------
# Volumul e montat read-only: backup-ul nu are voie să scrie material de
# criptare, doar să-l citească.
docker run --rm -v n8n_data:/d:ro -v "$STACK_DIR":/s:ro --entrypoint node \
  docker.n8n.io/n8nio/n8n:2.31.7 -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync("/d/config", "utf8")).encryptionKey;
  const line = fs.readFileSync("/s/.env", "utf8").split("\n")
    .find(l => l.startsWith("N8N_ENCRYPTION_KEY="));
  if (!line) { console.error("N8N_ENCRYPTION_KEY lipsește din .env"); process.exit(1); }
  if (cfg !== line.slice(19).trim()) {
    console.error("cheia din .env difera de cea din volumul n8n_data");
    process.exit(1);
  }
  process.stdout.write(fs.readFileSync("/d/config", "utf8"));
' > "$WORK/config" 2>"$WORK/keyerr" \
  || fail "cheia de criptare: $(cat "$WORK/keyerr")"

[ -s "$WORK/config" ] || fail "fișierul config a ieșit gol"

# --- 2. dump-ul Postgres -----------------------------------------------------
# Format custom (-Fc): comprimat, restaurabil selectiv cu pg_restore.
# --exclude-table-data păstrează schema și arunca datele de umplutură.
docker exec "$PG_CONTAINER" pg_dump -U n8n -d n8n -Fc \
  --exclude-table-data='public.execution_entity' \
  --exclude-table-data='public.execution_data' \
  --exclude-table-data='public.execution_metadata' \
  --exclude-table-data='public.sofia_msg_buffer' \
  --exclude-table-data='public.sofia_pending' \
  > "$WORK/n8n.dump" 2>"$WORK/dumperr" \
  || fail "pg_dump a eșuat: $(cat "$WORK/dumperr")"

[ -s "$WORK/n8n.dump" ] || fail "dump-ul a ieșit gol"

# Dump-ul se citește complet înapoi. Prinde trunchierea, care altfel arată ca
# un fișier valid până în ziua în care ai nevoie de el.
docker exec -i "$PG_CONTAINER" pg_restore --list > "$WORK/toc.txt" < "$WORK/n8n.dump" 2>"$WORK/tocerr" \
  || fail "dump-ul nu e citibil de pg_restore: $(cat "$WORK/tocerr")"

for t in workflow_entity credentials_entity data_table_user_XXXXXXXXXXXXXXXX; do
  grep -q "$t" "$WORK/toc.txt" || fail "tabelul $t lipsește din dump"
done

# --- 3. manifest — dovada că arhiva nu e înghețată ---------------------------
# Doar marginile se taie: un `tr -d ' '` ar lipi între ele valorile agregate.
q() { docker exec "$PG_CONTAINER" psql -U n8n -d n8n -tAc "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

PAGES=$(q "SELECT count(*) FROM \"data_table_user_XXXXXXXXXXXXXXXX\"")
PAGES_BY_LANG=$(q "SELECT string_agg(language||'='||c, ', ' ORDER BY language) FROM (SELECT language, count(*) c FROM \"data_table_user_XXXXXXXXXXXXXXXX\" GROUP BY language) s")
WFS=$(q "SELECT count(*) FROM workflow_entity")
WFS_ACTIVE=$(q "SELECT count(*) FROM workflow_entity WHERE active")
CREDS=$(q "SELECT count(*) FROM credentials_entity")
FOLLOWUPS=$(q "SELECT count(*) FROM sofia_followups")
DBSIZE=$(q "SELECT pg_size_pretty(pg_database_size('n8n'))")

{
  echo "n8n backup manifest"
  echo "generat:        $(date -Is)"
  echo "host:           $(hostname)"
  echo "imagine n8n:    $(docker inspect --format '{{.Config.Image}}' n8n 2>/dev/null || echo '?')"
  echo "postgres:       $(docker exec "$PG_CONTAINER" postgres --version 2>/dev/null | head -1)"
  echo
  echo "-- conținut (numărat din baza LIVE la momentul dump-ului) --"
  echo "pagini Facebook:    $PAGES   ($PAGES_BY_LANG)"
  echo "workflow-uri:       $WFS ($WFS_ACTIVE active)"
  echo "credențiale:        $CREDS (criptate cu cheia din ./config)"
  echo "follow-up-uri:      $FOLLOWUPS"
  echo "dimensiune bază:    $DBSIZE"
  echo "dump (necomprimat): $(du -h "$WORK/n8n.dump" | cut -f1)"
  echo "sha256 dump:        $(sha256sum "$WORK/n8n.dump" | cut -d' ' -f1)"
  echo
  echo "-- date excluse intenționat (schema E în dump) --"
  echo "execution_entity, execution_data, execution_metadata,"
  echo "sofia_msg_buffer, sofia_pending"
} > "$WORK/MANIFEST.txt"

# --- 4. arhivare -------------------------------------------------------------
tar czf "$OUT" -C "$WORK" n8n.dump config MANIFEST.txt
chmod 600 "$OUT"

# păstrează cele mai noi $KEEP arhive
ls -1t "$BACKUP_DIR"/n8n-*.tar.gz 2>/dev/null | tail -n "+$((KEEP + 1))" | xargs -r rm -f

log "backup ok: $(basename "$OUT") ($(du -h "$OUT" | cut -f1)) — ${PAGES} pagini ($PAGES_BY_LANG), ${WFS} workflow-uri, ${CREDS} credențiale — $(ls -1 "$BACKUP_DIR"/n8n-*.tar.gz 2>/dev/null | wc -l) arhive păstrate"
