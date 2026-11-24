# 16. Le serveur répond au réseau d'admin, mais plus à la prod

## Le ticket

> **Ticket #4815, priorité critique**
> Depuis hier soir, la boutique ne répond plus aux clients : les pages restent blanches, puis le navigateur abandonne. Le serveur, lui, répond parfaitement depuis le bastion des admins, et la supervision est verte. Hier, ticket #4811 : ajout de l'interface d'admin (eth2), pour le bastion, le miroir de paquets et la supervision.
> Le pare-feu du serveur est vide, et le routeur de prod répond au ping.
> Pour tester : `client-internet curl http://10.60.0.10/` (un client de la boutique), `bastion curl http://10.70.0.10/` (un admin).
> Contraintes : le durcissement CIS du serveur reste appliqué tel quel (`/etc/sysctl.d/60-cis.conf`). Les mises à jour (miroir 10.90.0.5) et la supervision (10.90.0.20) passent par le réseau d'admin, jamais par la prod. Les admins arrivent aujourd'hui du bastion, et le mois prochain aussi du nouveau VPN d'admin, dont l'équipe réseau n'a pas encore choisi la plage. Tout doit tenir au redémarrage.
> Les netns `routeur-prod`, `internet`, `routeur-admin`, `bastion` et `services`, et les unités `lab-*`, simulent le reste du réseau : n'y touche pas.

## Impact business

La boutique ne vend plus depuis la veille au soir, et rien ne le signale : la supervision passe par le réseau d'admin, qui marche. Ce sont les clients qui ont prévenu, par téléphone. Le premier réflexe sera de retirer l'interface d'admin ajoutée la veille : la prod revient, mais le bastion, la supervision et les mises à jour tombent avec, et la demande de la sécurité repart à zéro.

## Les enjeux

- Comprendre pourquoi une requête arrive et qu'aucune réponse ne repart.
- Trouver le réglage du noyau qui jette ces requêtes en silence, et pourquoi il a raison de le faire.
- Faire partir chaque réponse par le réseau d'où vient la question, sans assouplir le durcissement.
- Accueillir un réseau d'admin dont on ne connaît pas encore les adresses, et tenir au redémarrage.

## Ce qui est vérifié

Le check rejoue d'abord un démarrage : interfaces descendues, routes et règles effacées, réglages du noyau relus, puis `ifup`. Il vérifie :

- le filtrage du chemin de retour reste strict sur eth1 et eth2 (CIS)
- un client d'Internet charge la boutique
- un client d'une autre plage d'Internet aussi
- les admins se connectent depuis le bastion
- la supervision interroge le serveur
- les mises à jour joignent le miroir
- elles passent par le réseau d'admin, pas par la prod
- les réponses aux clients partent par la prod

Si c'est bon, il ouvre le VPN d'admin sur une plage que le serveur ne connaît pas, et vérifie qu'un admin connecté au VPN atteint le serveur, sans changer sa configuration.

## Indices

<details><summary>Indice 1</summary>

Pendant qu'un client essaie, regarde ce qui arrive et ce qui repart : `tcpdump -ni any 'tcp port 80 and host 203.0.113.50'`. Puis cherche si le noyau a laissé une trace : `dmesg`.

</details>

<details><summary>Indice 2</summary>

Par où partirait une réponse au client ? `ip route get 203.0.113.50`. Et que vérifie le noyau, avec `rp_filter=1`, quand une requête arrive sur une interface ?

</details>

<details><summary>Indice 3</summary>

Une seule table de routage ne peut pas faire partir les réponses de deux façons. `ip rule` choisit la table selon l'adresse source.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
client-internet curl -s -o /dev/null --max-time 3 -w '%{http_code}\n' http://10.60.0.10/   # 000 : rien ne revient
bastion curl -s -o /dev/null -w '%{http_code}\n' http://10.70.0.10/                       # 200
curl -s -o /dev/null -w '%{http_code}\n' http://10.60.0.10/                                # 200 en local : nginx va bien
```

nginx répond, et le même serveur répond au bastion. Ce qui arrive et ce qui repart pendant qu'un client essaie :

```bash
timeout 4 tcpdump -lni any -c 3 'tcp port 80 and host 203.0.113.50' &
sleep 0.5
client-internet curl -s -o /dev/null --max-time 2 http://10.60.0.10/
wait
nstat -az TcpExtIPReversePathFilter     # augmente à chaque essai du client
dmesg | grep -i martian | tail -2       # martian source 10.60.0.10 from 203.0.113.50, on dev eth1
```

Les SYN du client arrivent sur eth1, et le serveur ne répond rien, pas même un refus. Le noyau, lui, compte ces paquets : il les jette avant que nginx les voie, au titre du filtrage du chemin de retour, et les note comme « martiens » dans `dmesg`. Le réglage en cause :

```bash
sysctl net.ipv4.conf.all.rp_filter      # 1 : strict, posé par 60-cis.conf
ip route                                # deux routes par défaut : via 10.70.0.1 (eth2) en métrique 10, via 10.60.0.1 (eth1) en métrique 100
ip route get 203.0.113.50               # via 10.70.0.1 dev eth2
```

Avec `rp_filter=1`, le noyau accepte un paquet seulement si la route vers son expéditeur sort par l'interface où il est arrivé. Le client arrive par eth1, mais la route vers lui sort par eth2 : depuis hier, la route par défaut de l'admin, en métrique 10, passe devant celle de la prod. Le paquet est jeté et noté comme martien (`log_martians`, autre réglage CIS). Sans ce filtrage, ce ne serait pas mieux : la réponse partirait vers le routeur d'admin, qui ne sait pas joindre Internet. Le bastion et la supervision passent parce qu'ils arrivent par eth2, et que leur route de retour sort aussi par eth2. Le filtrage fait son travail : c'est le routage qui est faux.

Retirer la route par défaut de l'admin ramènerait la prod, mais le bastion et la supervision prendraient la route de la prod pour leurs réponses, et seraient jetés à leur tour. Il faut deux routages : ce qui part de l'adresse d'admin repart par l'admin, le reste par la prod. Une règle `ip rule` choisit la table selon l'adresse source :

```bash
mkdir -p /etc/iproute2/rt_tables.d
echo '100 admin' > /etc/iproute2/rt_tables.d/admin.conf
cat > /etc/network/interfaces.d/admin <<'EOF'
# Réseau d'admin (tickets #4811 et #4815) : bastion, miroir de paquets, supervision, VPN d'admin.
# Pas de route par défaut ici : celle de la machine reste la prod.
auto eth2
iface eth2 inet static
    address 10.70.0.10/24
    # Ce qui part de l'adresse d'admin repart par l'admin : réponses au bastion, à la supervision, au VPN.
    up ip route add default via 10.70.0.1 dev eth2 table admin
    up ip rule add from 10.70.0.10 lookup admin pref 1000
    # Les mises à jour et la supervision (10.90.0.0/24) passent par l'admin, comme le veut la sécurité.
    up ip route add 10.90.0.0/24 via 10.70.0.1 dev eth2
    down ip rule del from 10.70.0.10 lookup admin pref 1000
