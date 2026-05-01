{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

redis-data-dir:
  file.directory:
    - name: {{ settings.redis_data }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0750'
    - makedirs: True
    - require:
      - file: wp-base-dir

redis-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-redis.service
    - source: salt://redis/files/redis.service.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        redis_ip: {{ settings.redis_ip }}
        network_name: {{ settings.network_name }}
        redis_password: {{ settings.redis_password }}
        redis_data: {{ settings.redis_data }}
        redis_maxmemory: {{ settings.redis_maxmemory }}
        image: {{ settings.images.redis }}
    - require:
      - file: wp-systemd-dir
      - file: redis-data-dir
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'

redis-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: redis-systemd-unit

redis-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-redis
    - cwd: {{ h }}
    - require:
      - cmd: redis-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: redis-systemd-unit
