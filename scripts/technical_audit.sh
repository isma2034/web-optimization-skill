#!/usr/bin/env bash
# Raw technical evidence-gatherer for a web/SEO/CRO audit.
#
# Usage:
#   technical_audit.sh <base_url> [/path1 /path2 ...] [--json]
#   technical_audit.sh <base_url> --sitemap [sitemap_url] [--json]
#
#   --sitemap [url]   Crawl every real page found in the sitemap instead of
#                      a manual path list. If [url] is omitted, tries
#                      <base_url>/sitemap.xml then <base_url>/sitemap_index.xml.
#                      Recurses automatically through sitemap INDEXES (a
#                      sitemap that lists other sitemaps, e.g. Yoast's
#                      sitemap_index.xml -> post-sitemap.xml + page-sitemap.xml)
#                      — detected by the presence of a <sitemap> tag rather
#                      than a <url> tag. Verified against a real WordPress
#                      site (2 <sitemap> tags in the index, 20/99 <url> tags
#                      in the two sub-sitemaps) before trusting this.
#   --json            Emit structured JSON (one object per page + one
#                      "global" object) instead of human-readable text.
#                      Requires `jq` — aborts with a clear message if it's
#                      not installed, rather than hand-building JSON strings
#                      (string concatenation breaks the moment a <title> or
#                      meta description contains a double quote).
#   --delay N         Seconds to sleep between page requests during a
#                      --sitemap crawl or a multi-path run (default: 1).
#                      NOT OPTIONAL for a real site — a first version of this
#                      script ran two consecutive 119-page crawls against a
#                      real WordPress site on a raw Apache origin (no CDN)
#                      with zero delay between requests, and the site went
#                      unreachable (connection refused, confirmed from a
#                      second independent network path) immediately after.
#                      Never crawl an unknown production site at full speed.
#
# Prints raw findings only — no interpretation, no claims. The skill's job
# is to read this output and decide what's CONFIRMED vs what still needs
# a human/tool check. Never assert something this script didn't actually show.

set -uo pipefail

UA="Mozilla/5.0 (compatible; WebOptAudit/1.0)"

# Load a local PageSpeed Insights API key if one has been configured
# (<repo>/.env — never committed, gitignored,
# never printed by this script). Optional: only used if --pagespeed is
# passed and the key is present.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGESPEED_API_KEY=""
[ -f "$SCRIPT_DIR/../.env" ] && source "$SCRIPT_DIR/../.env"

