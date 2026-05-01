{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

grafana-conf-dir:
  file.directory:
    - name: {{ settings.base_dir }}/grafana/conf
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

grafana-provisioning-datasources-dir:
  file.directory:
    - name: {{ settings.base_dir }}/grafana/conf/provisioning/datasources
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: grafana-conf-dir

grafana-provisioning-dashboards-dir:
  file.directory:
    - name: {{ settings.base_dir }}/grafana/conf/provisioning/dashboards
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: grafana-conf-dir

grafana-data-dir:
  file.directory:
    - name: {{ settings.grafana_data }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

grafana-dashboards-dir:
  file.directory:
    - name: {{ settings.grafana_data }}/dashboards
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: grafana-data-dir

grafana-config:
  file.managed:
    - name: {{ settings.base_dir }}/grafana/conf/grafana.ini
    - source: salt://grafana/files/grafana.ini.jinja
    - template: jinja
    - context:
        admin_password: {{ settings.grafana_admin_password }}
        domain: {{ settings.domain }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-conf-dir

grafana-datasource:
  file.managed:
    - name: {{ settings.base_dir }}/grafana/conf/provisioning/datasources/datasource.yml
    - source: salt://grafana/files/datasource.yml.jinja
    - template: jinja
    - context:
        prometheus_ip: {{ settings.prometheus_ip }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-provisioning-datasources-dir

grafana-dashboard-provider:
  file.managed:
    - name: {{ settings.base_dir }}/grafana/conf/provisioning/dashboards/dashboard-provider.yml
    - source: salt://grafana/files/dashboard-provider.yml.jinja
    - template: jinja
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-provisioning-dashboards-dir

grafana-dashboard-node:
  file.managed:
    - name: {{ settings.grafana_data }}/dashboards/node-overview.json
    - source: salt://grafana/files/dashboards/node-overview.json
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-dashboards-dir

grafana-dashboard-mysql:
  file.managed:
    - name: {{ settings.grafana_data }}/dashboards/mysql-overview.json
    - source: salt://grafana/files/dashboards/mysql-overview.json
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-dashboards-dir

grafana-dashboard-redis:
  file.managed:
    - name: {{ settings.grafana_data }}/dashboards/redis-overview.json
    - source: salt://grafana/files/dashboards/redis-overview.json
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-dashboards-dir

grafana-dashboard-nginx:
  file.managed:
    - name: {{ settings.grafana_data }}/dashboards/nginx-overview.json
    - source: salt://grafana/files/dashboards/nginx-overview.json
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: grafana-dashboards-dir

grafana-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-grafana.service
    - source: salt://grafana/files/grafana.service.jinja
    - template: jinja
    - context:
        network_name: {{ settings.network_name }}
        grafana_ip: {{ settings.grafana_ip }}
        grafana_conf: {{ settings.base_dir }}/grafana/conf
        grafana_data: {{ settings.grafana_data }}
        admin_password: {{ settings.grafana_admin_password }}
        image: {{ settings.images.grafana }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: grafana-config
      - file: grafana-data-dir

grafana-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: grafana-systemd-unit

grafana-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-grafana
    - cwd: {{ h }}
    - require:
      - cmd: grafana-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: grafana-systemd-unit
      - file: grafana-config
      - file: grafana-datasource
      - file: grafana-dashboard-provider
