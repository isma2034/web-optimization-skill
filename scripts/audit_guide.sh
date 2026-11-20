#!/usr/bin/env bash
# Point d'entrée SIMPLE et guidé pour l'outil d'audit — pensé pour quelqu'un
# qui ne connaît ni curl, ni jq, ni les sitemaps. Pose des questions en
# français, prend les décisions de sécurité (délai entre requêtes) à ta
# place, et range les résultats dans un dossier daté au lieu de tout
# afficher en vrac dans le terminal.
#
# Usage : audit_guide.sh   (aucun argument, tout se passe en questions)
#
# Ce script ne réinvente rien : il pilote technical_audit.sh (le moteur
# déjà testé) et transforme son JSON en résumé lisible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/technical_audit.sh"
OUT_ROOT="$HOME/Audits-Web"

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Il manque un outil requis : jq."
  echo "   Lance d'abord : sudo apt install -y jq"
  exit 1
fi

echo "=========================================="
echo " Audit de site web — Google Ads / SEO / CRO"
echo "=========================================="
echo ""

# --- 1. Demander et nettoyer l'URL -----------------------------------------
read -rp "Quelle est l'adresse du site à auditer ? (ex: exemple.com) : " RAW_URL
RAW_URL=$(echo "$RAW_URL" | xargs)  # enlève les espaces avant/après
if [ -z "$RAW_URL" ]; then
  echo "❌ Aucune adresse saisie, on arrête là."
  exit 1
