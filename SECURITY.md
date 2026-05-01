# Security Reference — WordPress HA Infrastructure

Complete documentation of every security measure in this stack, how it works, and where it's configured.

---

## Table of Contents

- [Security Architecture](#security-architecture)
- [Network Security](#network-security)
- [Host-Level Hardening](#host-level-hardening)
- [Container Security](#container-security)
- [TLS / SSL](#tls--ssl)
- [Application Security (WordPress)](#application-security-wordpress)
- [Database Security](#database-security)
- [Cache Security](#cache-security)
- [Bot Protection](#bot-protection)
- [Secrets Management](#secrets-management)
- [File Permissions](#file-permissions)
- [Security Verification](#security-verification)
- [Known Gaps & Recommendations](#known-gaps--recommendations)

---

## Security Architecture

```
                         Internet
                            │
                     ┌──────▼───────┐
                     │  UFW Firewall│  DROP all INPUT, ACCEPT OUTPUT
                     │  Ports only: │  80/tcp, 443/tcp, 2222/tcp
                     │  80 443 2222 │  Route allow: 10.89.0.0/24
                     └──────┬───────┘
                            │
                     ┌──────▼───────┐
                     │  Nginx (LB)  │  TLS termination
                     │  10.89.0.2   │  Security headers
                     └──────┬───────┘  Bot filtering via Anubis
                     ┌──────┴───────┐
                     │ Anubis Bot   │  Challenge / Allow / Deny
                     │  10.89.0.5   │  Policy-based filtering
                     └──────┬───────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
      ┌───────▼───────┐         ┌────────▼────────┐
      │  WP Node 1    │         │  WP Node 2      │
      │  10.89.0.31   │         │  10.89.0.32     │  PHP-FPM 8.2
      │  Rootless     │         │  Rootless        │  No exposed ports
      └───────┬───────┘         └────────┬────────┘
              │                          │
              │    ┌──────────┐          │
              └───►│  Redis   │◄─────────┘  Password-protected
                   │ 10.89.0.20│            No external access
                   └──────┬───┘
                          │
                  ┌───────▼───────┐
                  │    MySQL      │  Password auth
                  │  10.89.0.10   │  No root remote login
                  └───────────────┘  No external access
```

**Principle**: No database, cache, or application port is exposed to the internet. Only Nginx (80/443) and SSH (2222) are reachable externally. All internal communication stays within the Podman bridge network `10.89.0.0/24`.

---

## Network Security

### Firewall (UFW)

**Configured in**: `srv/salt/security/init.sls`, `srv/salt/security/files/ufw.jinja`

| Setting | Value | Purpose |
|---------|-------|---------|
| Default INPUT policy | `DROP` | Block all incoming traffic unless explicitly allowed |
| Default OUTPUT policy | `ACCEPT` | Allow all outbound traffic |
| Default FORWARD policy | `DROP` | Block forwarding unless explicitly allowed |
| Logging | `low` | Log blocked packets for audit |
| Allow SSH | Port `2222/tcp` | Non-standard SSH port to reduce scan noise |
| Allow HTTP | Port `80/tcp` | HTTP redirect + ACME challenges |
| Allow HTTPS | Port `443/tcp` | TLS-terminated WordPress traffic |
| Route allow | `10.89.0.0/24` | Permit container network traffic through the bridge |

**Pillar reference**: `srv/pillar/network.sls` — `ssh_port`, `http_port`, `https_port`, `subnet`

### Podman Network Isolation

**Configured in**: `srv/salt/podman/init.sls`

| Setting | Value | Purpose |
|---------|-------|---------|
| Network name | `wp-network` | Dedicated bridge, isolated from host networking |
| Subnet | `10.89.0.0/24` | Private address range, not routable on the internet |
| Gateway | `10.89.0.1` | Container gateway |
| Static IPs | Per-service | MySQL `.10`, Redis `.20`, WP `.31/.32`, Nginx `.2`, Anubis `.5` |

No container port is published to the host except Nginx (80/443). MySQL (3306) and Redis (6379) are only accessible within the bridge network.

---

## Host-Level Hardening

### SSH

**Configured in**: `srv/salt/security/files/sshd_config.jinja`

| Setting | Value | Purpose |
|---------|-------|---------|
| Port | `2222` (configurable) | Non-standard port reduces brute-force log noise |
| PermitRootLogin | `prohibit-password` | Root login only via SSH key, never password |
| PasswordAuthentication | `no` | Require SSH keys for all users |
| PermitEmptyPasswords | `no` | Prevent empty password logins |
| MaxAuthTries | `3` | Limit authentication attempts per connection |
| MaxSessions | `5` | Limit concurrent sessions per connection |
| KbdInteractiveAuthentication | `no` | Disable keyboard-interactive auth |
| X11Forwarding | `no` | Disable X11 forwarding |
| AllowTcpForwarding | `no` | Disable SSH tunneling |
| AllowAgentForwarding | `no` | Disable agent forwarding |
| PermitTunnel | `no` | Disable tunnel device forwarding |
| LogLevel | `VERBOSE` | Log all SSH authentication attempts |
| SyslogFacility | `AUTH` | Send logs to auth facility |

#### SSH Cryptographic Settings

| Setting | Value |
|---------|-------|
| Ciphers | `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com` |
| MACs | `hmac-sha2-512-etm@openssh.com`, `hmac-sha2-256-etm@openssh.com` |
| KexAlgorithms | `curve25519-sha256`, `curve25519-sha256@libssh.org`, `diffie-hellman-group16-sha512` |

These settings disable legacy algorithms (CBC mode, SHA-1, DH group14 and below) and use only modern, authenticated encryption.

---

## Container Security

### Rootless Podman

**Configured in**: `srv/salt/podman/init.sls`, `srv/pillar/users.sls`

| Setting | Value | Purpose |
|---------|-------|---------|
| Runtime user | `podman-wp` (UID 1001) | Dedicated unprivileged user, no shell access to host services |
| User type | `system` | System account, no interactive login intended |
| Subordinate UID range | `100000-165535` | User namespace mapping — container UID 0 maps to host UID 100000 |
| Subordinate GID range | `100000-165535` | Group namespace mapping — same isolation for groups |
| Systemd linger | Enabled | User services survive logout |
| SELinux labels | `z` suffix on all volumes | Proper SELinux context for shared container volumes |

#### How Rootless Security Works

```
Container process thinks it's UID 0 (root)
         │
         ▼ mapped via /etc/subuid
Host sees it as UID 100000+ (unprivileged)
         │
         ▼
Even if container is compromised,
attacker has zero host privileges
```

- Container "root" is mapped to an unprivileged UID range on the host
- Container processes cannot access host filesystem, other users' processes, or privileged operations
- No daemon runs as host root (unlike Docker)
- `containers.conf` and `storage.conf` are managed per-user, not system-wide

### Health Checks

Every container has a health check configured, ensuring systemd auto-restarts failed services:

| Container | Health Check | Restart Policy |
|-----------|-------------|----------------|
| MySQL | `mysqladmin ping` | `on-failure`, 5s delay |
| Redis | `redis-cli ping` | `on-failure`, 5s delay |
| WP Node 1 | PHP-FPM status ping | `on-failure`, 5s delay |
| WP Node 2 | PHP-FPM status ping | `on-failure`, 5s delay |
| Nginx | `curl localhost/health` | `on-failure`, 5s delay |
| Anubis | No-op (always healthy) | `on-failure`, 5s delay |

### Systemd Service Dependencies

Containers are managed as systemd user services with enforced dependency ordering:

```
container-mysql  ←  container-redis  ←  container-wp-node1
                                      ←  container-wp-node2  ←  container-nginx
                                                               ←  container-anubis
```

If MySQL dies, all dependent containers are stopped. When MySQL recovers, dependents restart in order.

---

## TLS / SSL

**Configured in**: `srv/salt/nginx/files/nginx.conf.jinja`, `srv/salt/nginx/files/entrypoint.sh.jinja`

### Certificate Provisioning

1. On first start, Nginx attempts **Let's Encrypt** via `certbot certonly --standalone`
2. If Let's Encrypt fails (DNS not ready, rate limit), falls back to **self-signed** certificates
3. Automatic renewal via **cron job** running every 12 hours inside the container

### TLS Configuration

| Setting | Value | Purpose |
|---------|-------|---------|
| Protocols | `TLSv1.2`, `TLSv1.3` | Disable SSLv3, TLS 1.0, TLS 1.1 |
| Cipher suites | ECDHE + AES-GCM / CHACHA20 only | Forward secrecy, AEAD ciphers |
| `ssl_prefer_server_ciphers` | `off` | Let client choose (TLS 1.3 best practice) |
| `ssl_session_cache` | `shared:SSL:10m` | Session resumption (~40k sessions) |
| `ssl_session_timeout` | `1d` | Resume sessions for 24 hours |
| `ssl_session_tickets` | `off` | Disable stateful tickets for forward secrecy |
| `server_tokens` | `off` | Hide Nginx version from responses |

### HTTP → HTTPS Redirect

All HTTP traffic on port 80 is redirected to HTTPS with a `301` permanent redirect. Port 80 is only kept open for ACME challenges during certificate renewal.

---

## Application Security (WordPress)

### wp-config.php Hardening

**Configured in**: `srv/salt/wordpress/files/wp-config.php.jinja`

| Setting | Value | Purpose |
|---------|-------|---------|
| `FORCE_SSL_ADMIN` | `true` | Force HTTPS for all admin pages (`/wp-admin/`, `/wp-login.php`) |
| `DISALLOW_FILE_EDIT` | `true` | Disable theme/plugin file editor in admin (prevents PHP execution via admin UI) |
| `WP_DEBUG` | `false` | No error disclosure to visitors |
| `WP_DEBUG_LOG` | `false` | No debug logging in production |
| `WP_SITEURL` | `https://<domain>` | Enforce HTTPS in site URLs |
| `WP_HOME` | `https://<domain>` | Enforce HTTPS in home URLs |
| `WP_CONTENT_URL` | `https://<domain>/wp-content` | Enforce HTTPS for content URLs |

### Authentication Keys and Salts

Eight unique 64-character hex strings generated via `openssl rand -hex 32`:

- `AUTH_KEY`, `SECURE_AUTH_KEY`, `LOGGED_IN_KEY`, `NONCE_KEY`
- `AUTH_SALT`, `SECURE_AUTH_SALT`, `LOGGED_IN_SALT`, `NONCE_SALT`

These salt cookies and nonces. If any salt is rotated, all existing user sessions are invalidated.

### Session Storage

PHP sessions are stored in Redis (not on disk):

```php
ini_set('session.save_handler', 'redis');
ini_set('session.save_path', 'tcp://10.89.0.20:6379?auth=<password>');
```

Sessions are encrypted in transit (Redis AUTH) and never written to the local filesystem.

---

## Database Security

### MySQL 8.0

**Configured in**: `srv/salt/mysql/init.sls`, `srv/salt/mysql/files/init.sql.jinja`

| Setting | Value | Purpose |
|---------|-------|---------|
| Network binding | `10.89.0.10` only | No host exposure — accessible only within Podman bridge |
| Root password | Set via pillar | Mandatory root authentication |
| Application user | `wordpress` (least privilege) | Dedicated user with access to `wordpress` database only |
| Test database | Dropped on init | `DROP DATABASE IF EXISTS test` |
| Anonymous users | Dropped on init | `DROP USER IF EXISTS ''@'%'` and `''@'localhost'` |
| Character set | `utf8mb4` | Full Unicode support (including emojis) |
| Collation | `utf8mb4_unicode_ci` | Correct Unicode sorting |
| Data directory | `/srv/wp/mysql/data` | Persistent, owned by `podman-wp` |

### Least-Privilege Grant

```sql
GRANT ALL PRIVILEGES ON `wordpress`.* TO 'wordpress'@'%';
```

The WordPress application user only has access to the `wordpress` database, not system tables or other databases.

---

## Cache Security

### Redis 7

**Configured in**: `srv/salt/redis/init.sls`

| Setting | Value | Purpose |
|---------|-------|---------|
| Network binding | `10.89.0.20` only | No host exposure |
| Authentication | `--requirepass <password>` | Password required for all commands |
| Max memory | `256mb` | Prevent Redis from consuming all host memory |
| Eviction policy | `allkeys-lru` | Evict least-recently-used keys when memory is full |
| Data persistence | RDB snapshots in `/srv/wp/redis/data` | Survives container restarts |

Redis is not exposed on any host port. Only containers on `wp-network` can reach it.

---

## Bot Protection

### Anubis

**Configured in**: `srv/salt/anubis/init.sls`, `srv/salt/anubis/files/bot-policy.yaml.jinja`

Anubis sits between Nginx and the WordPress application, filtering traffic before it reaches PHP.

#### Policy Rules (evaluated in order, first match wins)

| Rule | Action | User Agents |
|------|--------|-------------|
| `allow-search-engines` | **ALLOW** | Googlebot, Bingbot, Slurp, DuckDuckBot, Baiduspider, YandexBot, facebookexternalhit, Twitterbot, LinkedInBot |
| `block-known-bad` | **DENY** | SemrushBot, AhrefsBot, MJ12bot, DotBot, SeznamBot, python-requests, Go-http-client, httpclient |
| `challenge-unknown` | **CHALLENGE** | `.*` (everything else) |

#### How the Challenge Works

1. Unknown browser/client requests any page
2. Anubis returns a JavaScript challenge (proof-of-work)
3. Legitimate browsers solve the challenge automatically
4. Bots without JS execution capability are blocked
5. Search engines bypass the challenge entirely (ALLOW rule)

#### Network Position

```
Nginx → Anubis (10.89.0.5:8923) → WordPress upstream
```

All traffic passes through Anubis before reaching PHP-FPM. Failed challenges never touch the WordPress application.

---

## Secrets Management

### Current Approach

Secrets are stored in **Salt pillar files** (`srv/pillar/secrets.sls`):

| Secret | Generation Method |
|--------|------------------|
| `mysql_root_password` | `openssl rand -hex 16` (32 hex chars) |
| `mysql_wp_password` | `openssl rand -hex 16` (32 hex chars) |
| `redis_password` | `openssl rand -hex 16` (32 hex chars) |
| `wp_auth_key` through `wp_nonce_salt` | `openssl rand -hex 32` (64 hex chars each) |

### Secret Distribution

```
secrets.sls (pillar)
       │
       ├─► wp-config.php.jinja  (WordPress salts, DB creds, Redis password)
       ├─► init.sql.jinja       (MySQL user creation)
       ├─► redis.service.jinja  (Redis requirepass)
       └─► mysql.service.jinja  (MySQL root password)
```

Secrets are rendered into configs at `salt-call state.apply` time. They are not baked into container images.

### gitignore

`secrets.sls` must be in `.gitignore` and never committed to version control. The file should have `chmod 600` permissions (owner read/write only).

---

## File Permissions

**Configured in**: various Salt states

| Path | Mode | Owner | Purpose |
|------|------|-------|---------|
| `/srv/wp/mysql/data/` | `0750` | `podman-wp:podman-wp` | Database files — no world-readable |
| `/srv/wp/redis/data/` | `0750` | `podman-wp:podman-wp` | Redis snapshots |
| `/srv/wp/nginx/ssl/` | `0700` | `podman-wp:podman-wp` | Private keys — most restrictive |
| `/srv/wp/nginx/conf/` | `0750` | `podman-wp:podman-wp` | Nginx configs |
| `/srv/wp/uploads/` | `0750` | `podman-wp:podman-wp` | WordPress media uploads |
| `/srv/wp/wp-content/` | `0750` | `podman-wp:podman-wp` | Plugins and themes |
| `wp-config.php` | `0644` (read-only mount) | Mounted `:ro` | WordPress config — immutable in container |
| `nginx.conf` | `0644` (read-only mount) | Mounted `:ro` | Nginx config — immutable in container |

All data directories are owned by the unprivileged `podman-wp` user. The root user can read but the `podman-wp` user cannot escalate.

### Read-Only Mounts

Sensitive configuration files are mounted as read-only (`:ro`) inside containers:

- `wp-config.php` — WordPress cannot modify its own config
- `nginx.conf` — Nginx cannot modify its own config
- `bot-policy.yaml` — Anubis cannot modify its own policy

---

## Security Verification

### Quick Audit Checklist

Run these commands after deployment to verify the security posture:

```bash
# 1. Verify firewall is active and restrictive
sudo ufw status verbose
# Expected: Status: active, Default: deny (incoming), allow (outgoing)

# 2. Verify only expected ports are open
sudo ss -tlnp | grep -E 'LISTEN'
# Expected: :80, :443, :2222 only

# 3. Verify SSH is on non-standard port and key-only
sudo sshd -T | grep -E 'port|passwordauthentication|permitrootlogin'
# Expected: port 2222, passwordauthentication no, permitrootlogin prohibit-password

# 4. Verify MySQL is not exposed externally
sudo ss -tlnp | grep 3306
# Expected: no output (not bound to host)

# 5. Verify Redis is not exposed externally
sudo ss -tlnp | grep 6379
# Expected: no output (not bound to host)

# 6. Verify SSL configuration
curl -sI https://<domain> | grep -i 'strict-transport'
# Expected: strict-transport-security header with long max-age

# 7. Verify security headers
curl -sI https://<domain> | grep -iE 'x-frame|x-content-type|x-xss|referrer'
# Expected: all four headers present

# 8. Verify Nginx version is hidden
curl -sI https://<domain> | grep -i server
# Expected: no version number in Server header

# 9. Verify hidden files are blocked
curl -sI https://<domain>/.env
# Expected: 403 Forbidden or 404 Not Found

# 10. Verify PHP version is hidden
curl -sI https://<domain>/index.php | grep -i x-powered-by
# Expected: no X-Powered-By header

# 11. Verify containers are rootless
ps aux | grep podman | head -5
# Expected: all processes owned by podman-wp, not root

# 12. Verify file permissions on secrets
ls -la /srv/wp/nginx/ssl/
# Expected: drwx------ (0700)
```

### Nginx Security Headers Audit

These headers are set on every response:

| Header | Value | Mitigates |
|--------|-------|-----------|
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` | SSL stripping, forces HTTPS for 2 years |
| `X-Frame-Options` | `SAMEORIGIN` | Clickjacking — only same-origin framing |
| `X-Content-Type-Options` | `nosniff` | MIME-type sniffing attacks |
| `X-XSS-Protection` | `1; mode=block` | Reflected XSS in older browsers |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Information leakage via Referer header |

### Hidden File Protection

Nginx blocks access to dotfiles and sensitive paths:

```nginx
location ~ /\. {
    deny all;
    log_not_found off;
    access_log off;
}
```

This blocks access to `.htaccess`, `.env`, `.git`, and any other hidden files.

---

## Known Gaps & Recommendations

### Current Limitations

| Area | Gap | Risk Level |
|------|-----|------------|
| **Single MySQL** | No replication or failover | High — database is a single point of failure |
| **Single Redis** | No Sentinel or Cluster | Medium — cache loss causes performance degradation |
| **No automated backups** | Only manual backup scripts documented | High — data loss risk without offsite backups |
| **No monitoring** | No metrics, alerting, or dashboards | Medium — issues go undetected until user reports |
| **Secrets in plaintext** | Pillar files contain unencrypted passwords | Medium — file read = full credential exposure |
| **No rate limiting** | Nginx does not rate-limit requests | Low — Anubis mitigates bot floods, but not targeted abuse |
| **No WAF** | No ModSecurity / Coraza | Medium — no application-layer attack detection |
| **No intrusion detection** | No file integrity monitoring | Medium — compromised files may go unnoticed |
| **No audit logging** | WordPress admin actions not logged | Low — no forensic trail for admin changes |

### Recommended Next Steps (Priority Order)

1. **Automated offsite backups** — daily MySQL dumps + file sync to S3/B2, with restore testing
2. **Prometheus + Grafana** — container metrics, Nginx stub status, MySQL/Redis exporters
3. **MySQL replication** — add a read replica for failover and read scaling
4. **Varnish or FastCGI cache** — full-page caching to reduce PHP load
5. **SOPS or age encryption** — encrypt `secrets.sls` at rest in the git repo
6. **CrowdSec** — collaborative IP reputation with Podman support
7. **ModSecurity / Coraza WAF** — OWASP core rule set for WordPress
8. **Redis Sentinel** — automatic failover for the cache layer
9. **Network segmentation** — separate Podman networks for frontend / app / data tiers
10. **UFW rate limiting** — `ufw limit 2222/tcp` for SSH brute-force protection
