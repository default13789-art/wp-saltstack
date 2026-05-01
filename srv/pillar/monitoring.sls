monitoring:
  disk_warning: 80
  disk_critical: 90

  disk_paths:
    - /
    - /srv/wp

  beacon_interval: 60

  watch_paths:
    db:
      - /srv/wp/mysql/conf
      - /srv/wp/mysql/init
    cache:
      - /srv/wp/redis/data
    app:
      - /srv/wp/wp-config
    lb:
      - /srv/wp/nginx/conf
      - /srv/wp/nginx/ssl

  container_services:
    db:
      - container-mysql
    cache:
      - container-redis
    app:
      - container-wp-node1
      - container-wp-node2
    lb:
      - container-nginx
      - container-anubis
    all-in-one:
      - container-mysql
      - container-redis
      - container-wp-node1
      - container-wp-node2
      - container-nginx
      - container-anubis

  alert_log: /var/log/wp/beacon-alerts.log
