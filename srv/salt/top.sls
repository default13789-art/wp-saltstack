base:
  'role:security':
    - match: grain
    - security

  'role:db':
    - match: grain
    - podman
    - mysql
    - monitoring

  'role:cache':
    - match: grain
    - podman
    - redis
    - monitoring

  'role:app':
    - match: grain
    - podman
    - wordpress
    - monitoring

  'role:lb':
    - match: grain
    - podman
    - nginx
    - anubis
    - monitoring

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
