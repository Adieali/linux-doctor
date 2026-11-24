# 18. Deux serveurs ont la VIP en même temps

## Le ticket

> **Ticket #4834, priorité critique**
> Depuis ce matin, des clients voient leur panier se vider en pleine commande, et le support ne reproduit rien. L'équipe réseau signale une alerte sur l'adresse virtuelle de la boutique (10.100.0.100) : son adresse MAC change toutes les quelques secondes.
> La boutique tourne sur deux nœuds keepalived : srv-prod-02 en maître, srv-prod-01 (ce serveur) en secours. Les paniers sont gardés en session locale, sur le nœud qui sert le client. Hier soir, le pare-feu standard des serveurs de prod a été déployé sur srv-prod-01 (ticket sécurité #4830), et il autorise le VRRP entre les deux nœuds.
> Pour tester : `client curl http://10.100.0.100/`, plusieurs fois. Pour regarder l'autre nœud : `srv-prod-02 <commande>`.
> Contraintes : le pare-feu standard reste en place (politique drop en entrée), et la sécurité veut que srv-prod-01 n'accepte le VRRP que de son pair : n'importe quelle machine du LAN qui parle VRRP peut voler la VIP. Si srv-prod-02 tombe, srv-prod-01 doit reprendre la boutique en moins de 5 secondes.
> Les netns `lan`, `client` et `srv-prod-02`, et les unités `lab-*`, simulent le reste : n'y touche pas.

## Impact business

Chaque bascule entre les deux nœuds vide les paniers des clients en cours de commande : ils recommencent, ou partent. Le support reçoit des plaintes qu'il ne peut ni reproduire ni expliquer, et l'alerte réseau tombe chez une équipe qui n'a pas la main sur les serveurs. Si rien n'est fait, la prochaine vraie panne de srv-prod-02 trouvera un cluster déjà cassé.

## Les enjeux

- Comprendre comment deux nœuds peuvent se croire maîtres en même temps.
- Trouver pourquoi le secours n'entend plus le maître, alors que tout semble autorisé.
- Réparer sans affaiblir le pare-feu ni ouvrir le VRRP au reste du LAN.
- Vérifier que le cluster bascule encore, dans les deux sens.

## Ce qui est vérifié

Le check recharge d'abord le pare-feu depuis `/etc/nftables.conf`, comme au prochain démarrage, puis il vérifie :

- le pare-feu est chargé, politique drop en entrée
- keepalived tourne sur srv-prod-01
- une seule VIP : sur srv-prod-02, pas sur srv-prod-01
- 20 requêtes d'un client, toutes servies par srv-prod-02

Si c'est bon, il arrête keepalived sur srv-prod-02, fait annoncer la VIP par une autre machine du LAN, avec la priorité maximale, puis relance srv-prod-02. Il vérifie :

- srv-prod-01 prend la VIP en moins de 5 s
- les clients le joignent
- srv-prod-01 n'écoute pas l'intrus, et garde la VIP
- srv-prod-02 reprend la VIP, srv-prod-01 la rend

## Indices

<details><summary>Indice 1</summary>

Qui porte la VIP ? `ip -br addr show eth1`, ici et sur srv-prod-02. Et que raconte keepalived : `journalctl -u keepalived`.

</details>

<details><summary>Indice 2</summary>

Le maître annonce sa présence chaque seconde, en VRRP. Les annonces arrivent-elles sur eth1 ? `tcpdump -ni eth1 vrrp`. Et le noyau les laisse-t-il passer ?

</details>

<details><summary>Indice 3</summary>

La règle VRRP du pare-feu existe. Compare l'adresse qu'elle autorise avec celle d'où viennent les annonces.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
for i in 1 2 3 4; do client curl -s http://10.100.0.100/ | grep -o 'servie par [a-z0-9-]*'; sleep 3; done   # srv-prod-01, srv-prod-02, au gré des secondes
ip -br addr show eth1                              # 10.100.0.21/24 10.100.0.100/24 : srv-prod-01 porte la VIP
srv-prod-02 ip -br addr show eth1                  # 10.100.0.32/24 10.100.0.100/24 : srv-prod-02 aussi
journalctl -u keepalived -o cat | grep STATE | tail -2   # Entering MASTER STATE
```

Les deux nœuds portent la VIP, et chacun annonce toutes les 5 secondes, par un ARP gratuit, que l'adresse est chez lui. Le client suit le dernier qui a parlé, et ses requêtes changent de nœud, avec ses paniers. C'est un « split brain ».

En VRRP, le maître annonce sa présence chaque seconde. Un secours qui n'entend plus rien pendant trois secondes se déclare maître. srv-prod-01 n'entend donc pas srv-prod-02 :

```bash
timeout 3 tcpdump -lni eth1 -c 2 vrrp              # 10.100.0.32 > 224.0.0.18: VRRPv2, Advertisement, vrid 51, prio 150
nft list ruleset | grep -i vrrp                    # ip saddr 10.100.0.22 ip protocol vrrp accept
srv-prod-02 ip -br addr show eth1                  # 10.100.0.32
```

Les annonces arrivent bien : `tcpdump` les voit, avant le pare-feu. Elles viennent de 10.100.0.32. La règle du pare-feu autorise le VRRP depuis 10.100.0.22, l'adresse de srv-prod-02 dans la CMDB. srv-prod-02 a été réadressé depuis, et la CMDB n'a pas suivi. La règle a l'air juste, elle vise la bonne machine sous une adresse qui n'existe plus : la politique drop jette les annonces, et keepalived ne reçoit rien.

La règle corrigée, dans le fichier que relit le pare-feu au démarrage. Le VRRP reste limité au pair, comme le veut la sécurité :

```bash
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Pare-feu standard des serveurs de prod (ticket sécurité #4830).
flush ruleset

table inet filtre {
    chain entree {
        type filter hook input priority filter; policy drop;
        iif lo accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        tcp dport { 22, 80, 443 } accept
        # Cluster de la boutique : VRRP entre les deux nœuds, et seulement entre eux.
        # Ticket #4834 : srv-prod-02 est en 10.100.0.32 depuis sa migration (la CMDB disait 10.100.0.22).
        ip saddr 10.100.0.32 ip protocol vrrp accept
    }
}
EOF
nft -c -f /etc/nftables.conf && systemctl reload nftables
timeout 10 bash -c 'until ! ip -br addr show eth1 | grep -q 10.100.0.100/; do sleep 0.5; done'
ip -br addr show eth1                              # 10.100.0.21/24 seulement : srv-prod-01 a rendu la VIP
journalctl -u keepalived -o cat | grep STATE | tail -1   # Entering BACKUP STATE
```

srv-prod-01 entend de nouveau le maître, de priorité plus haute, et repasse en secours. Le client peut encore avoir l'ancienne adresse MAC en cache, mais srv-prod-02 renvoie un ARP gratuit toutes les 5 secondes (`vrrp_garp_master_refresh`) : en quelques secondes, tout le monde revient vers lui.

```bash
sleep 6
for i in 1 2 3 4; do client curl -s http://10.100.0.100/ | grep -o 'servie par [a-z0-9-]*'; sleep 1; done   # srv-prod-02, à chaque fois
```

Reste à corriger la CMDB, d'où le pare-feu standard tire ses adresses : sinon, le prochain déploiement du pare-feu remettra 10.100.0.22.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Arrêter keepalived sur srv-prod-01** : plus de split brain, et plus de secours non plus. La prochaine panne de srv-prod-02 arrête la boutique.
- **Accepter le VRRP de n'importe qui, ou de tout le LAN** : le cluster remarche, et n'importe quelle machine du réseau peut voler la VIP avec une priorité plus haute. Le check en fait l'essai.
- **Vider le pare-feu, ou passer la politique en accept** : la sécurité vient de le déployer, il reviendra.
- **Monter la priorité de srv-prod-01, ou changer son identifiant VRRP** : il n'entend toujours rien, il reste maître, et le split brain continue.
- **Ajouter la règle avec `nft add rule`, à chaud** : tout revient, jusqu'au prochain rechargement du pare-feu.
- **La bonne adresse du pair dans `/etc/nftables.conf`, puis dans la CMDB** : srv-prod-01 entend le maître, le VRRP reste limité au pair, et le correctif tient au prochain déploiement.

</details>

## En prod

- Split brain VRRP : vérifier d'abord que chaque nœud entend l'autre. `tcpdump -ni <interface> vrrp` montre ce qui arrive, avant le pare-feu.
- Dans un pare-feu, autoriser le VRRP (protocole 112) depuis les pairs du cluster seulement. Une règle trop large laisse n'importe qui prendre la VIP.
- Une règle de pare-feu bâtie sur une adresse dépend de la source de vérité qui l'a produite. Un réadressage doit passer par la CMDB, puis par les règles qui en découlent.
- Superviser la VIP sur tous les nœuds : présente sur deux nœuds à la fois, c'est une alerte, pas un avertissement.
- `vrrp_garp_master_refresh` fait renvoyer des ARP gratuits par le maître : après une bascule ou un split brain, les clients et les switchs suivent sans attendre l'expiration de leur cache ARP.
