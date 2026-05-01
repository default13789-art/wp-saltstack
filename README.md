# WordPress HA Infrastructure

Production-grade WordPress deployment using **SaltStack** configuration management and **Rootless Podman** containers. Designed for security, high availability, and reproducibility on Ubuntu 24.04 LTS.

## Features

- **High Availability** — Two WordPress PHP-FPM nodes behind Nginx load balancer (least_conn)
- **Rootless Containers** — All services run as an unprivileged user via Podman user namespaces
- **Bot Protection** — Anubis policy engine filters, challenges, or blocks traffic before it hits PHP
- **TLS by Default** — Let's Encrypt auto-provisioning with HTTP/2, modern ciphers, HSTS preload
- **Object Caching** — Redis 7 for WordPress object cache and PHP session storage
- **SaltStack Managed** — Idempotent, repeatable, version-controlled infrastructure
- **Hardened Host** — UFW firewall (default DROP), SSH key-only auth on non-standard port, strong ciphers only
- **Monitoring Stack** — Prometheus + Grafana with pre-built dashboards for Node, MySQL, Redis, and Nginx metrics
- **Automated Backups** — Daily MySQL dumps, uploads, config, and Redis snapshots with rotation and restore
- **Intrusion Prevention** — Fail2ban with SSH, Nginx HTTP auth, and WordPress login jails (UFW bans)
- **Rate Limiting** — Nginx request/connection limits + wp-login.php brute-force protection
- **Secrets Encryption** — SOPS + age encryption for secrets at rest in the git repository
- **Container Auto-Updates** — Podman native auto-update with automatic rollback on health check failure
- **WordPress Maintenance** — Automated core/plugin/theme updates, DB optimization, transient cleanup via WP-CLI

## Architecture

```
                     Internet
                        │
                 ┌──────▼───────┐
                 │  UFW Firewall│  Ports: 80, 443, 2222 only
                 └──────┬───────┘
                 ┌──────▼───────┐
                 │  Nginx (LB)  │  TLS termination, security headers, rate limiting
                 │  10.89.0.2   │  grafana.<domain> proxy
                 └──────┬───────┘
                 ┌──────▼───────┐
                 │ Anubis Bot   │  Allow / Challenge / Deny
                 │  10.89.0.5   │
                 └──────┬───────┘
                        │
          ┌─────────────┴─────────────┐
          │                           │
  ┌───────▼───────┐         ┌────────▼────────┐
  │  WP Node 1    │         │  WP Node 2      │
  │  10.89.0.31   │         │  10.89.0.32     │  PHP 8.2 FPM
  └───────┬───────┘         └────────┬────────┘
          │                          │
          │    ┌──────────┐          │
          └───►│  Redis   │◄─────────┘  Cache + Sessions
               │ 10.89.0.20│
               └──────┬───┘
          ┌───────────▼───────────┐
          │      MySQL 8.0        │  Database
          │     10.89.0.10        │
          └───────────────────────┘

          ┌─────────── Monitoring Stack ───────────┐
          │  Prometheus  10.89.0.40  Metrics       │
          │  Grafana     10.89.0.41  Dashboards    │
          │  Node Exp.   10.89.0.42  Host metrics  │
          │  MySQL Exp.  10.89.0.43  DB metrics    │
          │  Redis Exp.  10.89.0.44  Cache metrics │
          └────────────────────────────────────────┘
```

All containers run rootless under `podman-wp` (UID 1001) on a private Podman bridge network (`10.89.0.0/24`). No database or cache port is exposed to the internet.

## Stack

| Component | Version | Role |
|-----------|---------|------|
| Nginx | 1.25-alpine | Reverse proxy, load balancer, SSL termination, rate limiting |
| WordPress | PHP 8.2 FPM Alpine | Application (2 nodes) |
| MySQL | 8.0 | Database |
| Redis | 7-alpine | Object cache, session storage |
| Anubis | latest | Bot protection (challenge/allow/deny) |
| Prometheus | latest | Metrics collection and alerting |
| Grafana | latest | Dashboards and visualization |
| Fail2ban | system | Intrusion prevention (SSH, Nginx, WP login) |
| SOPS + age | 3.9.2 / 1.2.0 | Secrets encryption at rest |
| SaltStack | Masterless | Configuration management |
| Podman | Rootless | Container runtime with auto-update |

## Quick Start

### Single Node (everything on one server)

```bash
git clone <repo-url> /opt/wpadmin
cd /opt/wpadmin

# Interactive installer
sudo bash install.sh

# Or non-interactive
sudo bash install.sh --domain=blog.example.com --single-node
```

### Multi-Node (distributed across servers)

```bash
# On the Salt master / LB node:
sudo bash install.sh --multi-node --role=lb --domain=example.com

# On the database node:
sudo bash install.sh --multi-node --role=db --domain=example.com --salt-master=10.0.0.1
```

See [DEPLOY.md](DEPLOY.md) for the full deployment guide including manual setup, multi-node topologies, and troubleshooting.

