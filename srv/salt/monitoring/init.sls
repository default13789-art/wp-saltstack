{% from "map.jinja" import settings with context %}
{% set role = salt['grains.get']('role', '') %}
{% set u = settings.podman_user %}
{% set uid = settings.podman_uid %}
{% set h = settings.podman_home %}

monitoring-pyinotify:
  pkg.installed:
    - name: python3-pyinotify

monitoring-alert-log-dir:
  file.directory:
    - name: /var/log/wp
    - mode: '0755'
    - makedirs: True

monitoring-beacon-config:
  file.managed:
    - name: /etc/salt/minion.d/beacons.conf
    - source: salt://monitoring/files/minion-beacon-conf.jinja
    - template: jinja
    - context:
        disk_critical: {{ settings.disk_critical }}
        disk_paths: {{ settings.disk_paths }}
        beacon_interval: {{ settings.beacon_interval }}
        watch_paths: {{ settings.watch_paths.get(role, []) }}
        container_services: {{ settings.container_services.get(role, []) }}
    - require:
      - pkg: monitoring-pyinotify
    - watch_in:
      - service: monitoring-minion-restart

monitoring-health-check-script:
  file.managed:
    - name: /usr/local/bin/wp-container-health-check.sh
    - source: salt://monitoring/files/check-container-health.sh.jinja
    - template: jinja
    - mode: '0755'
    - context:
        podman_user: {{ u }}
        podman_uid: {{ uid }}
        container_services: {{ settings.container_services.get(role, []) }}

monitoring-minion-restart:
  service.running:
    - name: salt-minion
    - watch:
      - file: monitoring-beacon-config
