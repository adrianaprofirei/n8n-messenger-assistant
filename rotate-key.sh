#!/usr/bin/env bash
#
# Rotește cheia de criptare n8n.
#
# DE CE EXISTĂ ACEST FIȘIER: cheia veche a apărut într-un transcript de sesiune
# pe 2026-07-27. Rotirea o face inutilă. Scriptul e separat pentru că scrierea
# materialului de criptare e o acțiune pe care asistentul nu o execută — o
# rulezi tu.
#
# CE FACE, exact, în ordine:
#   1. verifică existența unui export decriptat al credențialelor (plasa de
#      siguranță — fără el, rotirea le-ar face nedecriptabile definitiv)
#   2. generează o cheie nouă de 32 de caractere
#   3. o scrie în .env
#   4. o scrie în fișierul `config` din volumul n8n_data (folosit ca rezervă
#      dacă variabila de mediu dispare vreodată)
#   5. verifică faptul că cele două coincid
#
# NU repornește nimic și NU atinge credențialele. După ce rulează, asistentul
# repornește stiva și re-importă credențialele, care se re-criptează cu noua
# cheie.
#
# Rulare:  cd /home/ubuntu/n8n-stack && ./rotate-key.sh

set -euo pipefail
cd /home/ubuntu/n8n-stack
umask 077

BACKUP_EXPORT="${1:-}"

echo "== 1/5 verific plasa de siguranță =="
if [ -z "$BACKUP_EXPORT" ] || [ ! -s "$BACKUP_EXPORT" ]; then
  echo "   OPRIT: dă-mi calea către exportul decriptat al credențialelor."
  echo "   Fără el, credențialele devin nedecriptabile după rotire."
  echo "   Asistentul îți dă calea exactă."
  exit 1
fi
N=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$BACKUP_EXPORT")
echo "   ok — $N credențiale exportate în clar, recuperabile"

echo "== 2/5 generez cheia nouă =="
NEW=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)
[ ${#NEW} -eq 32 ] || { echo "   EȘUAT: lungime greșită"; exit 1; }
echo "   32 de caractere (nu se afișează)"

echo "== 3/5 scriu în .env =="
cp .env ".env.bak-$(date +%Y%m%d-%H%M%S)"
grep -v '^N8N_ENCRYPTION_KEY=' .env > .env.tmp
printf 'N8N_ENCRYPTION_KEY=%s\n' "$NEW" >> .env.tmp
mv .env.tmp .env
chmod 600 .env
echo "   ok (copie a vechiului .env păstrată alături)"

echo "== 4/5 scriu în volumul n8n_data =="
printf '%s' "$NEW" | docker run --rm -i -v n8n_data:/d --entrypoint sh \
  docker.n8n.io/n8nio/n8n:2.31.7 -c \
  'read -r k; printf "{\n\t\"encryptionKey\": \"%s\"\n}" "$k" > /d/config; chmod 600 /d/config'
echo "   ok"

echo "== 5/5 verific că cele două coincid =="
MATCH=$(docker run --rm -v n8n_data:/d -v /home/ubuntu/n8n-stack:/s:ro --entrypoint node \
  docker.n8n.io/n8nio/n8n:2.31.7 -e '
  const fs=require("fs");
  const cfg=JSON.parse(fs.readFileSync("/d/config","utf8")).encryptionKey;
  const line=fs.readFileSync("/s/.env","utf8").split("\n").find(l=>l.startsWith("N8N_ENCRYPTION_KEY="));
  process.stdout.write(cfg===line.slice(19).trim()?"IDENTICE":"DIFERITE");')
echo "   .env și config: $MATCH"
[ "$MATCH" = "IDENTICE" ] || { echo "   EȘUAT — nu reporni, spune-i asistentului"; exit 1; }

unset NEW
echo
echo "Cheie rotită. Credențialele din baza de date sunt încă criptate cu cea"
echo "VECHE — spune-i asistentului să continue: repornire + re-import."