# ---------------------------------------------------------------------------
# PageSpeed Insights (real Core Web Vitals). Google's own servers run a full
# Lighthouse pass remotely — this takes 5-15+ seconds PER CALL, unlike every
# other check in this script which is a plain curl fetch. Never wire this
# into a --sitemap full crawl by default: on 100+ pages it would turn a
# ~6-minute audit into 20-30+ minutes. Opt-in via --pagespeed, and the
# guided wrapper only ever runs it on the homepage for that reason.
# ---------------------------------------------------------------------------
fetch_pagespeed() {
  local url="$1" strategy="$2"
  if [ -z "$PAGESPEED_API_KEY" ]; then
    echo '{"error":"no_api_key"}'
    return
  fi
  local encoded_url response
  encoded_url=$(printf '%s' "$url" | jq -sRr @uri)
  response=$(curl -sS --max-time 30 "https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=${encoded_url}&strategy=${strategy}&category=performance&key=${PAGESPEED_API_KEY}")
  if [ -z "$response" ]; then
    echo '{"error":"empty_response"}'
    return
  fi
  echo "$response" | jq -c '
    if .error then
      {error: (.error.status // "unknown"), message: .error.message}
    else
      {
        performance_score: (.lighthouseResult.categories.performance.score // null),
        lab_lcp_ms: (.lighthouseResult.audits["largest-contentful-paint"].numericValue // null),
        lab_cls: (.lighthouseResult.audits["cumulative-layout-shift"].numericValue // null),
        lab_tbt_ms: (.lighthouseResult.audits["total-blocking-time"].numericValue // null),
        field_data_category: (.loadingExperience.overall_category // "NO_FIELD_DATA")
      }
    end' 2>/dev/null || echo '{"error":"unparseable_response"}'
}

# ---------------------------------------------------------------------------
# Retry helpers. A single network blip, timeout, or WAF challenge (e.g.
# Cloudflare briefly flagging this script's bot-like User-Agent) must never
# be reported as a confirmed "site is down" / "no sitemap" finding — that's
# exactly the kind of false-confirmed claim this tool exists to prevent.
# Caught in testing: a real, healthy, CDN-fronted site returned one 503 and
# an empty sitemap check on a first pass, then 200/found on an immediate
# re-run — a transient result, not a real fact about the site.
# ---------------------------------------------------------------------------
fetch_status_with_retry() {
  local url="$1" attempt status
  for attempt in 1 2 3; do
    status=$(curl -sS -A "$UA" -o /dev/null -w "%{http_code}" --max-time 15 "$url" 2>/dev/null)
    if [ -n "$status" ] && [ "$status" != "000" ] && [[ ! "$status" =~ ^5 ]]; then
      echo "$status"; return
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "$status"
}

fetch_body_with_retry() {
  local url="$1"; shift
  local attempt body
  for attempt in 1 2 3; do
    body=$(curl -sS -A "$UA" --max-time 20 "$@" "$url" 2>/dev/null)
    [ -n "$body" ] && { echo "$body"; return; }
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "$body"
}

fetch_headers_with_retry() {
  local url="$1" attempt dump status
  for attempt in 1 2 3; do
    dump=$(curl -sS -A "$UA" -D - -o /dev/null -L --max-redirs 10 --max-time 15 "$url" 2>&1)
    status=$(echo "$dump" | grep -Eo '^HTTP/[0-9.]+ [0-9]+' | tail -n 1 | awk '{print $2}')
    if [ -n "$status" ] && [[ ! "$status" =~ ^5 ]]; then
      echo "$dump"; return
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "$dump"
}

fetch_redirect_with_retry() {
  local url="$1" attempt info status
  for attempt in 1 2 3; do
    info=$(curl -sS -A "$UA" -o /dev/null -w "%{url_effective}|%{http_code}" -L --max-time 15 "$url" 2>&1)
    status="${info##*|}"
    if [ -n "$status" ] && [ "$status" != "000" ] && [[ ! "$status" =~ ^5 ]]; then
      echo "$info"; return
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  echo "$info"
}
JSON_MODE=0
SITEMAP_MODE=0
SITEMAP_URL=""
DELAY=1
COUNT_ONLY=0
PAGESPEED_MODE=0
SITEMAP_PAGE_COUNT=0
declare -a PATHS=()

usage() {
  cat >&2 <<'EOF'
Usage:
  technical_audit.sh <base_url> [/path1 /path2 ...] [--json] [--delay N]
  technical_audit.sh <base_url> --sitemap [sitemap_url] [--json] [--delay N]
EOF
  exit 1
}

if [ $# -lt 1 ]; then usage; fi
BASE="${1%/}"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --delay)
      shift
      if [ $# -eq 0 ]; then
        echo "!! --delay requires a numeric argument (seconds)." >&2
        exit 1
      fi
      DELAY="$1"
      shift
      ;;
    --sitemap)
      SITEMAP_MODE=1
      shift
      # optional explicit sitemap URL: only consume it if it doesn't look
      # like another flag or a bare path
      if [ $# -gt 0 ] && [[ "$1" != --* ]] && [[ "$1" != /* ]]; then
        SITEMAP_URL="$1"
        shift
      fi
      ;;
    --count-only)
      COUNT_ONLY=1
      shift
      ;;
    --pagespeed)
      PAGESPEED_MODE=1
      shift
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

if [ "$JSON_MODE" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
  echo "!! --json requires jq, which is not installed on this machine." >&2
  echo "   Install it first: sudo apt install jq" >&2
  exit 1
fi

if [ "$SITEMAP_MODE" -eq 0 ] && [ ${#PATHS[@]} -eq 0 ]; then
  PATHS=("/")
fi

TMPDIR_JSON=""
if [ "$JSON_MODE" -eq 1 ]; then
  TMPDIR_JSON=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_JSON"' EXIT
fi
PAGE_INDEX=0
PAGES_DONE=0

hr() { [ "$JSON_MODE" -eq 0 ] && printf '\n=== %s ===\n' "$1"; }
say() { [ "$JSON_MODE" -eq 0 ] && echo "$@"; }

# ---------------------------------------------------------------------------
# Sitemap crawling: resolves a sitemap (index or leaf) down to real page URLs.
# ---------------------------------------------------------------------------
crawl_sitemap() {
  local sitemap_url="$1"
  local depth="${2:-0}"

  if [ "$depth" -gt 3 ]; then
    say "!! Sitemap recursion depth exceeded at $sitemap_url — stopping to avoid a loop."
    return
  fi

  local xml
  xml=$(fetch_body_with_retry "$sitemap_url" -L)
  if [ -z "$xml" ]; then
    say "!! Empty/unreachable sitemap: $sitemap_url"
    return
  fi

  if echo "$xml" | grep -q '<sitemap>'; then
    # This is a sitemap INDEX (lists other sitemaps), not a page list.
    local sub_sitemaps
    sub_sitemaps=$(echo "$xml" | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g')
    while IFS= read -r sub; do
      [ -z "$sub" ] && continue
      crawl_sitemap "$sub" "$((depth + 1))"
    done <<< "$sub_sitemaps"
  else
    # Leaf sitemap: <loc> entries here are real pages.
    local urls
    urls=$(echo "$xml" | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g')
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      if [[ "$u" =~ \.(jpg|jpeg|png|gif|webp|pdf|xml)$ ]]; then
        continue
      fi
      if [ "$COUNT_ONLY" -eq 1 ]; then
        SITEMAP_PAGE_COUNT=$((SITEMAP_PAGE_COUNT + 1))
      else
        audit_page "$u"
        sleep "$DELAY"
      fi
    done <<< "$urls"
  fi
}

# ---------------------------------------------------------------------------
# Per-page audit. Prints text, or writes a JSON fragment to $TMPDIR_JSON.
# ---------------------------------------------------------------------------
audit_page() {
  local URL="$1"
  hr "PAGE: $URL"
  # Progress indicator on stderr (never stdout, so it can't corrupt --json
  # output) — a multi-minute crawl with zero visible progress looks frozen,
  # especially to someone who doesn't know the tool is working as intended.
  PAGES_DONE=$((PAGES_DONE + 1))
  [ "$JSON_MODE" -eq 1 ] && echo "  [$PAGES_DONE] $URL" >&2

  local HTML
  HTML=$(fetch_body_with_retry "$URL" -L)
  if [ -z "$HTML" ]; then
    say "!! Empty response — page may be blocking curl, redirecting via JS, or path is wrong."
    if [ "$JSON_MODE" -eq 1 ]; then
      PAGE_INDEX=$((PAGE_INDEX + 1))
      jq -n --arg url "$URL" '{url: $url, error: "empty_response"}' > "$TMPDIR_JSON/page_$PAGE_INDEX.json"
    fi
    return
  fi
  # Flatten to one line first: many builders (Elementor, Divi) wrap attributes
  # and split opening/closing tags across lines, which breaks line-based grep
  # and silently under-reports (e.g. "0 H1 found" when one genuinely exists).
  local FLAT
  FLAT=$(echo "$HTML" | tr '\n' ' ' | tr -s ' ')

  local title meta_desc generator canonical
  title=$(echo "$FLAT" | grep -io '<title>[^<]*</title>' | head -n 1 | sed -E 's/<[^>]+>//g')
  # NOTE: these must be double-quoted shell strings so an actual single quote
  # can sit inside the bracket expression. The previous version used \x27
  # hoping grep would treat it as a hex escape for "'" — it doesn't (no -P
  # here), so grep read \x27 as four literal alternatives: \, x, 2, 7. That
  # silently truncated any description/canonical containing one of those
  # characters (e.g. cut "Intervention 7j/7..." right before the "7").
  # Found by a real cross-check against a TypeScript reimplementation of
  # this same check, not by reading the regex.
  # Attribute value helper: reads the value of ATTR from the first tag matching
  # TAGPAT, honouring the quote that actually opened it (so an apostrophe inside
  # a double-quoted value, e.g. content="l'entreprise", is kept intact).
  attr_value() { # $1=tag regex, $2=attribute name
    local tag
    tag=$(echo "$FLAT" | grep -io "$1" | head -n 1)
    [ -z "$tag" ] && return 0
    echo "$tag" | ATTR="$2" perl -ne 'my $a = $ENV{ATTR}; if (/\b\Q$a\E\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)/i) { print defined $1 ? $1 : $2 }'
  }
  meta_desc=$(attr_value "<meta[^>]*name=[\"']description[\"'][^>]*>" content)
  generator=$(attr_value "<meta[^>]*name=[\"']generator[\"'][^>]*>" content)
  canonical=$(attr_value "<link[^>]*rel=[\"']canonical[\"'][^>]*>" href)

  say "--- <title> ---"
  say "$title"
  say "--- meta description ---"
  say "$meta_desc"
  say "--- meta generator (CMS fingerprint) ---"
  say "$generator"

  # H1s: non-greedy match (grep -P) is required. With several <h1> pairs on
  # one flattened line, a greedy .* merges everything between the FIRST <h1>
  # and the LAST </h1> into a single false "1 result" — silently hiding a
  # real multi-H1 problem instead of reporting it. Verified against a page
  # with 11 actual <h1> tags before trusting this.
  local h1count h1_texts
  h1count=$(echo "$FLAT" | grep -oi '<h1[^>]*>' | wc -l)
  h1_texts=$(echo "$FLAT" | perl -ne 'while (/<h1[^>]*>.*?<\/h1>/gi) { print "$&\n" }' | sed -E 's/<[^>]+>//g')
  say "--- H1 count and content ---"
  say "count: $h1count"
  echo "$h1_texts" | nl 2>/dev/null | { [ "$JSON_MODE" -eq 0 ] && cat || cat >/dev/null; }

  say "--- canonical tag ---"
  say "$canonical"

  local ldcount ld_types
  ldcount=$(echo "$FLAT" | grep -o 'application/ld+json' | wc -l)
  ld_types=""
  if [ "$ldcount" -gt 0 ]; then
    ld_types=$(echo "$FLAT" | grep -o '"@type"\s*:\s*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | sort -u)
  fi
  say "--- JSON-LD structured data blocks (count + types) ---"
  say "count: $ldcount"
  [ -n "$ld_types" ] && say "$ld_types"

  local total_img empty_alt no_alt
  total_img=$(echo "$FLAT" | grep -oi '<img[^>]*>' | wc -l)
  empty_alt=$(echo "$FLAT" | grep -oi '<img[^>]*>' | grep -icE 'alt=""|alt='"'"''"'"'' )
  no_alt=$(echo "$FLAT" | grep -oi '<img[^>]*>' | grep -vic 'alt=')
  say "--- images: total vs missing/empty alt ---"
  say "total <img>: $total_img | empty alt=\"\": $empty_alt | no alt attribute at all: $no_alt"

  local mixed_content
  mixed_content=$(echo "$FLAT" | grep -oE 'src="http://[^"]*"|href="http://[^"]*"' | sed -E 's/^(src|href)="//;s/"$//' | sort -u)
  say "--- HTTP asset URLs on this HTTPS page (mixed content) ---"
  [ -n "$mixed_content" ] && say "$mixed_content"

  local ext_domains
  ext_domains=$(echo "$FLAT" | grep -oE '(src|href)="https?://[^"/]+' | sed -E 's/^(src|href)="https?:\/\///' | sort -u | grep -v -F "$(echo "$BASE" | sed -E 's#https?://##')" | head -n 15)
  say "--- external/third-party asset domains referenced ---"
  [ -n "$ext_domains" ] && say "$ext_domains"

  local is_divi is_yoast plugins
  is_divi=$(echo "$FLAT" | grep -qo '?et_blog\|/wp-content/themes/Divi' && echo true || echo false)
  is_yoast=$(echo "$FLAT" | grep -qo 'twitter:label1.*Est\. reading time' && echo true || echo false)
  plugins=$(echo "$FLAT" | grep -oi 'wp-content/plugins/[a-z0-9-]*' | sed -E 's#wp-content/plugins/##' | sort -u | head -n 10)
  say "--- CMS/theme fingerprints ---"
  [ "$is_divi" = "true" ] && say "Divi theme signature found"
  [ "$is_yoast" = "true" ] && say "Yoast SEO signature found (est. reading time meta)"
  [ -n "$plugins" ] && say "$plugins"

  local form_count dup_ids
  form_count=$(echo "$FLAT" | grep -oci '<form')
  dup_ids=$(echo "$FLAT" | grep -oi 'id="[^"]*"' | sed -E 's/id="([^"]*)"/\1/' | sort | uniq -d | head -n 10)
  say "--- forms: count + duplicate form indicators ---"
  say "<form> tags: $form_count"
  [ -n "$dup_ids" ] && echo "$dup_ids" | sed 's/^/duplicate id attribute: /' | { [ "$JSON_MODE" -eq 0 ] && cat || cat >/dev/null; }

  local has_tel
  has_tel=$(echo "$FLAT" | grep -qoi 'tel:' && echo true || echo false)
  say "--- sticky/fixed mobile call element heuristics (best-effort, verify visually) ---"
  [ "$has_tel" = "true" ] && say "tel: link present somewhere in HTML (does not confirm it's a mobile sticky button — check visually)"

  local pagespeed_mobile="null"
  if [ "$PAGESPEED_MODE" -eq 1 ]; then
    if [ -z "$PAGESPEED_API_KEY" ]; then
      say "--- PageSpeed Insights (real Core Web Vitals) ---"
      say "!! --pagespeed requested but no PAGESPEED_API_KEY configured in .env — skipped."
    else
      say "--- PageSpeed Insights (real Core Web Vitals, mobile) ---"
      pagespeed_mobile=$(fetch_pagespeed "$URL" "mobile")
      say "$pagespeed_mobile"
    fi
  fi

  if [ "$JSON_MODE" -eq 1 ]; then
    PAGE_INDEX=$((PAGE_INDEX + 1))
    jq -n \
      --arg url "$URL" \
      --arg title "$title" \
      --arg meta_description "$meta_desc" \
      --arg generator "$generator" \
      --arg canonical "$canonical" \
      --argjson h1_count "$h1count" \
      --arg h1_texts "$h1_texts" \
      --argjson json_ld_count "$ldcount" \
      --arg json_ld_types "$ld_types" \
      --argjson img_total "$total_img" \
      --argjson img_empty_alt "$empty_alt" \
      --argjson img_no_alt "$no_alt" \
      --arg mixed_content "$mixed_content" \
      --arg external_domains "$ext_domains" \
      --argjson is_divi "$is_divi" \
      --argjson is_yoast "$is_yoast" \
      --arg plugins "$plugins" \
      --argjson form_count "$form_count" \
      --arg duplicate_ids "$dup_ids" \
      --argjson has_tel_link "$has_tel" \
      --argjson pagespeed_mobile "$pagespeed_mobile" \
      '{
        url: $url,
        seo: {
          title: $title,
          meta_description: $meta_description,
          canonical: $canonical,
          h1: { count: $h1_count, texts: ($h1_texts | split("\n") | map(select(length > 0))) },
          structured_data: { json_ld_blocks: $json_ld_count, types: ($json_ld_types | split("\n") | map(select(length > 0))) }
        },
        images: { total: $img_total, empty_alt: $img_empty_alt, no_alt: $img_no_alt },
        security: {
          mixed_http_content: ($mixed_content | split("\n") | map(select(length > 0))),
          external_domains: ($external_domains | split("\n") | map(select(length > 0)))
        },
        cms: { generator: $generator, divi_detected: $is_divi, yoast_detected: $is_yoast, plugins: ($plugins | split("\n") | map(select(length > 0))) },
        forms: { count: $form_count, duplicate_ids: ($duplicate_ids | split("\n") | map(select(length > 0))) },
        cro: { tel_link_present: $has_tel_link },
        performance: { pagespeed_mobile: $pagespeed_mobile }
      }' > "$TMPDIR_JSON/page_$PAGE_INDEX.json"
  fi
}

# ---------------------------------------------------------------------------
# --count-only: just resolve the sitemap recursively and report how many
# REAL pages it contains, without auditing any of them and without running
# the (unrelated) site-wide checks. Exists because counting top-level <loc>
# entries in sitemap_index.xml gives the number of SUB-SITEMAPS, not real
# pages (caught while building the guided wrapper — a site with a 2-entry
# sitemap index was reported as "2 pages" when it actually had far more).
# ---------------------------------------------------------------------------
if [ "$COUNT_ONLY" -eq 1 ]; then
  if [ -z "$SITEMAP_URL" ]; then
    for sm in "sitemap.xml" "sitemap_index.xml"; do
      code=$(fetch_status_with_retry "$BASE/$sm")
      if [ "$code" = "200" ]; then
        SITEMAP_URL="$BASE/$sm"
        break
      fi
    done
  fi
  if [ -z "$SITEMAP_URL" ]; then
    echo "0"
    exit 0
  fi
  crawl_sitemap "$SITEMAP_URL"
  echo "$SITEMAP_PAGE_COUNT"
  exit 0
fi

# ---------------------------------------------------------------------------
# Site-wide checks. All raw data goes into variables first, and is only
# printed via `say`/`hr` (silent in JSON mode) — nothing here writes to
# stdout unguarded, because a single leaked line breaks `--json` output
# (caught during testing: two bare sitemap lines landed before the `{`
# and made the JSON unparseable by `jq empty`).
# ---------------------------------------------------------------------------
headers_dump=$(fetch_headers_with_retry "$BASE/")
final_status=$(echo "$headers_dump" | grep -Eo '^HTTP/[0-9.]+ [0-9]+' | tail -n 1 | awk '{print $2}')
hsts_present=$(echo "$headers_dump" | grep -qi '^strict-transport-security:' && echo true || echo false)

HTTP_URL="${BASE/https:\/\//http://}"
http_redirect_info=$(fetch_redirect_with_retry "$HTTP_URL/")
http_final_url="${http_redirect_info%%|*}"
http_final_status="${http_redirect_info##*|}"

robots_status=$(fetch_status_with_retry "$BASE/robots.txt")
robots_body=""
[ "$robots_status" = "200" ] && robots_body=$(fetch_body_with_retry "$BASE/robots.txt")

hr "HEADERS & REDIRECTS (base URL)"
say "$headers_dump"
hr "HTTP -> HTTPS check"
say "http:// request -> final: $http_final_url  status: $http_final_status"
hr "robots.txt"
say "$robots_body"
say "[status: $robots_status]"

declare -a SITEMAP_JSON_PARTS=()
# Always runs, even in --sitemap mode: this only checks whether a sitemap
# EXISTS (cheap — a handful of status checks), independent of the fuller
# recursive crawl. Skipping it in --sitemap mode left global.sitemaps empty
# even after a real sitemap had just been used to enumerate 107 pages,
# producing a contradictory report ("sitemap found, 107 pages" followed by
# "no sitemap found") — caught by actually reading the generated summary,
# not just checking the JSON was valid.
hr "sitemap.xml / sitemap_index.xml"
for sm in "sitemap.xml" "sitemap_index.xml" "sitemap-index.xml"; do
  code=$(fetch_status_with_retry "$BASE/$sm")
  say "$sm -> HTTP $code"
  loc_count=0
  if [ "$code" = "200" ]; then
    sm_body=$(fetch_body_with_retry "$BASE/$sm")
    say "$(echo "$sm_body" | grep -o '<loc>[^<]*</loc>' | head -n 20)"
    loc_count=$(echo "$sm_body" | grep -c '<loc>')
    say "... ($loc_count <loc> entries total, first 20 shown)"
  fi
  if [ "$JSON_MODE" -eq 1 ]; then
    SITEMAP_JSON_PARTS+=("$(jq -n --arg file "$sm" --argjson status "$code" --argjson loc_count "$loc_count" '{file: $file, status: $status, loc_count: $loc_count}')")
  fi
done

if [ "$JSON_MODE" -eq 1 ]; then
  sitemap_json_array="[]"
  if [ ${#SITEMAP_JSON_PARTS[@]} -gt 0 ]; then
    sitemap_json_array=$(printf '%s\n' "${SITEMAP_JSON_PARTS[@]}" | jq -s '.')
  fi
  jq -n \
    --argjson final_status "${final_status:-0}" \
    --argjson hsts_present "$hsts_present" \
    --arg http_final_url "$http_final_url" \
    --argjson http_final_status "${http_final_status:-0}" \
    --arg robots_status "$robots_status" \
    --arg robots_body "$robots_body" \
    --argjson sitemaps "$sitemap_json_array" \
    '{
      https: { status: $final_status, hsts_present: $hsts_present },
      http_to_https_redirect: { final_url: $http_final_url, status: $http_final_status },
      robots_txt: { status: ($robots_status | tonumber), body: $robots_body },
      sitemaps: $sitemaps
    }' > "${TMPDIR_JSON}/global.json"
fi

# ---------------------------------------------------------------------------
# Run: either the sitemap crawl, or the manual path list
# ---------------------------------------------------------------------------
if [ "$SITEMAP_MODE" -eq 1 ]; then
  if [ -z "$SITEMAP_URL" ]; then
    for sm in "sitemap.xml" "sitemap_index.xml"; do
      code=$(fetch_status_with_retry "$BASE/$sm")
      if [ "$code" = "200" ]; then
        SITEMAP_URL="$BASE/$sm"
        break
      fi
    done
    if [ -z "$SITEMAP_URL" ]; then
      echo "!! Could not auto-find a sitemap at $BASE/sitemap.xml or $BASE/sitemap_index.xml — pass one explicitly." >&2
      exit 1
    fi
  fi
  say "Crawling sitemap: $SITEMAP_URL"
  crawl_sitemap "$SITEMAP_URL"
else
  for p in "${PATHS[@]}"; do
    audit_page "$BASE$p"
    sleep "$DELAY"
  done
fi

if [ "$JSON_MODE" -eq 1 ]; then
  # Merge via FILES (--slurpfile), never via a shell string passed as a
  # command-line argument (--argjson "$big_string"). Caught on a real
  # 107-page crawl: the assembled pages array was large enough (titles,
  # plugin lists, external domains, H1 texts...) to hit the OS argument-list
  # size limit — "jq: Liste d'arguments trop longue" — silently producing
  # an EMPTY final file. Worked fine at small scale (1-5 pages) in earlier
  # testing, which is exactly why this only showed up at real-world size.
  [ ! -f "$TMPDIR_JSON/global.json" ] && echo '{}' > "$TMPDIR_JSON/global.json"
  if ls "$TMPDIR_JSON"/page_*.json >/dev/null 2>&1; then
    jq -s '.' "$TMPDIR_JSON"/page_*.json > "$TMPDIR_JSON/pages_array.json"
  else
    echo '[]' > "$TMPDIR_JSON/pages_array.json"
  fi
  jq -n --slurpfile global "$TMPDIR_JSON/global.json" --slurpfile pages "$TMPDIR_JSON/pages_array.json" \
    '{ global: $global[0], pages: $pages[0] }'
else
  hr "NEXT — cannot be done with curl, do these manually"
  cat <<'EOF'
- PageSpeed Insights / Core Web Vitals: https://pagespeed.web.dev/ (paste each URL, mobile AND desktop)
- Indexation count: Google search "site:yourdomain.com" and compare to real page count from sitemap
- Rich Results Test (validates structured data actually works): https://search.google.com/test/rich-results
- Stack fingerprint confirmation: Wappalyzer browser extension
- Backlinks / domain authority: Search Console (client's own access) — do not guess this from a third-party aggregator
- If lighthouse CLI is installed: `npx lighthouse <url> --quiet --chrome-flags="--headless" --output=json --output-path=./lighthouse.json`
EOF
fi
