# WordPress sites and Caddy hostnames

## Goal

Serve every installed WordPress site on this VM, including inactive, archived, spammed, or deleted multisite records, without manually editing Caddy for each domain. Single-site installations use their configured home URL. This is routing only: it does not change a site's URL in WordPress or rewrite stored content.

## Discovery

`/scripts/refresh-sites.municipio.sh` runs WP-CLI inside the **local** Municipio container. On multisite it runs `wp site list --field=domain` without status filters, so records are not excluded based on site state. On single-site it reads `home_url()`.

The script uses `--skip-plugins --skip-themes` to keep discovery independent of plugin/theme health. For multisite, each site's `domain` column must contain its effective public hostname (including any mapped domain). If domain mapping exists only in a plugin and not in the WordPress multisite table, correct the WordPress source of truth first; the generator cannot safely infer that mapping.

WP-CLI output is validated as a hostname. Unicode IDNs are converted to ASCII A-labels (`xn--...`) before insertion into Caddy; DNS and certificate names use those same A-labels. Invalid or empty output fails the refresh and leaves the previous list in place. Domains are sorted and deduplicated.

## Apex and `www`

The installed Public Suffix List distinguishes registrable apex domains from subdomains, including domains such as `example.co.uk`. An apex domain receives an additional `www.` hostname; subdomains never do. Thus `example.com` adds `www.example.com`, while `blog.example.com` does not add `www.blog.example.com`. A site recorded as `www.example.com` does not implicitly add the bare domain. Both hostnames are proxied to the same local container; WordPress decides whether to redirect to its canonical URL.

The distro's `psl` command checks the Public Suffix List. Keep it updated with normal OS package updates. A newly introduced public suffix may need a package update before apex classification is correct. The `idn2` command converts Unicode names to IDNA2008 A-labels.

## Caddy configuration and refresh

The generator writes `/etc/caddy/municipio-sites.caddy`, a Caddyfile fragment with one host block per hostname. `/etc/caddy/Caddyfile` imports that file and provides the common local proxy/health snippet. Caddy's `import` reads the text when configuration is adapted or reloaded; it does not watch the file itself.

A systemd timer refreshes every minute, and the command can be run immediately after adding or editing a WordPress site:

```bash
sudo /scripts/refresh-sites.municipio.sh
sudo cat /etc/caddy/municipio-sites.caddy
sudo systemctl status municipio-sites.timer
```

The refresh validates a candidate Caddyfile before installing it and reloads Caddy only when content changes. A failed WP-CLI query or validation keeps the previous list. On a fresh cluster VM, before the app is running, installation seeds the file from `SITE_ADDRESS`; bootstrap/join refreshes it from WordPress after starting the app. On an existing VM whose app is temporarily down, reinstall retains its existing list.

When `CADDY_SITE_ADDRESS=:80`, each generated address has an explicit `http://` prefix, for upstream TLS termination. Otherwise Caddy manages HTTPS for each hostname. Public DNS, TLS validation, and the upstream HTTP load balancer must be ready for every hostname before traffic can work. The load balancer must preserve `Host`; `/healthz` checks should use a registered hostname.

In a two-node cluster, refresh runs on each VM against its own local container. After editing sites, run the refresh on both nodes and compare generated files before relying on round-robin routing. The periodic timer converges them, but it is not an atomic cross-node deployment mechanism.

## Changing a site's domain

Change the domain in WordPress using a separate, reviewed database/content migration and update DNS and TLS first. The refresh command only discovers the result. For multisite, verify the site's `domain` field reflects the new hostname; for single-site, verify `home_url()` does. A force-SSL plugin changes the scheme, not historical hostnames in stored links.
