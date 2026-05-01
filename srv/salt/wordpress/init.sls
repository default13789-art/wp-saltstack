{% from "map.jinja" import settings with context %}
{% set u = settings.podman_user %}
{% set h = settings.podman_home %}

wp-bin-dir:
  file.directory:
    - name: {{ settings.wp_bin }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

wp-containerfile:
  file.managed:
    - name: {{ settings.wp_bin }}/Containerfile
    - source: salt://wordpress/files/Containerfile.jinja
    - template: jinja
    - context:
        base_image: {{ settings.images.wordpress }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-bin-dir

wp-custom-image:
  cmd.run:
    - name: >
        podman build
        --dns=8.8.8.8 --dns=1.1.1.1
        -t wp-phpredis:latest
        -f {{ settings.wp_bin }}/Containerfile
        {{ settings.wp_bin }}
    - user: {{ u }}
    - cwd: {{ h }}
    - environment:
        XDG_RUNTIME_DIR: /run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS: unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME: {{ h }}
    - unless: test -f {{ settings.wp_core_dir }}/wp-settings.php
    - require:
      - file: wp-containerfile
      - cmd: podman-linger

wp-core-dir:
  file.directory:
    - name: {{ settings.wp_core_dir }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

wp-core-extract:
  cmd.run:
    - name: >
        podman create --name wp-core-temp wp-phpredis:latest >/dev/null 2>&1 &&
        podman cp wp-core-temp:/usr/src/wordpress/. {{ settings.wp_core_dir }}/ &&
        podman rm wp-core-temp >/dev/null 2>&1
    - user: {{ u }}
    - cwd: {{ h }}
    - environment:
        XDG_RUNTIME_DIR: /run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS: unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME: {{ h }}
    - unless: test -f {{ settings.wp_core_dir }}/wp-settings.php
    - require:
      - file: wp-core-dir
      - cmd: wp-custom-image

wp-uploads-dir:
  file.directory:
    - name: {{ settings.uploads_dir }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

wp-plugins-dir:
  file.directory:
    - name: {{ settings.base_dir }}/wp-content/plugins
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

wp-themes-dir:
  file.directory:
    - name: {{ settings.base_dir }}/wp-content/themes
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

wp-seed-plugins:
  cmd.run:
    - name: cp -a {{ settings.wp_core_dir }}/wp-content/plugins/. {{ settings.base_dir }}/wp-content/plugins/
    - unless: test -f {{ settings.base_dir }}/wp-content/plugins/akismet/akismet.php
    - require:
      - cmd: wp-core-extract
      - file: wp-plugins-dir

wp-seed-themes:
  cmd.run:
    - name: cp -a {{ settings.wp_core_dir }}/wp-content/themes/. {{ settings.base_dir }}/wp-content/themes/
    - unless: test -d {{ settings.base_dir }}/wp-content/themes/twentytwentyfour
    - require:
      - cmd: wp-core-extract
      - file: wp-themes-dir

wp-cli-download:
  cmd.run:
    - name: >
        curl -sSfL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        -o {{ settings.wp_bin }}/wp-cli.phar
    - unless: test -f {{ settings.wp_bin }}/wp-cli.phar
    - user: {{ u }}
    - environment:
        XDG_RUNTIME_DIR: /run/user/{{ settings.podman_uid }}
        HOME: {{ h }}
    - require:
      - file: wp-bin-dir

wp-cli-wrapper:
  file.managed:
    - name: /usr/local/bin/wp
    - source: salt://wordpress/files/wp-cli-wrapper.sh.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        podman_uid: {{ settings.podman_uid }}
    - mode: '0755'
    - require:
      - cmd: wp-cli-download

wp-config-dir:
  file.directory:
    - name: {{ settings.wp_config_dir }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0755'
    - makedirs: True
    - require:
      - file: wp-base-dir

wp-config-file:
  file.managed:
    - name: {{ settings.wp_config_dir }}/wp-config.php
    - source: salt://wordpress/files/wp-config.php.jinja
    - template: jinja
    - context:
        db_host: {{ settings.mysql_ip }}
        db_user: {{ settings.mysql_wp_user }}
        db_pass: {{ settings.mysql_wp_pass }}
        db_name: {{ settings.mysql_wp_db }}
        redis_host: {{ settings.redis_ip }}
        redis_password: {{ settings.redis_password }}
        domain: {{ settings.domain }}
        wp_auth_key: {{ settings.wp_auth_key }}
        wp_secure_auth_key: {{ settings.wp_secure_auth_key }}
        wp_logged_in_key: {{ settings.wp_logged_in_key }}
        wp_nonce_key: {{ settings.wp_nonce_key }}
        wp_auth_salt: {{ settings.wp_auth_salt }}
        wp_secure_auth_salt: {{ settings.wp_secure_auth_salt }}
        wp_logged_in_salt: {{ settings.wp_logged_in_salt }}
        wp_nonce_salt: {{ settings.wp_nonce_salt }}
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-config-dir

wp-php-ini:
  file.managed:
    - name: {{ settings.wp_config_dir }}/uploads.ini
    - source: salt://wordpress/files/uploads.ini.jinja
    - template: jinja
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-config-dir

{% for node_num, node_ip in [('1', settings.wp_node1_ip), ('2', settings.wp_node2_ip)] %}

wp-node{{ node_num }}-systemd-unit:
  file.managed:
    - name: {{ h }}/.config/systemd/user/container-wp-node{{ node_num }}.service
    - source: salt://wordpress/files/wp-node.service.jinja
    - template: jinja
    - context:
        podman_user: {{ u }}
        node_num: {{ node_num }}
        node_ip: {{ node_ip }}
        network_name: {{ settings.network_name }}
        uploads_dir: {{ settings.uploads_dir }}
        wp_config_dir: {{ settings.wp_config_dir }}
        wp_bin_dir: {{ settings.wp_bin }}
        wp_plugins_dir: {{ settings.base_dir }}/wp-content/plugins
        wp_themes_dir: {{ settings.base_dir }}/wp-content/themes
        image: wp-phpredis:latest
    - user: {{ u }}
    - group: {{ u }}
    - mode: '0644'
    - require:
      - file: wp-systemd-dir
      - file: wp-uploads-dir
      - file: wp-plugins-dir
      - file: wp-themes-dir
      - file: wp-config-file
      - file: wp-php-ini
      - cmd: wp-custom-image

wp-node{{ node_num }}-daemon-reload:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user daemon-reload
    - cwd: {{ h }}
    - onchanges:
      - file: wp-node{{ node_num }}-systemd-unit

wp-node{{ node_num }}-service:
  cmd.run:
    - name: >
        sudo -u {{ u }}
        XDG_RUNTIME_DIR=/run/user/{{ settings.podman_uid }}
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{{ settings.podman_uid }}/bus
        HOME={{ h }}
        systemctl --user enable --now container-wp-node{{ node_num }}
    - cwd: {{ h }}
    - require:
      - cmd: wp-node{{ node_num }}-daemon-reload
      - cmd: podman-network
    - onchanges:
      - file: wp-node{{ node_num }}-systemd-unit

{% endfor %}
