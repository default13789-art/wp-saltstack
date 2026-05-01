base:
  'role:security':
    - match: grain
    - security

  'role:db':
    - match: grain
    - podman
    - mysql

  'role:cache':
    - match: grain
    - podman
    - redis

  'role:app':
    - match: grain
    - podman
    - wordpress

  'role:lb':
    - match: grain
    - podman
    - nginx

  'role:all-in-one':
    - match: grain
    - podman
    - mysql
    - redis
    - wordpress
    - nginx
    - security
