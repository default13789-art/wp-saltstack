base:
  'role:security':
    - match: grain
    - security
    - fail2ban
    - logrotate

  'role:db':
    - match: grain
    - podman
    - mysql
    - monitoring
    - backup
    - logrotate

  'role:cache':
    - match: grain
    - podman
    - redis
    - monitoring
    - logrotate

  'role:app':
    - match: grain
    - podman
    - wordpress
    - monitoring
    - backup
    - logrotate

  'role:lb':
    - match: grain
    - podman
    - nginx
    - anubis
    - monitoring
    - logrotate

  'role:all-in-one':
    - match: grain
    - podman
    - mysql
    - redis
    - wordpress
    - nginx
    - anubis
    - security
    - monitoring
    - backup
    - fail2ban
    - logrotate
