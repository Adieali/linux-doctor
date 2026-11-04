# Serveur Debian avec systemd, pour que les pannes ressemblent à de la vraie prod.
FROM debian:13

ENV container=docker DEBIAN_FRONTEND=noninteractive

# LANG pour l'installation seulement : le cluster PostgreSQL créé par le paquet est en UTF-8.
RUN apt-get update \
 && LANG=C.UTF-8 apt-get install -y --no-install-recommends \
      systemd systemd-sysv procps iproute2 lsof psmisc curl nginx python3 cron less nano vim-tiny \
      openssh-server openssh-client logrotate sudo \
      iputils-ping bind9-dnsutils tcpdump strace dnsmasq-base dhcpcd-base \
      postgresql nftables \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl disable postgresql nftables \
 && systemctl mask getty.target systemd-udevd.service systemd-logind.service systemd-modules-load.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
