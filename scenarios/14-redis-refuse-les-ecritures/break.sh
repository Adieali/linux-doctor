#!/usr/bin/env bash
# Panne : Redis n'a pas de maxmemory, et ses 500 000 paniers occupent près de 300 Mo des 400 Mo que l'unité
# lui accorde (MemoryMax, sans swap). Plus de la moitié, pour qu'une copie complète déborde.
# À chaque BGSAVE, Redis forke : le fils partage la mémoire du père, mais chaque page que le père modifie
# pendant la sauvegarde est copiée (copy-on-write). Sous l'écriture de l'application, les copies dépassent
# la limite du cgroup, le noyau tue le fils (oom-score-adj le désigne en premier), et
# stop-writes-on-bgsave-error fait refuser toute écriture : MISCONF.
# Fausses pistes : vm.overcommit_memory (le fork réussit), le disque (à moitié vide).
set -euo pipefail

r() { redis-cli "$@"; }

install -d /etc/systemd/system/redis-server.service.d
cat > /etc/systemd/system/redis-server.service.d/memoire.conf <<'EOF'
# Équipe système : Redis a droit à 400 Mo sur ce serveur, sans swap. Si la mémoire manque, le noyau tue
# le fils de sauvegarde (oom-score-adj dans redis.conf), et Redis, lui, continue.
[Service]
MemoryMax=400M
MemorySwapMax=0
OOMPolicy=continue
EOF
cat >> /etc/redis/redis.conf <<'EOF'

# Si la mémoire manque, le fils de sauvegarde part avant le processus principal.
oom-score-adj yes
EOF
systemctl daemon-reload
systemctl enable --now redis-server 2>/dev/null
for _ in {1..60}; do r ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done

# Les paniers : un panier vit 7 jours après sa dernière modification. Ici, des paniers d'âges variés.
peupler() { # premier, dernier
  r eval "for i = tonumber(ARGV[1]), tonumber(ARGV[2]) do
            redis.call('SET', string.format('panier:%012d', i), string.rep('x', 400),
                       'EX', math.random(3600, 604800))
          end" 0 "$@" >/dev/null
}
for debut in 0 100000 200000 300000 400000; do
  peupler "$debut" $((debut + 99999))
done
r save >/dev/null

# L'application : des paniers existants modifiés en continu, n'importe où dans la base.
install -d /opt/labo
cat > /opt/labo/paniers <<'EOF'
#!/bin/bash
while :; do
  redis-benchmark -q -n 8000 -r 500000 SET 'panier:__rand_int__' "$(printf 'x%.0s' {1..400})" EX 604800 >/dev/null 2>&1
  sleep 1
done
EOF
chmod +x /opt/labo/paniers
cat > /etc/systemd/system/lab-paniers.service <<'EOF'
[Unit]
Description=Labo : application, paniers des clients (ne pas toucher)
After=redis-server.service

[Service]
ExecStart=/opt/labo/paniers
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-paniers 2>/dev/null
sleep 2

# La sauvegarde de 10 h, en pleine pointe d'écriture des clients.
# Sur certains noyaux (7.0 du runner GitHub), le père est parfois tué une milliseconde après le fils : ses
# nouvelles copies arrivent avant que la mémoire du fils soit rendue. systemd le relance, il recharge ses
# paniers depuis le SAVE ci-dessus, et on rejoue la pointe. L'état final reste MISCONF, Redis vivant.
persistance() { r info persistence 2>/dev/null | tr -d '\r' | sed -n "s/^$1://p"; }
for _ in {1..8}; do
  for _ in {1..120}; do [[ $(persistance loading) == 0 ]] && break; sleep 0.5; done
  redis-benchmark -q -n 400000 -r 500000 -c 8 SET 'panier:__rand_int__' "$(printf 'x%.0s' {1..400})" EX 604800 >/dev/null 2>&1 &
  sleep 1
  r bgsave >/dev/null 2>&1 || true
  for _ in {1..120}; do [[ $(persistance rdb_bgsave_in_progress) == 0 ]] && break; sleep 0.5; done
  wait
  if r set controle 1 2>&1 | grep -q MISCONF; then exit 0; fi
done
exit 1
