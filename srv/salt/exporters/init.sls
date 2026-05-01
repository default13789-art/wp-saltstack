{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

node-exporter-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-node-exporter.service
    - source: salt://exporters/files/node-exporter.service.jinja
    - template: jinja
    - context:
        network_name: {{ settings.network_name }}
        node_exporter_ip: {{ settings.node_exporter_ip }}
        image: {{ settings.images.node_exporter }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir

node-exporter-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: node-exporter-systemd-unit

node-exporter-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-node-exporter
    - cwd: {{ h }}
    - require:
      - cmd: node-exporter-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: node-exporter-systemd-unit

mysql-exporter-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-mysql-exporter.service
    - source: salt://exporters/files/mysql-exporter.service.jinja
    - template: jinja
    - context:
        network_name: {{ settings.network_name }}
        mysql_exporter_ip: {{ settings.mysql_exporter_ip }}
        mysql_ip: {{ settings.mysql_ip }}
        mysql_user: {{ settings.mysql_wp_user }}
        mysql_pass: {{ settings.mysql_wp_pass }}
        image: {{ settings.images.mysql_exporter }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir

mysql-exporter-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: mysql-exporter-systemd-unit

mysql-exporter-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-mysql-exporter
    - cwd: {{ h }}
    - require:
      - cmd: mysql-exporter-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: mysql-exporter-systemd-unit

redis-exporter-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-redis-exporter.service
    - source: salt://exporters/files/redis-exporter.service.jinja
    - template: jinja
    - context:
        network_name: {{ settings.network_name }}
        redis_exporter_ip: {{ settings.redis_exporter_ip }}
        redis_ip: {{ settings.redis_ip }}
        redis_password: {{ settings.redis_password }}
        image: {{ settings.images.redis_exporter }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir

redis-exporter-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: redis-exporter-systemd-unit

redis-exporter-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-redis-exporter
    - cwd: {{ h }}
    - require:
      - cmd: redis-exporter-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: redis-exporter-systemd-unit
