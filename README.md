# web-optimization

A small, dependency-light toolkit (plus a Claude Code skill) for **evidence-based
website audits**: SEO, technical health and conversion basics.

The idea in one sentence: send real HTTP requests, print back raw, checkable
facts about a site's code, and never state anything to a client that you
haven't actually verified.

- Plain Bash + `curl` (+ `perl`, and `jq` for `--json`). No install step.
- Every finding is either **Confirmed** (you have the evidence) or **To verify**
  (a hypothesis, phrased as a question). See [`SKILL.md`](SKILL.md) for the method.
- Polite by default: 1 second between requests, never a crawl unless you ask.

## Quick start

```bash
git clone https://github.com/isma2034/web-optimization-skill.git
cd web-optimization-skill

# Audit a few pages
bash scripts/technical_audit.sh https://example.com / /contact /services

# Crawl every page listed in the sitemap (sitemap indexes are resolved)
bash scripts/technical_audit.sh https://example.com --sitemap --delay 2

# Structured output (needs jq)
bash scripts/technical_audit.sh https://example.com / --json
```

Prefer no flags? `bash scripts/audit_guide.sh` asks for the site address, picks a
safe delay and writes a plain-language summary (`resume.txt`) and `donnees.json`
to `~/Audits-Web/<domain>/<date>/`. Its messages are in French.

## What it checks

**Site-wide:** response headers and redirects, HTTP to HTTPS, `robots.txt`,
`sitemap.xml` / sitemap index (with real page count).

**Per page:** title, meta description, `<h1>` count and text, canonical tag,
JSON-LD blocks and their `@type`s, image alt coverage, mixed http/https content,
third-party domains, CMS/theme/plugin fingerprints, form count and duplicate
`id` attributes, `tel:` links.

**Core Web Vitals (optional):** `--pagespeed` calls the PageSpeed Insights API
for one URL. Copy `.env.example` to `.env` and add your own free key. `.env` is
git-ignored and never printed.

## What it cannot see (and says so)

- Anything rendered by JavaScript after load. `<form> tags: 0` means "not in the
  static HTML", not "no form".
- Real indexation (use Search Console) and Rich Results eligibility (Google's
  Rich Results Test has no public API).
- Visual CRO checks such as a sticky mobile call button: check on a phone-width
  viewport.

Silence is never proof of absence. The end of every run lists what to verify by hand.

## Be careful with `--sitemap`

Crawling a real site with no pause can take a small origin server offline.
Keep `--delay` at 1 second or more, and only crawl sites you own or have
permission to audit. Check the `server:` header first: a CDN absorbs load, a
bare `Apache` or `nginx` does not.

## Use it as a Claude Code skill

Copy or symlink this folder into `~/.claude/skills/web-optimization`. Claude will
then run the audit, separate Confirmed from To verify, and help draft the report.

## Contributing

Issues and pull requests are welcome. If you add a check, test it on a page where
you already know the right answer, and prefer non-greedy matching or a per-tag
loop over one big regex on flattened HTML. Greedy matching merging several tags
into one result is this tool's recurring failure mode.

## License

MIT, see [`LICENSE`](LICENSE).
