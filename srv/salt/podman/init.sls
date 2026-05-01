{% from "map.jinja" import settings with context %}

podman-pkgs:
  pkg.installed:
    - pkgs: {{ settings.packages.podman | json }}

podman-sysctl-ports:
  sysctl.present:
    - name: net.ipv4.ip_unprivileged_port_start
    - value: 80
    - require:
      - pkg: podman-pkgs

podman-user:
  user.present:
    - name: {{ settings.podman_user }}
    - uid: {{ settings.podman_uid }}
    - home: {{ settings.podman_home }}
    - createhome: True
    - shell: /bin/bash
    - system: True
    - require:
      - pkg: podman-pkgs

podman-subuid:
  file.replace:
    - name: /etc/subuid
    - pattern: '^{{ settings.podman_user }}:.*'
    - repl: '{{ settings.podman_user }}:{{ settings.subuid_start }}:{{ settings.subuid_count }}'
    - append_if_not_found: True
    - require:
      - user: podman-user

podman-subgid:
  file.replace:
    - name: /etc/subgid
    - pattern: '^{{ settings.podman_user }}:.*'
    - repl: '{{ settings.podman_user }}:{{ settings.subgid_start }}:{{ settings.subgid_count }}'
    - append_if_not_found: True
    - require:
      - user: podman-user

podman-linger:
  cmd.run:
    - name: loginctl enable-linger {{ settings.podman_uid }}
    - unless: test -f /var/lib/systemd/linger/{{ settings.podman_user }}
    - require:
      - user: podman-user
      - file: podman-subuid
      - file: podman-subgid

podman-wait-systemd:
  cmd.run:
    - name: >
        timeout 30 bash -c 'while ! sudo -u {{ settings.podman_user }} XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        systemctl --user is-system-running >/dev/null 2>&1; do sleep 1; done'
    - require:
      - cmd: podman-linger

podman-config-dir:
  file.directory:
    - name: {{ settings.podman_home }}/.config/containers
    - user: {{ settings.podman_user }}
    - group: {{ settings.podman_user }}
    - mode: '0700'
    - makedirs: True
    - require:
      - user: podman-user

podman-storage-conf:
  file.managed:
    - name: {{ settings.podman_home }}/.config/containers/storage.conf
    - source: salt://podman/files/storage.conf.jinja
    - template: jinja
    - context:
        podman_user: {{ settings.podman_user }}
    - user: {{ settings.podman_user }}
    - group: {{ settings.podman_user }}
    - mode: '0644'
    - require:
      - file: podman-config-dir

podman-containers-conf:
  file.managed:
    - name: {{ settings.podman_home }}/.config/containers/containers.conf
    - source: salt://podman/files/containers.conf.jinja
    - template: jinja
    - context:
        podman_user: {{ settings.podman_user }}
    - user: {{ settings.podman_user }}
    - group: {{ settings.podman_user }}
    - mode: '0644'
    - require:
      - file: podman-config-dir

podman-network:
  cmd.run:
    - name: >
        podman network create
        --subnet {{ settings.subnet }}
        --gateway {{ settings.gateway }}
        {{ settings.network_name }}
    - user: {{ settings.podman_user }}
    - cwd: {{ settings.podman_home }}
    - unless: test -f {{ settings.podman_home }}/.local/share/containers/storage/networks/{{ settings.network_name }}.json
    - environment:
        XDG_RUNTIME_DIR: /run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS: unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME: {{ settings.podman_home }}
    - require:
      - user: podman-user
      - cmd: podman-linger

wp-base-dir:
  file.directory:
    - name: {{ settings.base_dir }}
    - user: {{ settings.podman_user }}
    - group: {{ settings.podman_user }}
    - mode: '0750'
    - makedirs: True
    - require:
      - user: podman-user

wp-systemd-dir:
  file.directory:
    - name: {{ settings.podman_home }}/.config/systemd/user
    - user: {{ settings.podman_user }}
    - group: {{ settings.podman_user }}
    - mode: '0700'
    - makedirs: True
    - require:
      - user: podman-user
