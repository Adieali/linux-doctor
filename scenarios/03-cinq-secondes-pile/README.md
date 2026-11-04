# 03. Certaines requêtes prennent 5 secondes pile

## Le ticket

> **Ticket #4527, priorité haute**
> Depuis hier 17 h 02, l'API commandes décroche. `/api/orders` reste instantané. `/api/stock` prend 5 secondes, `/api/paiement` 10 secondes, jamais de valeur entre les deux. Le taux d'abandon au paiement monte.
> Remontée de l'astreinte : `sudo` met 10 secondes à répondre, une session `ssh 10.20.0.10` met 45 secondes à s'ouvrir.
> Déjà vérifié : CPU, mémoire et disque normaux. Le ping vers les services internes est sous la milliseconde. Le service stock jure que ses temps de réponse n'ont pas bougé.
> Contraintes : ce serveur reste en DHCP, et le serveur DHCP appartient à l'équipe réseau (plusieurs jours de délai pour tout changement). Les services internes changent d'adresse lors d'une bascule de reprise, aucune adresse en dur.
> Les unités `lab-*` simulent le reste du réseau : considère-les comme des machines distantes, n'y touche pas.

## Impact business

Un paiement qui met 10 secondes, c'est un client qui clique deux fois ou qui part. Chaque requête bloquée garde aussi un worker occupé : à la prochaine pointe, l'attente se transforme en file, puis en erreurs 502. L'astreinte perd de son côté 45 secondes par connexion sur le serveur qu'elle doit réparer, ce qui ralentit toutes les interventions tant que le problème dure. Et comme tout finit par répondre, aucune alerte de disponibilité ne se déclenche : seule la courbe de latence le montre.

## Les enjeux

- Relier trois symptômes sans rapport apparent : une API, `sudo` et SSH.
- Lire le chiffre. Des durées rondes, toujours multiples de 5, ne ressemblent pas à une charge : la charge donne des durées qui varient.
- Ne pas s'arrêter au premier `5` trouvé dans une configuration.
- Corriger là où la valeur est fabriquée, sans toucher au DHCP de l'équipe réseau.

## Ce qui est vérifié

- dhcpcd tourne et eth1 garde son adresse DHCP

Si c'est bon, le check force un renouvellement DHCP, comme ceux qui arrivent tout seuls, puis vérifie :

- un nom interne se résout en moins d'une seconde, dix fois de suite
- un nom court aussi, avec la liste de recherche
- `/api/stock` et `/api/paiement` répondent en moins d'une seconde
- `sudo` répond en moins d'une seconde
- une session SSH s'ouvre en moins d'une seconde

## Indices

<details><summary>Indice 1</summary>

`curl -w` sait découper le temps d'une requête : `time_namelookup`, `time_connect`, `time_starttransfer`. Essaie-le sur un service interne appelé par son nom, puis par son adresse.

</details>

<details><summary>Indice 2</summary>

`strace -r -e trace=connect,poll getent ahosts stock.interne.lan`. Regarde à qui le processus parle, et combien de temps il attend. Puis `man resolv.conf`, options `timeout` et `attempts`.

</details>

<details><summary>Indice 3</summary>

Ta correction marche, puis le problème revient quelques minutes plus tard ? Lis /etc/resolv.conf en entier, commentaires compris. Qui l'a écrit, et que propose-t-il pour y ajouter quelque chose ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
tail -5 /var/log/nginx/access.log      # rt=5.01, rt=10.01 : une attente fixe, qu'une charge ne produirait pas
grep -n 5s /etc/nginx/sites-enabled/default   # proxy_connect_timeout 5s : tentant, mais il ne règle que la connexion locale de nginx à l'API
journalctl -u app-api -n 5 -o cat      # « réponse en 5008 ms, essai 1 » : aucune reprise, le timeout=5 du code n'est pas en cause
curl -so /dev/null -w 'dns=%{time_namelookup} total=%{time_total}\n' http://stock.interne.lan:8081/   # dns=5.006, total=5.009
curl -so /dev/null -w 'total=%{time_total}\n' http://10.30.0.50:8081/                                # total=0.005 sans le nom
cat /etc/resolv.conf                   # 10.30.0.2 puis 10.30.0.3
dig +short stock.interne.lan @10.30.0.3   # réponse immédiate
dig +short stock.interne.lan @10.30.0.2   # 15 s de silence, puis no servers could be reached
```

Le ping sous la milliseconde ne prouvait rien : il mesure le trajet d'un paquet, et le temps passé à résoudre les noms n'apparaît nulle part dans sa sortie. `time ping -c1 stock.interne.lan` affiche `time=0.04 ms` et dure 10 secondes : 5 pour le nom, 5 pour la résolution inverse de la réponse, que `ping -n` évite.

Le mécanisme : un second `nameserver` n'est pas un serveur de secours intelligent. La bibliothèque C n'a aucune mémoire d'une requête à l'autre. Chaque requête repart du premier serveur, attend `timeout` (5 secondes par défaut), puis passe au suivant. `strace` le montre : à chaque requête, `connect` vers 10.30.0.2, `poll` de 5000 ms, puis `connect` vers 10.30.0.3.

Les durées s'en déduisent. `stock.interne.lan` contient des points : il est tenté tel quel et trouvé du premier coup, 5 secondes. `paiement` est un nom court : la liste `search corp.lan interne.lan` essaie d'abord `paiement.corp.lan`, qui n'existe pas (5 secondes pour l'apprendre), puis `paiement.interne.lan` (5 de plus). `sudo` passe par le même chemin parce que `Defaults fqdn` lui fait résoudre le nom du serveur, absent de /etc/hosts. `sshd` avec `UseDNS yes` enchaîne une dizaine de séries de requêtes par connexion : `tcpdump -ni eth1 udp port 53` montre la résolution inverse de l'adresse du client, puis la vérification directe du nom, répétées à plusieurs étapes de l'ouverture de session, une série toutes les 5 secondes.

Retirer 10.30.0.2 de /etc/resolv.conf à la main règle tout, pendant quelques minutes. Le fichier dit pourquoi :

```bash
head -1 /etc/resolv.conf        # Generated by dhcpcd from eth1.dhcp
dhcpcd -4 --dumplease eth1 | grep -E 'domain_name_servers|lease_time'   # le DHCP annonce le mort en premier, bail de 300 s
journalctl -u dhcpcd -n 4 -o cat
```

dhcpcd réécrit le fichier à chaque renouvellement de bail, avec les valeurs du DHCP, qu'on ne peut pas changer ici. Le fichier généré indique lui-même la sortie : `# /etc/resolv.conf.head can replace this line`. dhcpcd recopie /etc/resolv.conf.head en tête du fichier à chaque renouvellement :

