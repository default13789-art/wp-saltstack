{% set output = data.get('data', {}).get('output', '') | default('', true) %}
{% set minion = data.get('id', '') %}

{% if output %}
{% for line in output.strip().split('\n') %}
{% if line.strip() and ':' in line.strip() %}
{% set svc = line.strip().split(':')[0] %}

restart_{{ svc }}_on_{{ minion }}:
  local.cmd.run:
    - tgt: {{ minion }}
    - arg:
      - |
        sudo -u podman-wp \
          XDG_RUNTIME_DIR=/run/user/1001 \
          DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
          systemctl --user restart {{ svc }}
        echo "$(date -Iseconds) BEACON restarted {{ svc }}" >> /var/log/wp/beacon-alerts.log

{% endfor %}
{% endif %}
