{% from "map.jinja" import settings with context %}

logrotate-pkg:
  pkg.installed:
    - name: logrotate

logrotate-wp-config:
  file.managed:
    - name: /etc/logrotate.d/wp-infrastructure
    - source: salt://logrotate/files/wp-logrotate.conf.jinja
    - template: jinja
    - context:
        log_dir: {{ settings.backup_log_dir }}
        nginx_logs: {{ settings.nginx_logs }}
        podman_user: {{ settings.podman_user }}
        podman_uid: {{ settings.podman_uid }}
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - pkg: logrotate-pkg
