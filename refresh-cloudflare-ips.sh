#!/bin/bash
# ============================================================================
#  refresh-cloudflare-ips.sh — resincronizeaza rangeurile Cloudflare in
#  AMANDOUA locurile care le folosesc.
#
#  DE CE EXISTA: din 2026-07-31 rangeurile Cloudflare nu mai sunt doar o
#  optimizare cosmetica pentru loguri — sunt singurul lucru care lasa traficul
#  sa intre. `firewall-cloudflare.sh` a inchis 80/443 la ele. Daca Cloudflare
#  adauga un range si lista de aici ramane veche, traficul de pe acel range e
#  respins de kernel si o parte din utilizatori nu mai ajung deloc la Sofia.
#  Simptomul e urat de diagnosticat: site-ul merge perfect din browserul tau,
#  dar o felie de trafic dispare fara nicio eroare in logurile n8n.
#
#  Cele doua locuri:
#    1. /etc/nginx/conf.d/cloudflare-realip.conf — de la ce IP-uri nginx are
#       voie sa creada antetul CF-Connecting-IP (altfel logurile si rate
#       limiting-ul vad IP-ul Cloudflare, nu clientul real)
#    2. regulile ufw cu comentariul 'cloudflare' — cine poate deschide 80/443
#
#  Nota: fisierul era referit in antetul lui cloudflare-realip.conf inca de pe
#  2026-07-27, dar nu a existat pana pe 2026-07-31; lista din nginx fusese
#  pusa de mana.
#
#  Rulare: sudo ./refresh-cloudflare-ips.sh
#  Cron:   lunar (vezi `crontab -l` la utilizatorul ubuntu)
# ============================================================================
set -euo pipefail

# cron ruleaza cu PATH=/usr/bin:/bin, iar `nginx` si `ufw` stau in /usr/sbin.
# Vezi comentariul identic din firewall-cloudflare.sh: fara asta, jobul lunar
# ar fi esuat fix in luna in care avea ceva de facut.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF=/etc/nginx/conf.d/cloudflare-realip.conf
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ruleaza cu sudo"; exit 1; }

echo "== iau rangeurile =="
curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4 -o "$TMP/v4" || { echo "FAIL ips-v4"; exit 1; }
curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6 -o "$TMP/v6" || { echo "FAIL ips-v6"; exit 1; }
# Niciun raspuns nu se termina cu newline — `awk 1` repara terminatorul.
awk 1 "$TMP/v4" "$TMP/v6" > "$TMP/all"

if grep -qvE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$TMP/all"; then
  echo "CONTINUT NEASTEPTAT de la Cloudflare — nu ating nimic:"
  grep -nvE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$TMP/all"
  exit 1
fi
N=$(grep -c . "$TMP/all")
[ "$N" -ge 15 ] || { echo "doar $N rangeuri — suspect de trunchiere, ma opresc"; exit 1; }

# Daca nimic nu s-a schimbat, nu atinge nginx si nu reincarca degeaba.
if [ -f "$CONF" ] && diff -q <(grep -oE '^set_real_ip_from [^;]+;' "$CONF" | awk '{print $2}' | tr -d ';') \
                            <(cat "$TMP/all") >/dev/null 2>&1; then
  echo "   $N rangeuri, identice cu ce e deja instalat — nimic de facut"
  exit 0
fi
echo "   $N rangeuri, DIFERITE de ce e instalat — actualizez"

echo "== 1. nginx =="
{
  echo "# Cloudflare real client IP — generat $(date -Is) de refresh-cloudflare-ips.sh"
  echo "# Sursa: https://www.cloudflare.com/ips-v4 si /ips-v6"
  echo "#"
  echo "# nginx accepta antetul CF-Connecting-IP DOAR de la aceste rangeuri."
  echo "# De la orice alt IP, \$remote_addr ramane IP-ul real al conexiunii,"
  echo "# deci antetul nu poate fi falsificat de cineva care loveste originea direct."
  echo "#"
  echo "# ACEEASI lista sta si in regulile ufw (comentariul 'cloudflare'), unde"
  echo "# decide cine poate deschide 80/443. Nu edita una fara cealalta —"
  echo "# ruleaza scriptul asta, le face pe amandoua."
  echo
  while read -r c; do [ -n "$c" ] && echo "set_real_ip_from $c;"; done < "$TMP/all"
  echo
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > "$TMP/conf"

cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
cp "$TMP/conf" "$CONF"
if nginx -t 2>&1 | sed 's/^/   /'; then
  systemctl reload nginx
  echo "   nginx reincarcat"
else
  echo "   nginx -t A PICAT — refac fisierul vechi"
  cp "$(ls -t "$CONF".bak-* | head -1)" "$CONF"
  exit 1
fi

echo "== 2. ufw =="
"$HERE/firewall-cloudflare.sh"
