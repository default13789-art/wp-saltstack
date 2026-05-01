{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

{% if settings.autoupdate_enabled %}

autoupdate-service:
  file.managed:
    - name: {{ h }}/.config/systemd/user/wp-autoupdate.service
    - source: salt://autoupdate/files/wp-autoupdate.service.jinja
    - template: jinja
    - context:
        podman_uid: {{ settings.podman_uid }}
        cleanup_images: {{ settings.autoupdate_cleanup }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir

autoupdate-timer:
  file.managed:
    - name: {{ h }}/.config/systemd/user/wp-autoupdate.timer
    - source: salt://autoupdate/files/wp-autoupdate.timer.jinja
    - template: jinja
    - context:
        hour: {{ settings.autoupdate_hour }}
        minute: {{ settings.autoupdate_minute|string|pad(2, '0') }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir

autoupdate-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: autoupdate-service
      - file: autoupdate-timer

autoupdate-timer-enable:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now wp-autoupdate.timer
    - cwd: {{ h }}
    - require:
      - cmd: autoupdate-daemon-reload
    - onchanges:
      - file: autoupdate-timer

{% endif %}
