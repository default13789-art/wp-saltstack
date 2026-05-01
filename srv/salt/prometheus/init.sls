{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

prometheus-conf-dir:
  file.directory:
    - name: {{ settings.base_dir }}/prometheus/conf
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

prometheus-data-dir:
  file.directory:
    - name: {{ settings.prometheus_data }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

prometheus-config:
  file.managed:
    - name: {{ settings.base_dir }}/prometheus/conf/prometheus.yml
    - source: salt://prometheus/files/prometheus.yml.jinja
    - template: jinja
    - context:
        scrape_interval: {{ settings.scrape_interval }}
        evaluation_interval: {{ settings.evaluation_interval }}
        node_exporter_ip: {{ settings.node_exporter_ip }}
        mysql_exporter_ip: {{ settings.mysql_exporter_ip }}
        redis_exporter_ip: {{ settings.redis_exporter_ip }}
        nginx_ip: {{ settings.nginx_ip }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: prometheus-conf-dir

prometheus-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-prometheus.service
    - source: salt://prometheus/files/prometheus.service.jinja
    - template: jinja
    - context:
        network_name: {{ settings.network_name }}
        prometheus_ip: {{ settings.prometheus_ip }}
        prometheus_conf: {{ settings.base_dir }}/prometheus/conf
        prometheus_data: {{ settings.prometheus_data }}
        retention_time: {{ settings.retention_time }}
        image: {{ settings.images.prometheus }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: prometheus-config
      - file: prometheus-data-dir

prometheus-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: prometheus-systemd-unit

prometheus-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-prometheus
    - cwd: {{ h }}
    - require:
      - cmd: prometheus-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: prometheus-systemd-unit
      - file: prometheus-config
