#!/bin/bash
# ============================================================================
#  firewall-cloudflare.sh — inchide originea la rangeurile Cloudflare.
#
#  PROBLEMA pe care o rezolva:
#  https://203.0.113.10/ intorcea 200 cu pagina de login n8n completa
#  (22 KB). Blocul nginx de pe 443 e singurul site activ, deci e si
#  default_server si prinde orice Host — inclusiv un IP brut. Cloudflare
#  ascunde originea doar daca originea nu raspunde direct; altfel WAF-ul si
#  rate limiting-ul de la CDN se ocolesc trivial, lovind IP-ul.
#
#  CE FACE: 80/443 acceptate DOAR de la rangeurile Cloudflare. Restul —
#  respins la nivel de kernel, inainte sa ajunga la nginx.
#
#  DE CE 22 RAMANE DESCHIS CATRE ORICINE: IP-ul de administrare
#  (198.51.100.7 la 2026-07-31) e pe un ISP rezidential, deci dinamic. O
#  regula legata de el te blocheaza afara la urmatorul lease. Daca vrei sa
#  strangi surubul: `ufw limit 22/tcp` in loc de `allow` adauga rate limiting
#  (blocheaza un IP la 6 conexiuni in 30s).
#
#  DEFAULT_FORWARD_POLICY=ACCEPT — obligatoriu, altfel Sofia moare.
#  ufw isi insereaza lanturile in fruntea FORWARD, inaintea DOCKER-USER. Cu
#  politica DROP, doar conexiunile deja stabilite trec (regula conntrack din
#  before.rules), iar orice conexiune NOUA dinspre containere catre Facebook
#  sau OpenAI e taiata. Cu ACCEPT, filtrarea forward ramane a lui Docker, care
#  isi tine oricum propria politica DROP plus DOCKER-USER/DOCKER-ISOLATION.
#  Nu expune porturi de container: fara o regula DNAT in nat/PREROUTING —
#  create doar pentru porturile publicate, iar singurul publicat e
#  127.0.0.1:5678 — pachetele din exterior nu ajung la IP-urile RFC1918 ale
#  containerelor.
#
#  Rangeurile Cloudflare se schimba rar, dar se schimba. Aceleasi rangeuri
#  stau si in /etc/nginx/conf.d/cloudflare-realip.conf. Reimprospatarea
#  amandurora: ./refresh-cloudflare-ips.sh
#
#  Rulare: sudo ./firewall-cloudflare.sh
# ============================================================================
set -euo pipefail

# cron ruleaza cu PATH=/usr/bin:/bin, iar `ufw` si `nginx` stau in /usr/sbin.
# Fara linia asta scriptul merge perfect din shell si pica din cron — si pica
# exact in luna in care Cloudflare chiar schimba rangeurile, fiindca pana atunci
# iese devreme cu "nimic de facut" si pare sanatos.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

V4_URL=https://www.cloudflare.com/ips-v4
V6_URL=https://www.cloudflare.com/ips-v6
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ruleaza cu sudo"; exit 1; }

echo "== 1. iau rangeurile Cloudflare =="
curl -fsS --max-time 20 "$V4_URL" -o "$TMP/v4" || { echo "FAIL ips-v4"; exit 1; }
curl -fsS --max-time 20 "$V6_URL" -o "$TMP/v6" || { echo "FAIL ips-v6"; exit 1; }

# ATENTIE: niciunul din cele doua raspunsuri nu se termina cu newline. Un
# `cat v4 v6` lipeste ultimul range v4 de primul v6 ("131.0.72.0/222400:cb00::/32")
# si ufw raspunde "Bad source address". `awk 1` normalizeaza terminatorul.
awk 1 "$TMP/v4" "$TMP/v6" > "$TMP/all"

# Validare inainte de a baga orice in firewall: fiecare linie trebuie sa fie un
# CIDR gol-golut. Daca Cloudflare returneaza vreodata o pagina de eroare HTML,
# fara verificarea asta ai transforma-o in reguli.
if grep -qvE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$TMP/all"; then
  echo "CONTINUT NEASTEPTAT de la Cloudflare — nu ating firewall-ul:"
  grep -nvE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$TMP/all"
  exit 1
fi
N4=$(grep -c . "$TMP/v4"); N6=$(grep -c . "$TMP/v6")
# Sub 10 v4 inseamna raspuns trunchiat, nu o schimbare reala de politica.
[ "$N4" -ge 10 ] || { echo "doar $N4 rangeuri v4 — suspect, ma opresc"; exit 1; }
echo "   $N4 rangeuri v4, $N6 rangeuri v6"

echo "== 2. DEFAULT_FORWARD_POLICY=ACCEPT (vezi antetul) =="
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
grep '^DEFAULT_FORWARD_POLICY' /etc/default/ufw | sed 's/^/   /'

echo "== 3. politici implicite =="
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null

echo "== 4. SSH INAINTE de orice — asta e regula care te tine inauntru =="
ufw allow 22/tcp comment 'ssh — admin' >/dev/null
echo "   allow 22/tcp"

echo "== 5. 80/443 doar de la Cloudflare =="
# ORDINEA CONTEAZA: adaug INTAI, sterg DUPA.
# Invers — sterg toate regulile 'cloudflare' si apoi le readaug — lasa un
# interval de ~30s (44 de invocari ufw, fiecare lenta) in care regulile pur si
# simplu nu exista, iar conexiunile NOI de la Cloudflare pica. Conntrack tine
# in viata doar ce e deja stabilit. Adica un mic outage la fiecare rulare care
# chiar schimba ceva — exact cand nu vrei.
# Re-adaugarea unei reguli identice e gratuita: ufw raspunde "Skipping adding
# existing rule", deci pasul asta e idempotent.
while read -r cidr; do
  [ -n "$cidr" ] || continue
  ufw allow proto tcp from "$cidr" to any port 80,443 comment 'cloudflare' >/dev/null
done < "$TMP/all"

# Abia acum scot regulile 'cloudflare' ramase pentru rangeuri pe care Cloudflare
# nu le mai publica. Numerele se renumeroteaza dupa fiecare stergere, deci reiau
# lista de la capat de fiecare data in loc sa colectez numerele dinainte.
removed=0
while :; do
  stale=$(ufw status numbered | grep '# cloudflare' | while read -r l; do
            c=$(echo "$l" | awk '{for (i=1; i<=NF; i++) if ($i == "#") print $(i-1)}')
            grep -qxF "$c" "$TMP/all" || { echo "$l"; break; }
          done | head -1)
  [ -n "$stale" ] || break
  n=$(echo "$stale" | sed 's/^\[ *\([0-9]*\)\].*/\1/')
  ufw --force delete "$n" >/dev/null
  removed=$((removed + 1))
done
echo "   $((N4+N6)) rangeuri active, $removed invechite sterse"

echo "== 6. activez =="
ufw --force enable
echo
ufw status verbose | head -12
