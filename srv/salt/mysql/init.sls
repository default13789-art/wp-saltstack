{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

mysql-data-dir:
  file.directory:
    - name: {{ settings.mysql_data }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - makedirs: True
    - require:
      - file: wp-base-dir

mysql-conf-dir:
  file.directory:
    - name: {{ settings.mysql_conf }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

mysql-init-dir:
  file.directory:
    - name: {{ settings.mysql_init }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

mysql-init-sql:
  file.managed:
    - name: {{ settings.mysql_init }}/init.sql
    - source: salt://mysql/files/init.sql.jinja
    - template: jinja
    - context:
        wp_user: {{ settings.mysql_wp_user }}
        wp_pass: {{ settings.mysql_wp_pass }}
        wp_db: {{ settings.mysql_wp_db }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0600'
    - require:
      - file: mysql-init-dir

mysql-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-mysql.service
    - source: salt://mysql/files/mysql.service.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        mysql_ip: {{ settings.mysql_ip }}
        network_name: {{ settings.network_name }}
        mysql_root_pass: {{ settings.mysql_root_pass }}
        mysql_wp_db: {{ settings.mysql_wp_db }}
        mysql_data: {{ settings.mysql_data }}
        mysql_conf: {{ settings.mysql_conf }}
        mysql_init: {{ settings.mysql_init }}
        image: {{ settings.images.mysql }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: mysql-init-sql

mysql-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: mysql-systemd-unit

mysql-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-mysql
    - cwd: {{ h }}
    - require:
      - cmd: mysql-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: mysql-systemd-unit
