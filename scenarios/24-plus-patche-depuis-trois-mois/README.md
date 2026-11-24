# 24. Le serveur n'est plus patché depuis trois mois

## Le ticket

> **Ticket #4958, priorité haute**
> Le scanner de vulnérabilités signale srv-prod-01 : libboutique-crypto en 1.3.9, vulnérable à la CVE-2026-31337 (signatures des webhooks de paiement devinables), corrigée en 1.4.3 depuis le 19 août. Le serveur a pourtant les mises à jour automatiques, comme tous les autres, et personne n'a reçu la moindre alerte.
> Le serveur n'a pas accès à Internet : il passe par le miroir interne, `depot.interne`. Les notes de version des paquets internes sont sur `http://depot.interne/notes/`.
> Contraintes : la CVE doit être corrigée aujourd'hui. L'application (`boutique-api`) ne change de version qu'en mise en production, jamais par une mise à jour du système. L'agent de supervision garde ses réglages locaux. À partir de demain, les correctifs de sécurité doivent s'installer seuls, comme prévu.
> Le netns `depot` et l'unité `lab-depot` simulent le miroir : n'y touche pas.

## Impact business

Une signature de webhook devinable permet de faire croire à la boutique qu'un paiement a été accepté. Le serveur l'expose depuis trois mois, sans que personne le sache : les mises à jour automatiques étaient censées s'en charger. L'audit PCI DSS de fin d'année demandera depuis quand le correctif était disponible, et pourquoi il n'était pas installé.

## Les enjeux

- Comprendre pourquoi un serveur « à jour automatiquement » ne l'est pas, et pourquoi rien n'a alerté.
- Corriger la CVE sans mettre à jour l'application au passage.
- Remettre dpkg d'aplomb sans bricoler sa base, et sans perdre une configuration locale.
- Faire en sorte que le prochain correctif s'installe seul.

## Ce qui est vérifié

- dpkg est dans un état propre, et agent-supervision 2.1 est installé, configuré et tourne, avec son réglage local
- libboutique-crypto est en 1.4.3 au moins, et n'est plus bloquée
- boutique-api est toujours en 3.8.0
- les mises à jour automatiques sont planifiées

Si c'est bon, le miroir publie un correctif de sécurité (libboutique-crypto 1.4.4) et une nouvelle version de l'application (boutique-api 3.9.1). Le check lance le passage quotidien des mises à jour automatiques, et vérifie :

- le correctif de sécurité s'est installé seul
- la version de l'application, non

## Indices

<details><summary>Indice 1</summary>

`apt list --upgradable`, puis `apt-get upgrade -s` (simulation : rien ne change). Que dit dpkg de son propre état ? `dpkg --audit`, et `/var/log/apt/history.log`.

</details>

<details><summary>Indice 2</summary>

Un paquet peut être retenu exprès : `apt-mark showhold`. Pourquoi l'a-t-il été, et la raison tient-elle toujours ?

</details>

<details><summary>Indice 3</summary>

