backup:
  backup_dir: /srv/wp/backups
  retention_days: 30
  schedule_hour: 3
  schedule_minute: 0

  offsite_enabled: false
  offsite_type: rsync
  offsite_target: ""
  offsite_rsync_key: ""