```bash
cat > /etc/resolv.conf.head <<'EOF'
# Le DHCP annonce 10.30.0.2 en premier, mort (ticket #4527). À retirer quand le DHCP sera corrigé.
nameserver 10.30.0.3
options timeout:1 attempts:2
EOF
dhcpcd --rebind eth1
cat /etc/resolv.conf
curl -so /dev/null -w 'total=%{time_total}\n' localhost/api/paiement/1
```

10.30.0.3 passe devant, et le DHCP continue d'annoncer ses deux serveurs derrière : quand 10.30.0.2 reviendra, rien à modifier. `timeout:1` limite le coût de la prochaine panne à une seconde. Rien à redémarrer non plus : depuis glibc 2.26, un processus déjà lancé relit resolv.conf quand le fichier change, et l'API accélère toute seule.

Le choix de ce fichier compte. `static domain_name_servers=` dans /etc/dhcpcd.conf donne le même résultat, mais dhcpcd voit sa configuration changer et expire le bail au `--rebind` : `config file changed, expiring leases`, puis 5 secondes sans adresse ni routes sur eth1. La réparation d'une panne de 5 secondes en aurait créé une vraie, qui coupe tout le trafic de cette interface.

Dernière étape, hors du serveur : ouvrir le ticket à l'équipe réseau pour corriger le DHCP. Tous les serveurs de ce réseau ont le même problème.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Baisser `proxy_connect_timeout` ou le `timeout=5` du code** : aucun effet. Le timeout d'un socket Python ne couvre pas `getaddrinfo`, et nginx parle à l'API en local. Le chiffre 5 est là par hasard, c'est la fausse piste la plus tentante du ticket.
- **Retirer la ligne de /etc/resolv.conf à la main** : tout redevient normal, jusqu'au prochain renouvellement de bail. Le pire des cas : le ticket est fermé, et le problème revient seul.
- **`chattr +i /etc/resolv.conf`** : le fichier ne bouge plus. dhcpcd échoue à chaque renouvellement, avec une ligne dans son journal, et reste `active`. Le jour où l'équipe réseau change vraiment de résolveurs, ce serveur reste sur les anciens et personne ne comprend pourquoi. (`chattr` n'est pas installé dans ce labo : ici, ce fichier appartient à Docker, et le verrouiller bloquerait la suppression du conteneur.)
- **Arrêter dhcpcd** : plus personne ne renouvelle le bail. L'adresse a une durée de vie (`valid_lft` dans `ip addr`) : à l'expiration, le serveur la perd, et l'accès aux services internes avec.
- **Inscrire les services dans /etc/hosts** : l'API accélère, jusqu'à la bascule de reprise où elle continuera d'appeler l'ancienne adresse. Et tout le reste du serveur garde le problème.
- **`UseDNS no` et `Defaults !fqdn`** : `ssh` et `sudo` accélèrent, l'audit perd les noms de machines, l'API reste à 5 secondes. Ces réglages cachent la panne sans la corriger.
- **`options timeout:1` seul** : 5 secondes deviennent 1 seconde. Mieux, et toujours mauvais : chaque appel perd encore une seconde sur un serveur mort.
- **`options rotate`** : répartit les requêtes entre les deux serveurs. Environ une requête sur deux reste à 5 secondes, et le problème devient intermittent, donc plus dur à diagnostiquer.
- **`static domain_name_servers=` dans /etc/dhcpcd.conf** : correct sur le fond, mais l'appliquer coupe eth1 pendant 5 secondes. À garder pour une fenêtre de maintenance.
- **`/etc/resolv.conf.head`** : corrige ce serveur tout de suite, sans coupure et sans toucher au DHCP, résiste aux renouvellements, et s'annule en supprimant un fichier le jour où le DHCP est réparé.

</details>

## En prod

- Une durée qui tombe pile sur 5, 10 ou 30 secondes est presque toujours un timeout. Commencer par chercher ce qui a expiré.
- Superviser chaque résolveur séparément. Un résolveur mort ne déclenche aucune alerte côté application, puisque le suivant finit par répondre.
- Avant de modifier /etc/resolv.conf, regarder qui l'écrit : dhcpcd, NetworkManager, systemd-resolved, cloud-init, netplan. Le fichier est souvent une sortie, pas une configuration.
- Sur un serveur à fort volume, mettre un cache DNS local (`systemd-resolved`, `unbound`) : lui se souvient qu'un serveur est mort, ce que la bibliothèque C ne fait pas.
- Écrire les noms complets dans les configurations d'applications (`paiement.interne.lan.`) : un nom court multiplie les requêtes par la liste de recherche.
