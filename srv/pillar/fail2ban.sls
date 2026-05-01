fail2ban:
  ban_time: 3600
  find_time: 600
  max_retry: 5

  ssh:
    enabled: true

  nginx_http_auth:
    enabled: true

  wp_login:
    enabled: true
    max_retry: 5
    find_time: 600
    ban_time: 3600