## Configuration

All configuration lives in `srv/pillar/`:

| File | Purpose |
|------|---------|
| `secrets.sls` | Database passwords, Redis password, WordPress salts |
| `network.sls` | Domain, IPs, ports, subnet |
| `users.sls` | Podman user and namespace mapping |
| `backup.sls` | Backup schedule, retention, offsite sync settings |
| `fail2ban.sls` | Ban time, find time, max retry, jail toggles |
| `monitoring_grafana.sls` | Monitoring IPs, Grafana admin password, scrape intervals |
| `autoupdate.sls` | Container update schedule and cleanup settings |
| `wp_maintenance.sls` | WP-CLI update schedule, plugin excludes, DB optimization |

Generate fresh secrets before deploying:

```bash
# Never use the example secrets in production
sudo bash -c 'cat > srv/pillar/secrets.sls <<EOF
secrets:
  mysql_root_password: $(openssl rand -hex 16)
  mysql_wp_user: wordpress
  mysql_wp_password: $(openssl rand -hex 16)
  mysql_wp_database: wordpress
  redis_password: $(openssl rand -hex 16)
  wp_auth_key:         $(openssl rand -hex 32)
  wp_secure_auth_key:  $(openssl rand -hex 32)
  wp_logged_in_key:    $(openssl rand -hex 32)
  wp_nonce_key:        $(openssl rand -hex 32)
  wp_auth_salt:        $(openssl rand -hex 32)
  wp_secure_auth_salt: $(openssl rand -hex 32)
  wp_logged_in_salt:   $(openssl rand -hex 32)
  wp_nonce_salt:       $(openssl rand -hex 32)
EOF'
sudo chmod 600 srv/pillar/secrets.sls
```

## Project Structure

```
wpadmin/
├── install.sh              Automatic installer
├── DEPLOY.md               Full deployment guide
├── SECURITY.md             Security documentation
└── srv/
    ├── pillar/
    │   ├── top.sls         Pillar mapping
    │   ├── secrets.sls     Credentials (generate fresh, never commit)
    │   ├── network.sls     IPs, ports, domain
    │   ├── users.sls       Podman user config
    │   ├── backup.sls      Backup schedule and retention
    │   ├── fail2ban.sls    Intrusion prevention settings
    │   ├── monitoring_grafana.sls  Monitoring stack config
    │   ├── autoupdate.sls  Container update schedule
    │   └── wp_maintenance.sls      WP-CLI automation config
    └── salt/
        ├── top.sls         Role to state mapping
        ├── map.jinja       Central variable lookup
        ├── security/       UFW firewall + SSH hardening + rate limiting
        ├── podman/         Podman install, user, network
        ├── mysql/          MySQL 8.0 container
        ├── redis/          Redis 7 container
        ├── wordpress/      2x PHP-FPM nodes + wp-config + WP-CLI
        ├── nginx/          Load balancer + SSL + Anubis + Grafana proxy + rate limiting
        ├── anubis/         Bot protection with policy rules
        ├── monitoring/     Beacons + reactors for automated remediation
        ├── prometheus/     Metrics collection + scrape config
        ├── exporters/      Node, MySQL, Redis metric exporters
        ├── grafana/        Dashboards + auto-provisioned datasource
        ├── backup/         Daily automated backups + restore
        ├── fail2ban/       SSH, Nginx, WP login intrusion prevention
        ├── logrotate/      Infrastructure log rotation
        ├── sops/           Secrets encryption (SOPS + age)
        ├── autoupdate/     Container auto-update timer with rollback
        └── wp_maintenance/ WP-CLI update and optimization timer
```

## Operational Commands

```bash
# List running containers
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$(id -u podman-wp) podman ps

# View logs
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$(id -u podman-wp) podman logs -f nginx

# Re-apply all Salt states (idempotent, safe to run anytime)
sudo salt-call --local state.apply

# WordPress CLI (via wrapper)
wp --info
wp plugin list
wp user list

# Run backups manually
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$(id -u podman-wp) \
    systemctl --user start wp-backup

# Restore from backup
/srv/wp/bin/backup-restore.sh list
/srv/wp/bin/backup-restore.sh restore-db <file>

# Run WordPress maintenance manually
sudo systemctl start wp-maintenance

# Trigger container updates manually
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$(id -u podman-wp) \
    systemctl --user start wp-autoupdate

# Check Grafana health
curl http://10.89.0.41:3000/api/health

# Check Prometheus targets
curl http://10.89.0.40:9090/api/v1/targets
```

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| CPU | 2 cores | 4 cores |
| RAM | 2 GB | 4 GB |
| Disk | 20 GB | 50 GB SSD |
| Network | Public IP, ports 80/443 open | |

## Documentation

- [DEPLOY.md](DEPLOY.md) — Full deployment, configuration, troubleshooting, backup, and scaling guide
- [SECURITY.md](SECURITY.md) — Complete security reference with verification checklist

## License

[MIT](LICENSE)
