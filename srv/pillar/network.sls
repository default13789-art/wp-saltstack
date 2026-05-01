network:
  domain: example.com

  ssh_port: 2222

  network_name: wp-network
  subnet: 10.89.0.0/24
  gateway: 10.89.0.1

  mysql_ip: 10.89.0.10
  redis_ip: 10.89.0.20
  wp_node1_ip: 10.89.0.31
  wp_node2_ip: 10.89.0.32
  nginx_ip: 10.89.0.2

  http_port: 80
  https_port: 443

  external_interface: eth0

  base_dir: /srv/wp
  mysql_data: /srv/wp/mysql/data
  mysql_conf: /srv/wp/mysql/conf
  mysql_init: /srv/wp/mysql/init
  uploads_dir: /srv/wp/uploads
  nginx_conf: /srv/wp/nginx/conf
  nginx_ssl: /srv/wp/nginx/ssl
  wp_config_dir: /srv/wp/wp-config
  wp_bin: /srv/wp/bin