EOF
```

Les routes disparaissent d'elles-mêmes quand l'interface descend, pas les règles : la ligne `down` retire celle qu'ajoute `up`, sinon chaque redémarrage de l'interface en empilerait une de plus. La route vers 10.90.0.0/24 compte autant que la règle : le serveur ouvre lui-même les connexions vers le miroir, depuis son adresse de prod si rien ne lui indique l'admin.

La même chose, à chaud, sans couper les sessions des admins : la table et la règle d'abord, le retrait de l'ancienne route par défaut en dernier. Dans l'autre ordre, les réponses au bastion partiraient un instant par la prod.

```bash
ip route add default via 10.70.0.1 dev eth2 table admin
ip rule add from 10.70.0.10 lookup admin pref 1000
ip route add 10.90.0.0/24 via 10.70.0.1 dev eth2
ip route del default via 10.70.0.1 dev eth2
client-internet curl -s -o /dev/null -w '%{http_code}\n' http://10.60.0.10/   # 200
bastion curl -s -o /dev/null -w '%{http_code}\n' http://10.70.0.10/           # 200
ip route get 10.90.0.5                  # dev eth2 : les mises à jour passent par l'admin
ip route get 203.0.113.50 from 10.70.0.10   # table admin, dev eth2
```

Le filtrage reste strict et passe désormais : pour vérifier un paquet arrivé sur eth2, le noyau cherche la route de retour depuis 10.70.0.10, la règle l'envoie dans la table `admin`, qui sort par eth2. Le futur VPN d'admin marchera sans rien changer : sa plage n'apparaît nulle part dans la configuration.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Désactiver `rp_filter`, ou le passer en lâche (2)** : contraire au CIS, et sans effet. Les requêtes arrivent, les réponses partent toujours vers le routeur d'admin, qui ne sait pas joindre Internet.
- **Retirer la route par défaut de l'admin, ou inverser les métriques** : la prod revient, le bastion et la supervision tombent, et les mises à jour sortent par la prod.
- **Des routes vers le bastion et la supervision** : marche aujourd'hui. Le VPN d'admin du mois prochain, sur une plage encore inconnue, tombera.
- **Corriger avec `ip` à la main seulement** : tout revient, jusqu'au prochain redémarrage, qui remet la route de métrique 10.
- **Une règle par adresse source et une table pour l'admin, dans `/etc/network/interfaces`** : chaque réponse repart par où est venue la question, le filtrage strict reste en place, le VPN marchera sans changement, et la configuration tient au redémarrage.

</details>

## En prod

- Un serveur a une seule route par défaut. Une deuxième interface n'en apporte pas, ou alors dans sa propre table.
- Sur un serveur à plusieurs interfaces, faire repartir les réponses par l'interface d'arrivée : une règle `from <adresse>` et une table par réseau.
- Requêtes visibles dans `tcpdump`, aucune réponse, rien dans les logs de l'application : penser au filtrage du chemin de retour. `nstat -az TcpExtIPReversePathFilter` compte les paquets jetés, et `log_martians` les fait apparaître dans `dmesg`.
- Le noyau retient la plus grande des deux valeurs entre `conf.all.rp_filter` et celle de l'interface : 2 (lâche) l'emporte sur 1 (strict), qui l'emporte sur 0. Une interface créée avant le chargement des réglages garde sa propre valeur : vérifier `conf.<interface>.rp_filter`, pas seulement `all`.
- Vérifier une sortie avant et après une modification : `ip route get <destination> from <source>`.
- Dans `/etc/network/interfaces`, une règle ajoutée en `up` se retire en `down`. Les routes partent avec l'interface, les règles restent.