Que fait unattended-upgrades chaque matin ? `/var/log/unattended-upgrades/unattended-upgrades.log`. Compare les origines qu'il accepte avec celles du miroir : `apt-cache policy libboutique-crypto`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
apt list --upgradable                                      # boutique-api 3.9.0, libboutique-crypto 1.4.3 (trixie-securite)
apt-get upgrade -s | tail -4                               # 1 not fully installed or removed ; Inst boutique-api ...
dpkg --audit                                               # agent-supervision : à moitié configuré
grep -B1 -A4 '2026-08-20' /var/log/apt/history.log         # apt-get upgrade du 20 août : Error, code (1)
```

Première couche : depuis la journée de correctifs du 20 août, agent-supervision est à moitié configuré. Son script de configuration a échoué, et chaque opération d'apt essaie de le reconfigurer, puis s'arrête. `apt-get upgrade -s` montre aussi qu'un `apt-get upgrade` passerait boutique-api en 3.9.0 : interdit ici, l'application change de version en mise en production.

```bash
dpkg --configure -a
# agent-supervision : option inconnue dans /etc/agent-supervision.conf : intervalle (renommée periode en 2.1 ...)
cat /usr/share/doc/agent-supervision/NEWS
grep -v '^#' /etc/agent-supervision.conf                   # serveur = 10.90.0.20, intervalle = 30 : réglés à la main
```

La 2.1 a renommé l'option `intervalle` en `periode`. Le fichier, modifié à la main, a été gardé tel quel à la mise à jour (`--force-confold`), avec l'ancienne option, et la 2.1 refuse de démarrer avec une option qu'elle ne connaît pas. La correction va dans la configuration : on renomme l'option, on garde les valeurs locales, et dpkg termine ce qu'il avait commencé.

```bash
sed -i 's/^intervalle = 30$/periode = 30/' /etc/agent-supervision.conf
dpkg --configure -a                                        # Setting up agent-supervision (2.1) ...
dpkg --audit                                               # rien
systemctl is-active agent-supervision                      # active
```

Deuxième couche : la bibliothèque vulnérable ne bouge toujours pas.

```bash
apt-mark showhold                                          # libboutique-crypto
grep crypto /etc/motd                                      # bloquée en 1.3.9 : incident #4411, mars, la 1.4.0 cassait les webhooks
curl -s http://depot.interne/notes/libboutique-crypto.txt | sed -n '3,6p'
# 1.4.3 : CVE-2026-31337, et corrige aussi la régression de la 1.4.0 (incident #4411)
```

Le blocage de mars avait une raison, et la 1.4.3 la règle. On le lève, et on installe la seule bibliothèque, sans rien mettre à jour d'autre.

```bash
apt-mark unhold libboutique-crypto
apt-get install -y --only-upgrade libboutique-crypto       # 1.3.9 -> 1.4.3, boutique-api ne bouge pas
dpkg-query -W libboutique-crypto boutique-api              # 1.4.3 et 3.8.0
```

Troisième couche : pourquoi rien de tout ça ne s'est fait seul.

```bash
tail -2 /var/log/unattended-upgrades/unattended-upgrades.log   # No packages found that can be upgraded unattended
grep 'Allowed origins' /var/log/unattended-upgrades/unattended-upgrades.log | tail -1   # origin=Debian seulement
apt-cache policy libboutique-crypto | grep -m1 'o='        # o=Boutique,a=trixie-securite,n=trixie-securite,l=Boutique-Securite
```

unattended-upgrades n'installe que ce qui vient des origines qu'il accepte. Sa configuration est celle de Debian : `origin=Debian`. Le miroir interne publie tout sous l'origine `Boutique`, Debian compris : depuis l'installation du serveur, unattended-upgrades tourne chaque matin, ne trouve rien qui corresponde, l'écrit dans son journal, et ne prévient personne. Le paquet à moitié configuré n'y était pour rien : même avec dpkg en ordre, rien ne se serait installé.

On ajoute l'origine du miroir, limitée à sa suite de sécurité. Un fichier à part, plutôt que la configuration du paquet, que sa prochaine version voudra remplacer :

```bash
cat > /etc/apt/apt.conf.d/51unattended-upgrades-boutique <<'EOF'
// Ticket #4958 : le miroir interne (depot.interne) publie tout sous l'origine « Boutique ».
// Seule sa suite de sécurité s'installe seule. Les versions de l'application passent par les mises en production.
Unattended-Upgrade::Origins-Pattern {
        "origin=Boutique,label=Boutique-Securite";
};
EOF
unattended-upgrade --dry-run -v 2>&1 | grep 'Allowed origins'    # ..., origin=Boutique,label=Boutique-Securite
```

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **`apt-get upgrade`** : la CVE est corrigée, et boutique-api passe en 3.9.0 hors mise en production. Et il bute de toute façon sur le paquet à moitié configuré.
- **Modifier `/var/lib/dpkg/status`, ou vider le postinst dans `/var/lib/dpkg/info`** : dpkg se tait, l'agent ne démarre toujours pas (sa configuration reste invalide), et la base de dpkg ne dit plus la vérité.
- **Réinstaller l'agent avec la configuration du paquet (`--force-confnew`)** : il démarre, et envoie ses données à `supervision.exemple` au lieu du vrai serveur de supervision.
- **`apt-mark unhold` sans lire pourquoi le paquet était bloqué** : ça marche ici parce que la 1.4.3 corrige la régression de mars. Un blocage se lève quand sa raison a disparu, pas avant.
- **`origin=Boutique` sans préciser la suite** : les correctifs s'installent seuls, et les nouvelles versions de l'application aussi.
- **Retirer le blocage, réparer dpkg, mais laisser unattended-upgrades tel quel** : la CVE est corrigée aujourd'hui, et la prochaine attendra le prochain scanner.
- **Réparer dpkg par la configuration, lever le blocage après en avoir vérifié la raison, mettre à jour la seule bibliothèque, et ouvrir unattended-upgrades à la seule suite de sécurité du miroir** : chaque couche corrigée à sa place, et l'application ne bouge pas.

</details>

## En prod

- `dpkg --audit` doit être vide sur tous les serveurs. Un paquet à moitié configuré bloque toutes les mises à jour suivantes, en silence si personne ne lit la sortie d'apt.
- Une configuration modifiée localement est gardée aux mises à jour. Lire les `NEWS` et le changelog avant une mise à jour majeure d'un paquet dont on a touché la configuration.
- Un `apt-mark hold` sans date ni raison devient permanent. Tenir la liste des paquets bloqués avec leur ticket, et la revoir à chaque nouvelle version.
- unattended-upgrades filtre par origine, telle que la donne le fichier `Release` du dépôt (`apt-cache policy`). Un miroir interne qui réécrit l'origine rend la configuration par défaut inutile.
- « Pas d'erreur » ne veut pas dire « à jour ». Superviser l'âge des correctifs installés (ou le nombre de paquets de sécurité en attente), et configurer `Unattended-Upgrade::Mail` pour être prévenu d'un échec.
- `apt-get install --only-upgrade <paquet>` met à jour un paquet précis, sans rien entraîner d'autre que ses dépendances.