fi
if [[ ! "$RAW_URL" =~ ^https?:// ]]; then
  RAW_URL="https://$RAW_URL"
fi
BASE="${RAW_URL%/}"

echo ""
echo "→ Site à vérifier : $BASE"
echo ""

# --- 2. Vérifier que le site répond avant de faire quoi que ce soit --------
echo "Je vérifie que le site répond..."
CHECK=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$BASE/" 2>/dev/null)
if [ -z "$CHECK" ] || [ "$CHECK" = "000" ]; then
  echo "❌ Le site ne répond pas (adresse incorrecte, site down, ou connexion bloquée)."
  echo "   Vérifie l'adresse et réessaie plus tard."
  exit 1
fi
echo "✅ Le site répond (code $CHECK)."
echo ""

# --- 3. Détecter s'il y a un CDN devant le site (Cloudflare, etc.) ---------
# Sans CDN, chaque requête arrive directement sur le serveur du client —
# on doit être plus prudent sur le nombre de requêtes/seconde.
HEADERS=$(curl -sS -D - -o /dev/null --max-time 10 "$BASE/" 2>/dev/null)
if echo "$HEADERS" | grep -qi 'cloudflare\|fastly\|cloudfront\|akamai'; then
  DELAY=1
  echo "ℹ️  Un CDN a été détecté devant ce site (ex: Cloudflare) — délai standard entre requêtes."
else
  DELAY=2
  echo "⚠️  Aucun CDN détecté — ce site encaisse directement chaque requête."
  echo "   Par sécurité, on va prendre notre temps (délai plus long entre chaque page)."
fi
echo ""

# --- 4. Combien de pages sur ce site ? --------------------------------------
# Utilise --count-only : résout le sitemap récursivement (y compris un
# sitemap-index qui liste d'autres sitemaps) pour compter les VRAIES pages,
# pas juste les fichiers sitemap de premier niveau.
echo "Je regarde combien de pages ce site contient (via son sitemap)..."
TOTAL_PAGES=$("$ENGINE" "$BASE" --sitemap --count-only 2>/dev/null | tail -n 1)
if [ -z "$TOTAL_PAGES" ] || ! [[ "$TOTAL_PAGES" =~ ^[0-9]+$ ]]; then TOTAL_PAGES=0; fi

if [ "$TOTAL_PAGES" -gt 0 ]; then
  echo "✅ Sitemap trouvé — environ $TOTAL_PAGES page(s) listée(s)."
else
  echo "⚠️  Aucun sitemap exploitable trouvé — seule la page d'accueil pourra être testée."
fi
echo ""

# --- 5. Choix du type d'audit ------------------------------------------------
echo "Que veux-tu faire ?"
echo "  1) Audit rapide       — juste la page d'accueil (quelques secondes)"
if [ "$TOTAL_PAGES" -gt 0 ]; then
  # Le délai de sécurité n'est qu'une partie du temps réel : chaque page a
  # aussi un vrai temps réseau (souvent 1 à 3s). Sous-estimer ça donne un
  # temps annoncé faux, ce qui fait croire que l'outil est planché en
  # plein audit alors qu'il tourne normalement (bug trouvé en testant un
  # vrai audit de 107 pages : "2 min" annoncées, ~5 min réelles).
  EST_MIN=$(( (TOTAL_PAGES * (DELAY + 2)) / 60 + 1 ))
  echo "  2) Audit complet      — les $TOTAL_PAGES pages du site (environ $EST_MIN min, on ne brusque pas le serveur)"
fi
read -rp "Ton choix (1 ou 2) : " CHOICE
echo ""

STAMP=$(date "+%Y-%m-%d_%Hh%M")
DOMAIN=$(echo "$BASE" | sed -E 's#https?://##; s#[^A-Za-z0-9.-]#_#g')
OUT_DIR="$OUT_ROOT/$DOMAIN/$STAMP"
mkdir -p "$OUT_DIR"
JSON_OUT="$OUT_DIR/donnees.json"

# PageSpeed (vraies Core Web Vitals) : uniquement sur la page d'accueil,
# jamais sur un crawl complet — chaque appel prend 5-15s (Google exécute un
# vrai test Lighthouse à distance), donc l'ajouter à 107 pages transformerait
# un audit de 6 minutes en 20-30+.
HAS_PAGESPEED_KEY=0
if [ -f "$SCRIPT_DIR/../.env" ] && grep -q '^PAGESPEED_API_KEY=.\+' "$SCRIPT_DIR/../.env"; then
  HAS_PAGESPEED_KEY=1
fi

PAGESPEED_JSON="$OUT_DIR/pagespeed_accueil.json"

if [ "$CHOICE" = "2" ] && [ "$TOTAL_PAGES" -gt 0 ]; then
  echo "Audit complet en cours — merci de patienter, on ne brusque pas le serveur du client..."
  "$ENGINE" "$BASE" --sitemap --json --delay "$DELAY" > "$JSON_OUT"
  if [ "$HAS_PAGESPEED_KEY" -eq 1 ]; then
    echo "Vérification de la vitesse réelle de la page d'accueil (PageSpeed Insights)..."
    "$ENGINE" "$BASE" / --pagespeed --json --delay 0 > "$PAGESPEED_JSON" 2>/dev/null
  fi
else
  if [ "$HAS_PAGESPEED_KEY" -eq 1 ]; then
    echo "Audit rapide en cours (avec vérification de vitesse réelle)..."
    "$ENGINE" "$BASE" / --pagespeed --json --delay "$DELAY" > "$JSON_OUT"
    cp "$JSON_OUT" "$PAGESPEED_JSON"
  else
    echo "Audit rapide en cours..."
    "$ENGINE" "$BASE" / --json --delay "$DELAY" > "$JSON_OUT"
  fi
fi

if ! jq empty "$JSON_OUT" 2>/dev/null; then
  echo "❌ Quelque chose s'est mal passé, les résultats ne sont pas exploitables."
  echo "   Fichier brut conservé ici pour investigation : $JSON_OUT"
  exit 1
fi

# --- 6. Résumé en langage clair ---------------------------------------------
SUMMARY_OUT="$OUT_DIR/resume.txt"

{
  echo "Résumé d'audit — $BASE"
  echo "Date : $(date '+%d/%m/%Y %H:%M')"
  echo "Pages analysées : $(jq '.pages | length' "$JSON_OUT")"
  echo ""
  echo "--- Fondations du site ---"

  https_status=$(jq -r '.global.https.status' "$JSON_OUT")
  if [ "$https_status" = "200" ]; then echo "✅ Le site est bien accessible en HTTPS."
  else echo "❌ Problème d'accès en HTTPS (code $https_status)."; fi

  robots_status=$(jq -r '.global.robots_txt.status' "$JSON_OUT")
  if [ "$robots_status" = "200" ]; then echo "✅ Fichier robots.txt présent."
  else echo "⚠️  Pas de fichier robots.txt trouvé (code $robots_status) — à vérifier, pas forcément grave."; fi

  sitemap_ok=$(jq '[.global.sitemaps[]? | select(.status == 200)] | length' "$JSON_OUT")
  if [ "$sitemap_ok" -gt 0 ]; then echo "✅ Sitemap présent."
  else echo "⚠️  Aucun sitemap trouvé — Google a plus de mal à découvrir toutes les pages."; fi

  echo ""
  echo "--- Points techniques à vérifier (trouvés sur au moins une page) ---"

  n_h1_multi=$(jq '[.pages[] | select(.error == null) | select(.seo.h1.count != 1)] | length' "$JSON_OUT")
  [ "$n_h1_multi" -gt 0 ] && echo "⚠️  $n_h1_multi page(s) ont plusieurs (ou zéro) titre H1 principal — dilue le référencement de la page."

  n_mixed=$(jq '[.pages[] | select(.error == null) | select((.security.mixed_http_content | length) > 0)] | length' "$JSON_OUT")
  [ "$n_mixed" -gt 0 ] && echo "⚠️  $n_mixed page(s) chargent une ressource non sécurisée (http) sur une page https."

  n_dup_forms=$(jq '[.pages[] | select(.error == null) | select((.forms.duplicate_ids | length) > 0)] | length' "$JSON_OUT")
  [ "$n_dup_forms" -gt 0 ] && echo "⚠️  $n_dup_forms page(s) ont un formulaire dupliqué dans le code (bug technique, peut fausser le suivi)."

  n_no_schema=$(jq '[.pages[] | select(.error == null) | select(.seo.structured_data.json_ld_blocks == 0)] | length' "$JSON_OUT")
  [ "$n_no_schema" -gt 0 ] && echo "⚠️  $n_no_schema page(s) n'ont aucune donnée structurée (JSON-LD) — moins de chances d'avoir un résultat enrichi sur Google."

  n_errors=$(jq '[.pages[] | select(.error != null)] | length' "$JSON_OUT")
  [ "$n_errors" -gt 0 ] && echo "⚠️  $n_errors page(s) n'ont pas pu être chargées du tout (à revérifier manuellement)."

  # Vitesse réelle (PageSpeed) — vraie donnée si une clé API est configurée,
  # sinon ça reste dans la liste "à faire à la main" plus bas.
  pagespeed_ok=0
  pagespeed_bad=0
  if [ -f "$PAGESPEED_JSON" ] && jq empty "$PAGESPEED_JSON" 2>/dev/null; then
    psi=$(jq -c '.pages[0].performance.pagespeed_mobile // empty' "$PAGESPEED_JSON" 2>/dev/null)
    if [ -n "$psi" ] && [ "$(echo "$psi" | jq -r '.error // empty')" = "" ]; then
      pagespeed_ok=1
      score=$(echo "$psi" | jq -r '.performance_score')
      lcp_ms=$(echo "$psi" | jq -r '.lab_lcp_ms')
      field_cat=$(echo "$psi" | jq -r '.field_data_category')
      score_pct=$(awk "BEGIN{printf \"%.0f\", $score*100}")
      lcp_s=$(awk "BEGIN{printf \"%.1f\", $lcp_ms/1000}")
      if awk "BEGIN{exit !($lcp_ms > 2500)}"; then
        pagespeed_bad=1
        echo "⚠️  Vitesse mobile réelle (page d'accueil) : score ${score_pct}/100, chargement principal (LCP) ${lcp_s}s — Google considère qu'un bon score est sous 2,5s. Donnée terrain (vrais visiteurs) : $field_cat."
      else
        echo "✅ Vitesse mobile réelle (page d'accueil) : score ${score_pct}/100, LCP ${lcp_s}s — dans les clous. Donnée terrain : $field_cat."
      fi
    fi
  fi

  if [ "$n_h1_multi" -eq 0 ] && [ "$n_mixed" -eq 0 ] && [ "$n_dup_forms" -eq 0 ] && [ "$n_no_schema" -eq 0 ] && [ "$n_errors" -eq 0 ] && [ "$pagespeed_bad" -eq 0 ]; then
    echo "✅ Aucun problème technique évident détecté sur les points vérifiables automatiquement."
  fi

  echo ""
  echo "--- Ce qui reste à vérifier À LA MAIN (impossible à automatiser) ---"
  if [ "$pagespeed_ok" -eq 0 ]; then
    echo "- Vitesse réelle / Core Web Vitals : https://pagespeed.web.dev/ (ou configure une clé API PageSpeed dans .env pour l'automatiser)"
  fi
  echo "- Nombre de pages réellement indexées par Google : idéalement via l'API Search Console (si tu as accès au compte du client) plutôt qu'une recherche \"site:$DOMAIN\" manuelle"
  echo "- Rich Results Test (résultats enrichis) : https://search.google.com/test/rich-results"
  echo ""
  echo "Données brutes complètes (JSON) : $JSON_OUT"
} | tee "$SUMMARY_OUT"

echo ""
echo "=========================================="
echo "Terminé. Tout est sauvegardé dans :"
echo "  $OUT_DIR"
echo "=========================================="
