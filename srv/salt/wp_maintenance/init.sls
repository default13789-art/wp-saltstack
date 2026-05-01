{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

{% if settings.wp_maint_enabled %}

wp-maintenance-script:
  file.managed:
    - name: {{ settings.wp_bin }}/wp-maintenance.sh
    - source: salt://wp_maintenance/files/wp-maintenance.sh.jinja
    - template: jinja
    - context:
        update_core: {{ settings.wp_maint_core }}
        update_plugins: {{ settings.wp_maint_plugins }}
        update_themes: {{ settings.wp_maint_themes }}
        exclude_plugins: {{ settings.wp_maint_exclude_plugins }}
        db_optimize: {{ settings.wp_maint_db_optimize }}
        transient_cleanup: {{ settings.wp_maint_transient_cleanup }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - require:
      - cmd: wp-cli-download

wp-maintenance-service:
  file.managed:
    - name: /etc/systemd/system/wp-maintenance.service
    - source: salt://wp_maintenance/files/wp-maintenance.service.jinja
    - template: jinja
    - context:
        wp_bin: {{ settings.wp_bin }}
    - mode: '0644'

wp-maintenance-timer:
  file.managed:
    - name: /etc/systemd/system/wp-maintenance.timer
    - source: salt://wp_maintenance/files/wp-maintenance.timer.jinja
    - template: jinja
    - context:
        hour: {{ settings.wp_maint_hour }}
        minute: {{ settings.wp_maint_minute|string|pad(2, '0') }}
    - mode: '0644'

wp-maintenance-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: wp-maintenance-service
      - file: wp-maintenance-timer

wp-maintenance-timer-enable:
  cmd.run:
    - name: systemctl enable --now wp-maintenance.timer
    - require:
      - cmd: wp-maintenance-daemon-reload
      - file: wp-maintenance-service
      - file: wp-maintenance-timer
      - file: wp-maintenance-script
    - onchanges:
      - file: wp-maintenance-timer

{% endif %}
