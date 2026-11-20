---
name: web-optimization
description: Use this skill when auditing or optimizing a website for SEO and conversion (CRO) — technical SEO audits, Core Web Vitals, structured data, local SEO for service businesses, or drafting a client-facing audit/report. Also use it before quoting or promising specific website work to a client, so claims are evidence-backed rather than guessed.
version: 0.1.0
---

# Web Optimization (SEO + CRO) Audits

## Why this skill exists

When you sell website or ad optimization to small local businesses or larger
B2B clients, the core risk isn't lack of effort — it's **asserting things
you haven't actually verified**. A wrong claim on a sales call or in a report
costs far more credibility than an honest "I need to check that." This skill
makes the audit process itself produce evidence, so you never have to bluff.

## The one rule that matters more than any checklist

**Every finding is either CONFIRMED (you have direct evidence) or TO VERIFY
(you have a hypothesis, not evidence).** Never present a TO VERIFY item as a
fact. Say it as a question instead.

- CONFIRMED example: "The `/services/` page has 10 `<h1>` tags — I counted
  them in the page source." → state it as fact, cite the evidence.
- TO VERIFY example: "This looks like a page-builder site with a lot of
  images, so page speed might be an issue." → do NOT say "your site is slow."
  Ask: "Have you checked your Core Web Vitals recently?" or go measure it
  first (most of these ARE measurable in a few minutes).
- Never repeat a third-party data aggregator's numbers (revenue, headcount,
  tech stack) as fact — they are frequently stale or wrong. Verify directly
  or don't mention them.

A false CONFIRMED claim is far worse than an honest "still checking".

## Process

### 1. Gather raw evidence — read the source, don't eyeball the rendered page

```bash
bash scripts/technical_audit.sh https://example.com / /contact /services
```

Pass every important path (home, contact, key service pages, one blog post).
It prints raw findings only: titles, meta description, H1 count and text,
canonical tag, JSON-LD types, image alt-text coverage, mixed HTTP content on
an HTTPS page, CMS/theme/plugin fingerprints, robots.txt, sitemap.xml (and
page count), form count, duplicate `id` attributes.

Other modes:
- `--sitemap [url]` crawls every page in the sitemap (resolves sitemap
  indexes recursively).
- `--json` emits `{ global: {...}, pages: [...] }` (requires `jq`).
- `--pagespeed` adds real Core Web Vitals through the PageSpeed Insights API
  (needs `PAGESPEED_API_KEY` in `.env`, see `.env.example`).

`scripts/audit_guide.sh` is the no-flags version: it asks for the site
address, picks a safe delay, and writes a plain-language `resume.txt` plus
`donnees.json` to `~/Audits-Web/<domain>/<date>/`. Its output is in French.

**Respect `--delay N` (default 1 s) on any real site, especially `--sitemap`
crawls.** Never set it to 0 on a site you don't control: a crawl with no pause
against an origin server without a CDN can take it offline. Check the response
headers first — `server: cloudflare` (or similar) means a CDN absorbs load; a
bare `Server: Apache/...` or `nginx/...` means every request hits the origin,
so be more conservative.

**Known blind spots — silence is not proof of absence:**
- Content injected by JavaScript (forms, popups, chat widgets) never appears
  in curl's output. `<form> tags: 0` means "not in the static HTML", not
  "no form exists".
- A `tel:` link somewhere is not a sticky mobile call button — check on a
  phone-width viewport.
- Duplicate `id` attributes can be a real bug or a harmless shared id (a
  widget's own id). Open the page before calling it a bug.

### 2. Fill the gaps the script can't reach (about 15–20 min)

- **PageSpeed Insights** (pagespeed.web.dev) — each key URL, mobile and
  desktop.
- **Indexation**: compare `site:domain.com` with the real page count from the
  sitemap, or better, use Search Console if the client gives access.
- **Rich Results Test** (search.google.com/test/rich-results) — the answer to
  "does structured data actually work", not just "is a JSON-LD block present".
- **Wappalyzer** to confirm the stack beyond HTML fingerprints.
- **Google Business Profile** (local businesses): NAP consistency with the
  site footer, category, review count and recency — check the live listing.

### 3. CRO pass — conversion, not just crawlability

- Is there a sticky/fixed call button on mobile? (verify visually)
- Is the quote/contact form reachable in 1–2 clicks from the homepage?
- Is there a lead-capture mechanism for visitors who don't convert at once?
- Do images actually load?
- Is there a clear above-the-fold value proposition and CTA?
- Are trust signals visible fast (phone, reviews, service area, availability)?

Where possible, tie a proposed fix to a number from the client's own data
(clicks, leads, cost per lead) rather than a vague "your site could be better".

### 4. Local SEO specifics

- NAP consistency across the site, Google Business Profile and directories.
- Locally scoped landing pages per city/zone vs. one generic page.
- LocalBusiness schema in the JSON-LD types the script reports.

### 5. Report the findings

| Status | Finding | Evidence |
|---|---|---|
| Confirmed | ... | exactly what you saw (URL, tag, tool + timestamp) |
| To verify | phrased as a question for the client | why it matters if true |

Open the report with a short **"Method and scope"** note: which pages and
tools you actually used, and that unverifiable items are flagged as questions.
It pre-empts objections and is the highest-leverage sentence for credibility.

## What NOT to do

- Don't repeat unverified third-party data as if you measured it.
- Don't promise a specific ranking or traffic outcome — talk about actions
  and leading indicators (indexation, Core Web Vitals, structured data,
  conversion rate).
- Don't ask for more access than the work requires; say why when you do.
