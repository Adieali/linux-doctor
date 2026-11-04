# 07. Les gros transferts se figent, les petits passent

## Le ticket

> **Ticket #4677, priorité haute**
> Depuis la mise en service du nouveau lien VPN avec l'agence de Lyon, lundi, les agents ne peuvent plus télécharger les rapports mensuels de l'intranet : le téléchargement ne démarre jamais, puis tombe en timeout. Les pages de l'intranet s'affichent normalement. Depuis le siège, tout marche. Un agent dit que « parfois, ça passe ».
> L'équipe réseau a vérifié le tunnel : aucune perte entre les routeurs, débit nominal.
> Pour tester depuis un poste de Lyon : `poste-lyon curl -o /dev/null http://10.20.0.10/rapport-octobre.pdf`.
> Contraintes : la règle PSSI-12 du pare-feu (le serveur ne répond pas au ping) est contrôlée par l'audit, elle reste. Le tunnel et les routeurs appartiennent à l'équipe réseau, et le tunnel va encore changer dans les semaines qui viennent (passage en IPsec).
> Les netns `siege`, `agence` et `poste` simulent le reste du réseau : n'y touche pas, sauf pour tester avec `poste-lyon`.

## Impact business

L'agence de Lyon travaille sans ses rapports depuis lundi. Les agents se les font envoyer par mail, ce qui contourne les droits d'accès de l'intranet et fait sortir des documents internes du système d'information. Chaque équipe renvoie le problème à l'autre : le réseau a un tunnel sans perte, le serveur répond à toutes ses pages. Le ticket peut tourner des semaines comme ça.

## Les enjeux

- Expliquer pourquoi la taille compte : les petits échanges passent, les gros n'arrivent jamais.
- Trouver qui devait prévenir le serveur, et pourquoi le serveur ne l'entend pas.
- Corriger sans affaiblir la règle de l'audit.
- Choisir une correction qui s'adapte quand le réseau change, plutôt qu'un chiffre figé.

## Ce qui est vérifié

Le check recharge d'abord le pare-feu depuis /etc/nftables.conf, comme au prochain démarrage, et fait oublier à toutes les machines les MTU déjà appris. Puis il vérifie :

- le pare-feu est chargé
- le serveur ne répond toujours pas au ping (PSSI-12)
- les pages légères passent depuis Lyon
- le rapport de 2 Mo arrive complet à Lyon en moins de 5 s
- le serveur a appris le MTU du chemin vers Lyon (1400)

Ensuite, il passe le tunnel en 1380, comme le fera l'IPsec, et vérifie que le rapport arrive encore complet.

## Indices

<details><summary>Indice 1</summary>

Une page passe, un fichier de 2 Mo ne reçoit pas un octet. Pendant un téléchargement, regarde ce que le serveur envoie et ce qu'il reçoit : `tcpdump -ni eth1 'icmp or (tcp src port 80 and greater 1000)'`.

</details>

<details><summary>Indice 2</summary>

`tcpdump` voit les paquets avant le pare-feu. Un message arrive sur eth1 : est-ce que le noyau l'a reçu ? Compare avec `nft list ruleset` et `ip route get 10.40.0.10`.

</details>

<details><summary>Indice 3</summary>

PSSI-12 veut empêcher le ping. Parmi les types ICMP, lesquels ne servent pas à scanner mais à faire fonctionner IP et TCP ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
poste-lyon curl -s -o /dev/null -w '%{http_code}, %{size_download} octets\n' http://10.20.0.10/   # 200, la page passe
poste-lyon curl -s -o /dev/null --max-time 5 -w '%{size_download} octets en 5 s\n' http://10.20.0.10/rapport-octobre.pdf   # 0 octet
```

Même pas les en-têtes HTTP : ils partent dans le même segment que le début du fichier. Ce qui part et ce qui revient, pendant un téléchargement :

```bash
timeout 4 tcpdump -lni eth1 -c 6 'icmp or (tcp src port 80 and greater 1000)' &
sleep 0.5
poste-lyon curl -s -o /dev/null --max-time 3 http://10.20.0.10/rapport-octobre.pdf
wait
```

Le serveur envoie des segments de 1448 octets de données (1500 avec les en-têtes), et le routeur du siège répond à chacun : `ICMP 10.40.0.10 unreachable - need to frag (mtu 1400)`. Le serveur renvoie pourtant le même segment, de la même taille, encore et encore.

Le serveur et le poste de Lyon sont tous deux sur des réseaux en MTU 1500 : chacun annonce un MSS de 1460 dans sa poignée de main, et aucun des deux ne voit le tunnel. Celui-ci ne passe que 1400 octets, le reste étant pris par l'encapsulation. Les paquets TCP portent le drapeau DF (ne pas fragmenter) : le routeur ne peut pas les découper, il les jette et prévient l'émetteur par un ICMP de type 3, code 4, qui contient le MTU à respecter. C'est la découverte du MTU du chemin (PMTUD). Une page légère tient dans un seul petit paquet, elle n'a jamais affaire à cette limite.

```bash
nft list ruleset                      # meta l4proto icmp drop : PSSI-12 jette tout l'ICMP
ip route get 10.40.0.10               # aucun mtu appris : le message n'est jamais arrivé jusqu'à TCP
```

`tcpdump` capture les paquets avant le pare-feu, d'où ce qu'il montre : le message arrive bien sur eth1, puis `nftables` le jette avec le reste de l'ICMP. Le serveur ne sait jamais qu'il doit réduire ses paquets : c'est un trou noir PMTUD.

Le « parfois, ça passe » a aussi son explication. Un poste qui envoie lui-même un gros paquet vers le serveur (une connexion SSH, par exemple : l'échange de clés d'OpenSSH dépasse 1400 octets) reçoit l'ICMP du routeur de Lyon, que rien ne filtre de son côté. Pendant dix minutes, il retient le MTU 1400, annonce un MSS de 1360 dans ses connexions, et ses téléchargements passent. Puis la panne revient.

PSSI-12 vise le ping, c'est-à-dire les demandes d'écho. Les messages d'erreur ICMP ne répondent à aucun scan : ils signalent qu'une destination est injoignable, qu'un paquet est trop gros ou qu'il a expiré en route. Les laisser passer avant la règle de l'audit :

```bash
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Pare-feu du serveur.
flush ruleset

