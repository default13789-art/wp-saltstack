{% from "map.jinja" import settings with context %}

fail2ban-pkg:
  pkg.installed:
    - name: fail2ban

fail2ban-jail-local:
  file.managed:
    - name: /etc/fail2ban/jail.local
    - source: salt://fail2ban/files/jail.local.jinja
    - template: jinja
    - context:
        ssh_enabled: {{ settings.f2b_ssh_enabled }}
        ssh_port: {{ settings.ssh_port }}
        nginx_http_auth_enabled: {{ settings.f2b_nginx_http_auth_enabled }}
        wp_login_enabled: {{ settings.f2b_wp_login_enabled }}
        max_retry: {{ settings.f2b_max_retry }}
        find_time: {{ settings.f2b_find_time }}
        ban_time: {{ settings.f2b_ban_time }}
        wp_login_max_retry: {{ settings.f2b_wp_login_max_retry }}
        wp_login_find_time: {{ settings.f2b_wp_login_find_time }}
        wp_login_ban_time: {{ settings.f2b_wp_login_ban_time }}
        nginx_log_dir: {{ settings.nginx_logs }}
    - require:
      - pkg: fail2ban-pkg
    - watch_in:
      - service: fail2ban-service

fail2ban-filter-wp-login:
  file.managed:
    - name: /etc/fail2ban/filter.d/wp-login.conf
    - source: salt://fail2ban/files/filter-wp-login.conf.jinja
    - template: jinja
    - require:
      - pkg: fail2ban-pkg
    - watch_in:
      - service: fail2ban-service

fail2ban-filter-nginx-auth:
  file.managed:
    - name: /etc/fail2ban/filter.d/nginx-http-auth.conf
    - source: salt://fail2ban/files/filter-nginx-http-auth.conf.jinja
    - template: jinja
    - require:
      - pkg: fail2ban-pkg
    - watch_in:
      - service: fail2ban-service

fail2ban-service:
  service.running:
    - name: fail2ban
    - enable: True
    - require:
      - pkg: fail2ban-pkg
