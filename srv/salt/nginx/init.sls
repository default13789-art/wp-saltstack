{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

nginx-conf-dir:
  file.directory:
    - name: {{ settings.nginx_conf }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

nginx-ssl-dir:
  file.directory:
    - name: {{ settings.nginx_ssl }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0700'
    - makedirs: True
    - require:
      - file: wp-base-dir

nginx-logs-dir:
  file.directory:
    - name: {{ settings.nginx_logs }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

nginx-wp-plugins-dir:
  file.directory:
    - name: {{ settings.base_dir }}/wp-content/plugins
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

nginx-wp-themes-dir:
  file.directory:
    - name: {{ settings.base_dir }}/wp-content/themes
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

nginx-conf:
  file.managed:
    - name: {{ settings.nginx_conf }}/nginx.conf
    - source: salt://nginx/files/nginx.conf.jinja
    - template: jinja
    - context:
        domain: {{ settings.domain }}
        wp_node1_ip: {{ settings.wp_node1_ip }}
        wp_node2_ip: {{ settings.wp_node2_ip }}
        anubis_ip: {{ settings.anubis_ip }}
        grafana_ip: {{ settings.grafana_ip }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: nginx-conf-dir

nginx-entrypoint:
  file.managed:
    - name: {{ settings.nginx_conf }}/entrypoint.sh
    - source: salt://nginx/files/entrypoint.sh.jinja
    - template: jinja
    - context:
        domain: {{ settings.domain }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - require:
      - file: nginx-conf-dir
      - file: nginx-ssl-dir

nginx-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-nginx.service
    - source: salt://nginx/files/nginx.service.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        nginx_ip: {{ settings.nginx_ip }}
        network_name: {{ settings.network_name }}
        http_port: {{ settings.http_port }}
        https_port: {{ settings.https_port }}
        nginx_conf: {{ settings.nginx_conf }}
        nginx_ssl: {{ settings.nginx_ssl }}
        nginx_logs: {{ settings.nginx_logs }}
        uploads_dir: {{ settings.uploads_dir }}
        wp_plugins_dir: {{ settings.base_dir }}/wp-content/plugins
        wp_themes_dir: {{ settings.base_dir }}/wp-content/themes
        wp_core_dir: {{ settings.wp_core_dir }}
        image: {{ settings.images.nginx }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: nginx-conf
      - file: nginx-entrypoint
      - cmd: wp-core-extract

nginx-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: nginx-systemd-unit

nginx-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-nginx
    - cwd: {{ h }}
    - require:
      - cmd: nginx-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: nginx-systemd-unit
      - file: nginx-conf

nginx-cert-renew-cron:
  cron.present:
    - name: >
        sudo -u {{ u }} env XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        systemctl --user restart container-nginx.service
    - user: root
    - minute: 0
    - hour: '2,14'
    - identifier: wp-nginx-cert-renew
