{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

backup-dir:
  file.directory:
    - name: {{ settings.backup_dir }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - makedirs: True
    - require:
      - file: wp-base-dir

backup-mysql-dir:
  file.directory:
    - name: {{ settings.backup_dir }}/mysql
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - require:
      - file: backup-dir

backup-uploads-dir:
  file.directory:
    - name: {{ settings.backup_dir }}/uploads
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - require:
      - file: backup-dir

backup-config-dir:
  file.directory:
    - name: {{ settings.backup_dir }}/config
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - require:
      - file: backup-dir

backup-redis-dir:
  file.directory:
    - name: {{ settings.backup_dir }}/redis
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - require:
      - file: backup-dir

backup-log-dir:
  file.directory:
    - name: {{ settings.backup_log_dir }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True

backup-script:
  file.managed:
    - name: {{ settings.wp_bin }}/backup.sh
    - source: salt://backup/files/backup.sh.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        podman_uid: {{ settings.podman_uid }}
        backup_dir: {{ settings.backup_dir }}
        retention_days: {{ settings.retention_days }}
        log_dir: {{ settings.backup_log_dir }}
        mysql_root_pass: {{ settings.mysql_root_pass }}
        mysql_wp_db: {{ settings.mysql_wp_db }}
        uploads_dir: {{ settings.uploads_dir }}
        wp_config_dir: {{ settings.wp_config_dir }}
        redis_data: {{ settings.redis_data }}
        offsite_enabled: {{ settings.offsite_enabled }}
        offsite_type: {{ settings.offsite_type }}
        offsite_target: {{ settings.offsite_target }}
        offsite_rsync_key: {{ settings.offsite_rsync_key }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - require:
      - file: backup-dir
      - file: backup-log-dir

backup-restore-script:
  file.managed:
    - name: {{ settings.wp_bin }}/backup-restore.sh
    - source: salt://backup/files/backup-restore.sh.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        podman_uid: {{ settings.podman_uid }}
        backup_dir: {{ settings.backup_dir }}
        log_dir: {{ settings.backup_log_dir }}
        mysql_root_pass: {{ settings.mysql_root_pass }}
        mysql_wp_db: {{ settings.mysql_wp_db }}
        uploads_dir: {{ settings.uploads_dir }}
        wp_config_dir: {{ settings.wp_config_dir }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - require:
      - file: backup-dir

backup-systemd-service:
  file.managed:
    - name: {{ h }}/.config/systemd/user/wp-backup.service
    - source: salt://backup/files/wp-backup.service.jinja
    - template: jinja
    - context:
        wp_bin: {{ settings.wp_bin }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: backup-script

backup-systemd-timer:
  file.managed:
    - name: {{ h }}/.config/systemd/user/wp-backup.timer
    - source: salt://backup/files/wp-backup.timer.jinja
    - template: jinja
    - context:
        schedule_hour: {{ settings.schedule_hour }}
        schedule_minute: {{ settings.schedule_minute }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: backup-systemd-service

backup-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: backup-systemd-service
      - file: backup-systemd-timer

backup-timer-enable:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now wp-backup.timer
    - cwd: {{ h }}
    - require:
      - cmd: backup-daemon-reload
    - unless: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user is-enabled wp-backup.timer
