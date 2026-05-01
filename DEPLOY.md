# Deployment Guide — WordPress HA Infrastructure

Complete guide for deploying the SaltStack + Rootless Podman WordPress stack.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Quick Start — Single Node](#quick-start--single-node)
- [Multi-Node Deployment](#multi-node-deployment)
- [Configuration Reference](#configuration-reference)
- [Post-Deployment Verification](#post-deployment-verification)
- [DNS & SSL Setup](#dns--ssl-setup)
- [Operational Commands](#operational-commands)
- [Troubleshooting](#troubleshooting)
- [Backup & Recovery](#backup--recovery)
- [Scaling](#scaling)

---

## Architecture Overview

```
                    ┌─────────────┐
                    │   Internet   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  Nginx (LB)  │  :80 → redirect :443
                    │  10.89.0.2   │  :443 → TLS termination
                    └──────┬───────┘
                    ┌──────┴───────┐
                    │  least_conn  │
                    └──┬────────┬──┘
                ┌──────▼──┐  ┌──▼────────┐
                │ WP Node1│  │ WP Node2  │
                │.31:9000 │  │ .32:9000  │  PHP-FPM 8.2
                └────┬────┘  └────┬──────┘
                     └─────┬──────┘
                ┌──────────▼──────────┐
                │      Redis 7        │  Object cache + sessions
                │     10.89.0.20      │
                └──────────┬──────────┘
                ┌──────────▼──────────┐
                │     MySQL 8.0       │  Database
                │     10.89.0.10      │
                └─────────────────────┘
```

All containers run rootless under `podman-wp` (UID 1001) with user namespace mapping. The Podman bridge network `wp-network` (10.89.0.0/24) provides static internal IPs.

### Service Boot Order

```
podman setup → MySQL → Redis → WP Node 1 + WP Node 2 → Nginx
```

Enforced via systemd `Requires=` / `After=` directives.

---

## Prerequisites

### Hardware

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU       | 2 cores | 4 cores     |
| RAM       | 2 GB    | 4 GB        |
| Disk      | 20 GB   | 50 GB SSD   |
| Network   | Public IP with ports 80/443 open |

### Software

- **OS**: Ubuntu 24.04 LTS (Noble Numbat)
- **Access**: Root or sudo privileges
- **DNS**: Your domain's A record must point to the server IP before SSL provisioning

### Network

| Port | Protocol | Purpose |
|------|----------|---------|
| 80   | TCP      | HTTP → HTTPS redirect, ACME challenge |
| 443  | TCP      | HTTPS (WordPress site) |
| 2222 | TCP      | SSH (configurable) |

---

create an user with sudo | cause the script remove root ssh acess

## Quick Start — Single Node

Deploy everything on one server in under 10 minutes.

### Option A: Automatic Installer

```bash
# Clone or copy the repo to the server
git clone <repo-url> /opt/wpadmin
cd /opt/wpadmin

# Run the installer (interactive)
sudo bash install.sh

# Or with all parameters pre-set
sudo bash install.sh --domain=blog.example.com --single-node
```

### Option B: Manual Step-by-Step

#### 1. Install Packages

```bash
sudo apt-get update
sudo apt-get install -y salt-minion salt-common podman podman-plugins ufw openssl
```

#### 2. Generate Secrets

```bash
# Generate fresh passwords and salts
sudo bash -c 'cat > /opt/wpadmin/srv/pillar/secrets.sls <<EOF
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
sudo chmod 600 /opt/wpadmin/srv/pillar/secrets.sls
```

#### 3. Configure Domain

```bash
# Edit network.sls — change 'domain: example.com' to your domain
sudo sed -i 's/domain: example.com/domain: YOUR.DOMAIN/' /opt/wpadmin/srv/pillar/network.sls
```

#### 4. Configure Salt for Masterless Mode

```bash
sudo tee /etc/salt/minion <<EOF
file_client: local
file_roots:
  base:
    - /opt/wpadmin/srv/salt
pillar_roots:
  base:
    - /opt/wpadmin/srv/pillar
EOF
```

#### 5. Apply States

```bash
# Apply in dependency order
sudo salt-call --local state.apply podman
sudo salt-call --local state.apply mysql
sudo salt-call --local state.apply redis
sudo salt-call --local state.apply wordpress
sudo salt-call --local state.apply nginx
sudo salt-call --local state.apply security
```

#### 6. Start Containers

```bash
# As the podman-wp user
UID=$(id -u podman-wp)
SUDO="sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID"

$SUDO systemctl --user start container-mysql
sleep 10
$SUDO systemctl --user start container-redis
$SUDO systemctl --user start container-wp-node1
$SUDO systemctl --user start container-wp-node2
$SUDO systemctl --user start container-nginx
```

---

## Multi-Node Deployment

Distribute roles across multiple servers for production HA.

### Topology Example (5 Nodes)

```
Node A (security)   — Firewall + SSH hardening
Node B (db)         — MySQL 8.0
Node C (cache)      — Redis 7
Node D (app)        — WordPress PHP-FPM (2 containers)
Node E (lb)         — Nginx load balancer + SSL
```

### Minimum Topology (2 Nodes)

```
Node 1: db + cache + app (all data services)
Node 2: lb + security (edge services)
```

### Setup Steps

#### 1. Choose a Salt Master

Pick one node (typically the `security` or `lb` node) to host the Salt master.

```bash
# On the Salt master node:
sudo apt-get install -y salt-master

sudo tee /etc/salt/master <<EOF
file_roots:
  base:
    - /opt/wpadmin/srv/salt
pillar_roots:
  base:
    - /opt/wpadmin/srv/pillar
auto_accept: True
EOF

sudo systemctl enable --now salt-master
```

#### 2. Configure Each Minion

On every node (including the master if it also runs workloads):

```bash
sudo apt-get install -y salt-minion

sudo tee /etc/salt/minion <<EOF
master: <SALT_MASTER_IP>
id: <UNIQUE_MINION_ID>
EOF

sudo systemctl enable --now salt-minion
```

#### 3. Assign Roles

```bash
# From the Salt master (or locally):
sudo salt 'db-node' grains.setval role db
sudo salt 'cache-node' grains.setval role cache
sudo salt 'app-node' grains.setval role app
sudo salt 'lb-node' grains.setval role lb
sudo salt 'sec-node' grains.setval role security
```

#### 4. Update Network IPs

Edit `srv/pillar/network.sls` if containers run on different hosts. Each host runs its own Podman bridge, so IPs can remain the same — but ensure the host firewall allows inter-node traffic on the Podman subnet.

#### 5. Apply States

```bash
# From the Salt master — apply all at once:
sudo salt '*' state.apply

# Or per-role, in order:
sudo salt -G 'role:db' state.apply
sudo salt -G 'role:cache' state.apply
sudo salt -G 'role:app' state.apply
sudo salt -G 'role:lb' state.apply
sudo salt -G 'role:security' state.apply
```

#### 6. Or use the installer on each node

```bash
# On the DB node:
sudo bash install.sh --multi-node --role=db --domain=example.com --salt-master=10.0.0.1

# On the LB node:
sudo bash install.sh --multi-node --role=lb --domain=example.com --salt-master=10.0.0.1
```

---

## Configuration Reference

### Pillar Files

All configuration lives in `srv/pillar/`. Edit these before applying states.

#### `secrets.sls` — Credentials

| Key | Description | Default |
|-----|-------------|---------|
| `mysql_root_password` | MySQL root password | Auto-generated |
| `mysql_wp_user` | WordPress DB user | `wordpress` |
| `mysql_wp_password` | WordPress DB password | Auto-generated |
| `mysql_wp_database` | WordPress DB name | `wordpress` |
| `redis_password` | Redis AUTH password | Auto-generated |
| `wp_auth_key` through `wp_nonce_salt` | WordPress salts (8 total) | Auto-generated |

> **Never commit `secrets.sls` to version control.** Add it to `.gitignore`.

#### `network.sls` — Network Topology

| Key | Description | Default |
|-----|-------------|---------|
| `domain` | Public domain name | `example.com` |
| `ssh_port` | SSH port for firewall | `2222` |
| `network_name` | Podman bridge name | `wp-network` |
| `subnet` | Bridge subnet | `10.89.0.0/24` |
| `gateway` | Bridge gateway | `10.89.0.1` |
| `mysql_ip` | MySQL container IP | `10.89.0.10` |
| `redis_ip` | Redis container IP | `10.89.0.20` |
| `wp_node1_ip` | WP node 1 IP | `10.89.0.31` |
| `wp_node2_ip` | WP node 2 IP | `10.89.0.32` |
| `nginx_ip` | Nginx container IP | `10.89.0.2` |
| `http_port` | Host HTTP port | `80` |
| `https_port` | Host HTTPS port | `443` |
| `base_dir` | Host base directory | `/srv/wp` |
| `wp_bin` | WP-CLI & tools directory | `/srv/wp/bin` |

#### `users.sls` — Podman User

| Key | Description | Default |
|-----|-------------|---------|
| `podman_user` | Unprivileged user name | `podman-wp` |
| `podman_uid` | User UID | `1001` |
| `podman_home` | Home directory | `/home/podman-wp` |
| `subuid_start` | Namespace UID start | `100000` |
| `subuid_count` | Namespace UID count | `65536` |

### Container Images

Configured in `srv/salt/map.jinja`:

| Service | Image |
|---------|-------|
| MySQL | `docker.io/library/mysql:8.0` |
| Redis | `docker.io/library/redis:7-alpine` |
| WordPress | `docker.io/library/wordpress:php8.2-fpm-alpine` |
| Nginx | `docker.io/library/nginx:1.25-alpine` |

---

## Post-Deployment Verification

### Check All Containers

```bash
UID=$(id -u podman-wp)
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID podman ps -a
```

Expected output: 5 containers (mysql, redis, wp-node1, wp-node2, nginx) all status `Up`.

### Check Health Endpoints

```bash
# HTTP health
curl -f http://localhost/health

# HTTPS (accept self-signed cert initially)
curl -kf https://localhost/
```

### Check MySQL

```bash
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID \
    podman exec mysql mysqladmin ping -h localhost -p"<root_password>" --silent
```

### Check Redis

```bash
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID \
    podman exec redis redis-cli -a "<redis_password>" ping
```

### Check Load Balancer

```bash
# Should alternate between nodes
for i in $(seq 1 6); do
    curl -sk https://localhost/ -o /dev/null -w "Node: %{remote_ip}\n"
done
```

### Check Firewall

```bash
sudo ufw status verbose
```

Expected: Active with rules for 80/tcp, 443/tcp, 2222/tcp.

---

## DNS & SSL Setup

### DNS

Point your domain's A record to the server's public IP:

```
blog.example.com.  A  203.0.113.42
```

Wait for DNS propagation (usually 5-30 minutes). Verify:

```bash
dig blog.example.com +short
```

### SSL (Let's Encrypt)

Once DNS resolves, the Nginx container will attempt Let's Encrypt on next restart. To manually trigger:

```bash
UID=$(id -u podman-wp)
SUDO="sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID"

# Stop nginx, remove self-signed cert, restart
$SUDO systemctl --user stop container-nginx
rm -rf /srv/wp/nginx/ssl/live/*
$SUDO systemctl --user start container-nginx

# Watch the entrypoint logs
$SUDO podman logs -f nginx
```

The entrypoint script will:
1. Attempt Let's Encrypt via `certbot certonly --standalone`
2. Fall back to self-signed if it fails
3. Set up automatic renewal cron every 2 months

---

## Operational Commands

### Container Management

```bash
# Helper variables
export UID=$(id -u podman-wp)
export SUDO="sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID"

# List containers
$SUDO podman ps -a

# Start/stop/restart individual services
$SUDO systemctl --user start container-mysql
$SUDO systemctl --user stop container-nginx
$SUDO systemctl --user restart container-redis

# View logs
$SUDO podman logs -f mysql
$SUDO podman logs -f nginx
$SUDO podman logs --tail 100 wp-node1

# Shell into a container
$SUDO podman exec -it mysql bash
$SUDO podman exec -it wp-node1 sh
```

### Salt Management

```bash
# Re-apply all states (idempotent — safe to run anytime)
salt-call --local state.apply

# Re-apply a single state
salt-call --local state.apply mysql

# Render a template without applying (debug Jinja2)
salt-call --local state.show_sls wordpress

# Refresh pillar after editing pillar files
salt-call --local saltutil.refresh_pillar

# Show grains
salt-call --local grains.items
```

### WordPress

```bash
# WP-CLI is installed automatically by the wordpress state.
# Host wrapper (runs inside wp-node1 container):
wp --info
wp plugin list
wp user list

# Or run directly via podman exec:
$SUDO podman exec wp-node1 php /usr/local/bin/wp-cli.phar --info

# Database backup
$SUDO podman exec mysql mysqldump -u root -p"<root_password>" wordpress > backup.sql

# Database restore
$SUDO podman exec -i mysql mysql -u root -p"<root_password>" wordpress < backup.sql
```

---

## Troubleshooting

### Containers won't start

```bash
# Check systemd user service logs
journalctl --user -u container-mysql --no-pager -n 50

# Check if podman-wp user has lingering enabled
ls /var/lib/systemd/linger/podman-wp

# Enable lingering if missing
loginctl enable-linger podman-wp
```

### MySQL connection refused

```bash
# Verify MySQL is healthy
$SUDO podman exec mysql mysqladmin ping -h localhost -p"<root_password>"

# Check init SQL ran
$SUDO podman exec mysql mysql -u root -p"<root_password>" -e "SHOW DATABASES;"

# Check network connectivity from WP node
$SUDO podman exec wp-node1 php -r "var_dump(fsockopen('10.89.0.10', 3306, \$errno, \$errstr, 5));"
```

### Redis connection issues

```bash
# Test from inside the network
$SUDO podman exec wp-node1 php -r "
  \$r = new Redis();
  var_dump(\$r->connect('10.89.0.20', 6379));
  var_dump(\$r->auth('<redis_password>'));
  var_dump(\$r->ping());
"
```

### Nginx 502 Bad Gateway

```bash
# Check if WP nodes are running
$SUDO podman ps --filter name=wp-node

# Test PHP-FPM directly
$SUDO podman exec wp-node1 php-fpm -t

# Check upstream from Nginx
$SUDO podman exec nginx curl -s http://10.89.0.31:9000/status 2>&1 || echo "FPM not responding"
```

### Port 80/443 already in use

```bash
# Find what's using the ports
sudo ss -tlnp | grep -E ':80|:443'

# Stop conflicting services
sudo systemctl stop apache2 nginx 2>/dev/null
sudo apt-get remove -y apache2 nginx 2>/dev/null
```

### Permission denied on volumes

```bash
# Fix ownership of host directories
sudo chown -R podman-wp:podman-wp /srv/wp/
```

### Rebuild from scratch

```bash
UID=$(id -u podman-wp)
SUDO="sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID"

# Stop all containers
$SUDO systemctl --user stop container-nginx container-wp-node1 container-wp-node2 container-redis container-mysql

# Remove containers
$SUDO podman rm -f mysql redis wp-node1 wp-node2 nginx 2>/dev/null

# Remove data (CAUTION — destroys database)
sudo rm -rf /srv/wp/mysql/data/*

# Re-apply states
salt-call --local state.apply

# Start containers
$SUDO systemctl --user start container-mysql
sleep 10
$SUDO systemctl --user start container-redis container-wp-node1 container-wp-node2 container-nginx
```

---

## Backup & Recovery

### Database Backup

```bash
# One-time dump
UID=$(id -u podman-wp)
sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID \
    podman exec mysql mysqldump -u root -p"<password>" --single-transaction wordpress \
    | gzip > wordpress-db-$(date +%Y%m%d).sql.gz
```

### File Backup (Uploads)

```bash
sudo tar czf wp-uploads-$(date +%Y%m%d).tar.gz /srv/wp/uploads/
```

### Automated Daily Backups (Cron)

```bash
# Add to root crontab
sudo crontab -e
```

```cron
# Daily DB backup at 2 AM, keep 30 days
0 2 * * * UID=$(id -u podman-wp); sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID podman exec mysql mysqldump -u root -p'<PASSWORD>' --single-transaction wordpress | gzip > /srv/wp/backups/db-$(date +\%Y\%m\%d).sql.gz; find /srv/wp/backups/ -name "db-*.sql.gz" -mtime +30 -delete
```

### Restore

```bash
# Restore database
gunzip < wordpress-db-YYYYMMDD.sql.gz | \
    sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/$UID \
    podman exec -i mysql mysql -u root -p"<password>" wordpress

# Restore uploads
sudo tar xzf wp-uploads-YYYYMMDD.tar.gz -C /
```

---

## Scaling

### Add a Third WP Node

1. Edit `srv/salt/wordpress/init.sls` — add node 3 to the loop:

```jinja
{% for node_num, node_ip in [('1', settings.wp_node1_ip), ('2', settings.wp_node2_ip), ('3', settings.wp_node3_ip)] %}
```

2. Add the IP to `srv/pillar/network.sls`:

```yaml
wp_node3_ip: 10.89.0.33
```

3. Add the upstream server to `srv/salt/nginx/files/nginx.conf.jinja`.

4. Add the `Requires=`/`After=` for node 3 in `srv/salt/nginx/files/nginx.service.jinja`.

5. Re-apply states:

```bash
salt-call --local state.apply wordpress
salt-call --local state.apply nginx
```

### Increase PHP Workers

Edit the WP node service to add environment variables:

```yaml
-e PHP_FPM_MAX_CHILDREN=20
```

Or mount a custom `www.conf` with adjusted `pm.max_children`.

### Separate Uploads to NFS

For multi-node deployments, replace the local `/srv/wp/uploads` bind mount with an NFS volume:

```bash
sudo apt-get install -y nfs-common
sudo mkdir -p /srv/wp/uploads
sudo mount -t nfs4 nfs-server:/exports/wp-uploads /srv/wp/uploads
```

---

## File Layout Summary

```
wpadmin/
├── install.sh              ← Automatic installer
├── DEPLOY.md               ← This guide
├── CLAUDE.md               ← Architecture reference
└── srv/
    ├── pillar/
    │   ├── top.sls         ← Pillar mapping
    │   ├── secrets.sls     ← Passwords & salts (GENERATE FRESH!)
    │   ├── network.sls     ← IPs, ports, domain
    │   └── users.sls       ← Podman user config
    └── salt/
        ├── top.sls         ← Role → state mapping
        ├── map.jinja       ← Central variable lookup
        ├── security/       ← UFW + SSH hardening
        ├── podman/         ← Podman install + user + network
        ├── mysql/          ← MySQL 8.0 container
        ├── redis/          ← Redis 7 container
        ├── wordpress/      ← 2x PHP-FPM nodes + wp-config
        └── nginx/          ← Load balancer + SSL
```
