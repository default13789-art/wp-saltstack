{% from "map.jinja" import settings with context %}

ufw-pkg:
  pkg.installed:
    - name: ufw

ufw-config:
  file.managed:
    - name: /etc/ufw/ufw.conf
    - source: salt://security/files/ufw.jinja
    - template: jinja
    - context:
        ssh_port: {{ settings.ssh_port }}
    - require:
      - pkg: ufw-pkg

ufw-defaults-default-input:
  file.replace:
    - name: /etc/default/ufw
    - pattern: '^DEFAULT_INPUT_POLICY=".*"'
    - repl: 'DEFAULT_INPUT_POLICY="DROP"'
    - append_if_not_found: True
    - require:
      - pkg: ufw-pkg

ufw-defaults-default-output:
  file.replace:
    - name: /etc/default/ufw
    - pattern: '^DEFAULT_OUTPUT_POLICY=".*"'
    - repl: 'DEFAULT_OUTPUT_POLICY="ACCEPT"'
    - append_if_not_found: True
    - require:
      - pkg: ufw-pkg

ufw-defaults-default-forward:
  file.replace:
    - name: /etc/default/ufw
    - pattern: '^DEFAULT_FORWARD_POLICY=".*"'
    - repl: 'DEFAULT_FORWARD_POLICY="DROP"'
    - append_if_not_found: True
    - require:
      - pkg: ufw-pkg

ufw-allow-ssh:
  cmd.run:
    - name: ufw allow {{ settings.ssh_port }}/tcp
    - unless: 'ufw status | grep -q "^{{ settings.ssh_port }}/tcp"'
    - require:
      - file: ufw-config

ufw-allow-http:
  cmd.run:
    - name: ufw allow {{ settings.http_port }}/tcp
    - unless: 'ufw status | grep -q "^{{ settings.http_port }}/tcp"'
    - require:
      - file: ufw-config

ufw-allow-https:
  cmd.run:
    - name: ufw allow {{ settings.https_port }}/tcp
    - unless: 'ufw status | grep -q "^{{ settings.https_port }}/tcp"'
    - require:
      - file: ufw-config

ufw-enable:
  cmd.run:
    - name: ufw --force enable
    - unless: 'ufw status | grep -q "Status: active"'
    - require:
      - cmd: ufw-allow-ssh
      - cmd: ufw-allow-http
      - cmd: ufw-allow-https

ufw-allow-podman-route:
  cmd.run:
    - name: >
        ufw route allow from {{ settings.subnet }}
    - unless: >
        ufw status routed | grep -q "{{ settings.subnet }}"
    - require:
      - cmd: ufw-enable

openssh-server-pkg:
  pkg.installed:
    - name: openssh-server

sshd-config:
  file.managed:
    - name: /etc/ssh/sshd_config
    - source: salt://security/files/sshd_config.jinja
    - template: jinja
    - context:
        ssh_port: {{ settings.ssh_port }}
    - require:
      - pkg: openssh-server-pkg
      - cmd: ufw-enable

sshd-service:
  service.running:
    - name: ssh
    - enable: True
    - watch:
      - file: sshd-config
    - require:
      - pkg: openssh-server-pkg
      - file: sshd-config
