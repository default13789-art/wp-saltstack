{% set minion = data.get('id', '') %}
{% set usage_data = data.get('data', {}) %}

disk_alert_{{ minion }}:
  local.cmd.run:
    - tgt: {{ minion }}
    - arg:
      - |
        echo "$(date -Iseconds) DISK WARNING on {{ minion }}: {{ usage_data }}" >> /var/log/wp/beacon-alerts.log
        sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/1001 podman system prune -f --filter "until=48h" 2>/dev/null || true
        journalctl --vacuum-time=7d 2>/dev/null || true
        find /tmp -type f -mtime +7 -delete 2>/dev/null || true
