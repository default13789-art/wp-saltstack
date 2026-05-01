{% from "map.jinja" import settings with context %}
{% set sops_version = settings.sops_version %}
{% set age_version = settings.age_version %}
{% set arch = 'amd64' if grains['cpuarch'] == 'x86_64' else 'arm64' %}

sops-age-key-dir:
  file.directory:
    - name: /root/.config/sops/age
    - mode: '0700'
    - makedirs: True

sops-age-keygen:
  cmd.run:
    - name: age-keygen -o /root/.config/sops/age/keys.txt 2>/dev/null
    - unless: test -f /root/.config/sops/age/keys.txt
    - require:
      - file: sops-age-key-dir
    - require_in:
      - cmd: sops-age-pubkey

sops-age-pubkey:
  cmd.run:
    - name: age-keygen -y /root/.config/sops/age/keys.txt > /root/.config/sops/age/public.txt
    - unless: test -f /root/.config/sops/age/public.txt
    - require:
      - file: sops-age-key-dir

sops-install:
  cmd.run:
    - name: >
        curl -sSL
        https://github.com/getsops/sops/releases/download/v{{ sops_version }}/sops-v{{ sops_version }}.linux.{{ arch }}
        -o /usr/local/bin/sops && chmod +x /usr/local/bin/sops
    - unless: test -f /usr/local/bin/sops

age-install:
  cmd.run:
    - name: >
        curl -sSL
        https://github.com/FiloSottile/age/releases/download/v{{ age_version }}/age-v{{ age_version }}-linux-{{ arch }}.tar.gz
        -o /tmp/age.tar.gz &&
        tar xzf /tmp/age.tar.gz -C /tmp &&
        mv /tmp/age/age /usr/local/bin/age &&
        mv /tmp/age/age-keygen /usr/local/bin/age-keygen &&
        rm -rf /tmp/age /tmp/age.tar.gz
    - unless: test -f /usr/local/bin/age

sops-helper-script:
  file.managed:
    - name: /usr/local/bin/wp-secrets
    - source: salt://sops/files/secrets-helper.sh.jinja
    - template: jinja
    - context:
        secrets_file: {{ settings.sops_secrets_file }}
        age_key_file: /root/.config/sops/age/keys.txt
        age_pub_file: /root/.config/sops/age/public.txt
        sops_config: {{ settings.sops_config_file }}
    - mode: '0755'
    - require:
      - cmd: sops-install
      - cmd: age-install

sops-dot-config:
  cmd.run:
    - name: >
        PUB_KEY=$(age-keygen -y /root/.config/sops/age/keys.txt) &&
        mkdir -p {{ settings.base_dir }} &&
        cat > {{ settings.sops_config_file }} <<SEOF
        creation_rules:
          - path_regex: ^srv/pillar/secrets\\.sls\$
            age: ${PUB_KEY}
        SEOF
    - unless: test -f {{ settings.sops_config_file }}
    - require:
      - cmd: sops-age-keygen
