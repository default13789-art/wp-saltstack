{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

anubis-conf-dir:
  file.directory:
    - name: {{ settings.base_dir }}/anubis/conf
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

anubis-bot-policy:
  file.managed:
    - name: {{ settings.base_dir }}/anubis/conf/bot-policy.yaml
    - source: salt://anubis/files/bot-policy.yaml.jinja
    - template: jinja
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: anubis-conf-dir

anubis-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-anubis.service
    - source: salt://anubis/files/anubis.service.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        anubis_ip: {{ settings.anubis_ip }}
        nginx_ip: {{ settings.nginx_ip }}
        network_name: {{ settings.network_name }}
        anubis_conf: {{ settings.base_dir }}/anubis/conf
        image: {{ settings.images.anubis }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: anubis-bot-policy

anubis-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: anubis-systemd-unit

anubis-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-anubis
    - cwd: {{ h }}
    - require:
      - cmd: anubis-daemon-reload
      - cmd: podman-network
      - cmd: nginx-service
    - onchanges:
      - file: anubis-systemd-unit
      - file: anubis-bot-policy
