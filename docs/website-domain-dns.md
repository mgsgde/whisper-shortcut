# Website domain and DNS (whispershortcut.com)

Two different hosts use this domain:

| Host | Service | Purpose |
|------|---------|--------|
| **whispershortcut.com** (apex) | GitHub Pages | Static marketing site (homepage, privacy, terms). See `.github/workflows/pages.yml`. |
| **www.whispershortcut.com** | Cloud Run **whisper-account** | Next.js account dashboard (Google sign-in, balance, Stripe). Region: `europe-west1`. |

---

## Cloud Run: www → whisper-account

The account app is mapped in **Google Cloud Console → Cloud Run → Manage custom domains** (or **APIs & Services → Domain verification** for the domain, then map in Cloud Run):

1. **Add mapping** → Select service **whisper-account** (europe-west1).
2. **Select verified domain** → `whispershortcut.com`.
3. **Subdomain** → `www` (so the mapping is for **https://www.whispershortcut.com**).
4. **Update DNS records** → Add this CNAME at your DNS provider:

   | Type  | Hostname | Points to           | TTL   |
   |-------|----------|---------------------|-------|
   | CNAME | `www`    | `ghs.googlehosted.com.` | 3600 (1 h) |

Add that CNAME at your DNS provider for `www.whispershortcut.com`. After propagation, https://www.whispershortcut.com will serve the whisper-account app. Ensure production env has **NEXTAUTH_URL=https://www.whispershortcut.com** (the account app uses www; see `apps/account/app/site.ts`).

---

## GitHub Pages: apex (whispershortcut.com)

The static site uses the apex domain as custom domain in the repo’s **Settings → Pages → Custom domain**. No www mapping to GitHub Pages if www is used for Cloud Run.

---

## DNS at IONOS (reference)

Relevant records for the site and account app (mail/verification omitted):

| Typ  | Hostname | Wert / Ziel              | Zweck                    |
|------|----------|--------------------------|--------------------------|
| A    | `@`      | 216.239.32.21, .34.21, .36.21, .38.21 | Apex → GitHub Pages      |
| AAAA | `@`      | 2001:4860:4802:32/34/36/38::15       | Apex IPv6 → GitHub Pages |
| CNAME| `www`    | ghs.googlehosted.com     | www → Cloud Run (whisper-account) |

---

## References

- [GitHub Docs: Managing a custom domain for your GitHub Pages site](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)
- [Google Cloud: Map a custom domain to a Cloud Run service](https://cloud.google.com/run/docs/mapping-custom-domains)