table inet filtre {
    chain entree {
        type filter hook input priority filter; policy accept;
        # Ticket #4677 : les erreurs ICMP font fonctionner IP et TCP, dont la découverte du MTU du chemin.
        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        # PSSI-12 (audit 2025) : le serveur ne répond pas aux scans. Aucun autre ICMP, donc pas de ping.
        meta l4proto icmp drop
    }
}
EOF
nft -c -f /etc/nftables.conf && systemctl reload nftables
```

`nft -c` vérifie le fichier avant de le charger : une erreur de syntaxe dans un pare-feu se découvre mieux avant qu'après. Puis :

```bash
poste-lyon curl -s -o /dev/null --max-time 5 -w '%{size_download} octets en %{time_total} s\n' http://10.20.0.10/rapport-octobre.pdf   # 2097152 octets
ip route get 10.40.0.10                # cache expires ... mtu 1400 : appris au premier segment
poste-lyon ping -c 1 -W 1 10.20.0.10   # toujours aucune réponse : PSSI-12 tient
```

Le serveur apprend le MTU de chaque chemin tout seul, pour chaque destination, et le réapprendra quand le tunnel passera en IPsec. Dernière étape, hors du serveur : envoyer à l'équipe sécurité la règle ajoutée et sa raison, pour qu'elle entre dans le référentiel PSSI. Et proposer à l'équipe réseau de clamper le MSS sur les routeurs du tunnel : ça protège aussi les machines de l'agence dont le pare-feu ne sera pas corrigé.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Chercher du côté du tunnel** : il ne perd rien entre les routeurs, et c'est vrai. Les paquets trop gros sont jetés à son entrée, et l'erreur est signalée correctement. Elle est perdue chez le destinataire.
- **Autoriser tout l'ICMP** : les téléchargements passent, et le serveur répond de nouveau au ping. L'audit le verra.
- **Passer eth1 en MTU 1400** : tout le trafic du LAN paie pour un seul tunnel. Et au passage en IPsec, en 1380, le trou noir revient.
- **Une route vers Lyon avec `mtu 1400`** : le même chiffre figé, qui devient faux au premier changement du tunnel. Chaque nouveau site distant demandera sa propre route.
- **Clamper le MSS sur le serveur à une valeur fixe** : même défaut, le chiffre ne suit pas le réseau, et seul TCP en profite.
- **`tcp_mtu_probing=1`** : le noyau finit par détecter le trou noir après plusieurs retransmissions perdues. Le rapport n'arrive pas en 5 s, et chaque nouvelle connexion repaie cette attente.
- **Vider le pare-feu avec `nft flush ruleset`** : tout remarche jusqu'au prochain rechargement, et PSSI-12 disparaît en attendant.
- **Laisser passer les erreurs ICMP avant la règle PSSI-12** : la découverte du MTU fonctionne vers toutes les destinations, suit le tunnel quand il change, et le ping reste bloqué.

</details>

## En prod

- « Les petits échanges passent, les gros se figent » : penser MTU en premier, surtout après la mise en service d'un tunnel, d'un VPN ou d'un lien opérateur.
- Ne jamais filtrer tout l'ICMP. En IPv4, laisser passer au moins `destination-unreachable` (type 3) et `time-exceeded`. En IPv6, `packet-too-big` est indispensable : les routeurs n'y fragmentent jamais.
- `tcpdump` montre ce qui arrive sur l'interface, pas ce que le noyau accepte. Un paquet visible dans la capture peut très bien être jeté juste après par le pare-feu.
- Sur les routeurs d'un tunnel, clamper le MSS au MTU du tunnel. Ça protège aussi les machines dont on ne maîtrise pas le pare-feu.
- Pour mesurer le MTU d'un chemin : `tracepath`, ou `ping -M do -s <taille>` vers une destination qui répond au ping.
