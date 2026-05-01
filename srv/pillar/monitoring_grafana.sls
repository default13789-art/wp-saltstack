monitoring_grafana:
  prometheus_ip: 10.89.0.40
  grafana_ip: 10.89.0.41
  node_exporter_ip: 10.89.0.42
  mysql_exporter_ip: 10.89.0.43
  redis_exporter_ip: 10.89.0.44

  grafana_admin_password: changeme

  scrape_interval: 15s
  evaluation_interval: 15s
  retention_time: 15d
