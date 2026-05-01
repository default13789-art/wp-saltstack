{% set minion = data.get('id', '') %}
{% set change_data = data.get('data', {}) %}
{% set change_path = change_data.get('path', 'unknown') %}
{% set change_mask = change_data.get('mask', []) %}

config_change_alert_{{ minion }}:
  local.cmd.run:
    - tgt: {{ minion }}
    - arg:
      - echo "$(date -Iseconds) CONFIG CHANGE on {{ minion }}: path={{ change_path }} action={{ change_mask }}" >> /var/log/wp/beacon-alerts.log
