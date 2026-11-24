# 20. Le transporteur répond à curl, pas au service

## Le ticket

> **Ticket #4866, priorité haute**
> Depuis la mise en place du pare-feu de sortie (politique de sécurité #4860 : vers Internet, tout passe par le proxy d'entreprise), plus aucune expédition ne part. Le service des expéditions répond « transporteur injoignable ». Pourtant, depuis le serveur, `curl https://api.transporteur.example/v1/sante` répond tout de suite, et l'équipe sécurité a bien configuré le proxy sur la machine.
> Pour tester : `curl -X POST http://localhost:8000/expedier`.
> Contraintes : la sortie directe vers Internet reste fermée. Le proxy journalise et filtre tout ce qu'il voit : les échanges internes n'ont rien à y faire, il les refuse. La configuration doit tenir au redémarrage et aux redéploiements du service.
> Les netns `routeur`, `proxy`, `stock` et `internet`, et les unités `lab-*`, simulent le reste : n'y touche pas.

## Impact business

Les commandes s'accumulent sans étiquette de transport : rien ne part chez les clients, et chaque heure de retard décale les livraisons promises. Comme `curl` passe depuis le serveur, l'équipe système pense à un problème chez le transporteur, et lui ouvre un ticket. Pendant ce temps, l'entrepôt prépare des colis qui ne partiront pas.

## Les enjeux

- Comprendre pourquoi la même requête passe depuis un shell et pas depuis le service.
- Donner au service l'accès au proxy, pour ce qui doit sortir, et seulement pour ça.
- Ne pas faire passer les échanges internes par le proxy.
- Une configuration qui tient au redémarrage, sans dépendre d'un shell de connexion.

## Ce qui est vérifié

Le check rejoue d'abord un démarrage : environnement de systemd et drop-ins de `/run` effacés, service relancé. Puis il vérifie :

- la sortie directe vers Internet reste fermée
- une expédition passe de bout en bout
- le transporteur est joint par le proxy
- les appels internes et locaux ne passent pas par le proxy

## Indices

<details><summary>Indice 1</summary>

`curl` passe depuis ton shell. Qu'est-ce que ton shell a que le service n'a pas ? `env | grep -i proxy`, puis l'environnement du processus du service : `/proc/<pid>/environ`.

</details>

<details><summary>Indice 2</summary>

Qui lit `/etc/profile.d` ? Et d'où un service systemd tient-il son environnement ? `systemctl show expeditions -p Environment`.

</details>

<details><summary>Indice 3</summary>

Une fois le proxy donné au service, regarde ce que le proxy voit passer : `/var/log/labo-proxy.log`. Tout ce qu'il voit doit-il passer par lui ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
curl -s -X POST http://localhost:8000/expedier; echo                 # {"erreur": "transporteur injoignable (...) : <urlopen error timed out>"}
bash -lc 'curl -s https://api.transporteur.example/v1/sante'; echo   # {"api": "transporteur", "etat": "ok"}
bash -lc 'env | grep -i proxy'                                       # http_proxy, https_proxy, no_proxy
tr '\0' '\n' < /proc/"$(systemctl show -p MainPID --value expeditions)"/environ | grep -i proxy   # rien
```

Un shell de connexion lit `/etc/profile`, qui lit `/etc/profile.d/proxy.sh` : il a les variables du proxy, et `curl` passe par lui. Un service systemd ne lit ni l'un ni l'autre : son environnement vient de son unité. Sans proxy, il appelle le transporteur en direct, et le routeur jette ses paquets : un timeout, pas un refus.

Premier réflexe, la variable qu'on trouve partout :

```bash
mkdir -p /etc/systemd/system/expeditions.service.d
printf '[Service]\nEnvironment=HTTP_PROXY=http://proxy.interne:3128\n' > /etc/systemd/system/expeditions.service.d/proxy.conf
systemctl daemon-reload && systemctl restart expeditions && sleep 1
curl -s -X POST http://localhost:8000/expedier; echo                 # toujours transporteur injoignable
```

L'API du transporteur est en `https`. Pour une URL `https`, les outils lisent `https_proxy`, pas `http_proxy` : le service part toujours en direct. Avec les deux :

```bash
printf '[Service]\nEnvironment=http_proxy=http://proxy.interne:3128 https_proxy=http://proxy.interne:3128\n' > /etc/systemd/system/expeditions.service.d/proxy.conf
systemctl daemon-reload && systemctl restart expeditions && sleep 1
curl -s -X POST http://localhost:8000/expedier; echo                 # {"erreur": "stock injoignable (...) : HTTP Error 403: ..."}
tail -n 3 /var/log/labo-proxy.log                                    # GET http://stock.interne:8080/stock REFUSÉ : destination interne
```

Le transporteur passe, mais maintenant tout part vers le proxy : le stock, service interne, et les tarifs, sur `localhost`. Le proxy refuse les destinations internes, et il a raison. `no_proxy` liste ce qui ne doit pas passer par lui. Le shell l'avait déjà, le service non.

Une seule source pour les shells et pour le service, plutôt que deux copies qui divergeront. Les outils ne lisent pas tous les mêmes variables (curl ignore `HTTP_PROXY` en majuscules, d'autres ne lisent que les majuscules) : le fichier donne les deux.

```bash
cat > /etc/proxy.env <<'EOF'
# Proxy d'entreprise (politique de sécurité #4860) : toute sortie vers Internet passe par lui.
# Ce qui est interne ou local n'y passe pas : il le refuse, et n'a pas à le voir.
http_proxy=http://proxy.interne:3128
https_proxy=http://proxy.interne:3128
no_proxy=localhost,127.0.0.1,.interne
HTTP_PROXY=http://proxy.interne:3128
HTTPS_PROXY=http://proxy.interne:3128
NO_PROXY=localhost,127.0.0.1,.interne
EOF
cat > /etc/systemd/system/expeditions.service.d/proxy.conf <<'EOF'
[Service]
# Ticket #4866 : le proxy d'entreprise, comme pour les shells.
EnvironmentFile=/etc/proxy.env
EOF
cat > /etc/profile.d/proxy.sh <<'EOF'
# Proxy d'entreprise : variables lues dans /etc/proxy.env, la même source que les services.
set -a
. /etc/proxy.env
set +a
EOF
systemctl daemon-reload && systemctl restart expeditions && sleep 1
curl -s -X POST http://localhost:8000/expedier; echo                 # {"expedition": "créée", "etiquette": "TR-2026-118734"}
tail -n 1 /var/log/labo-proxy.log                                    # CONNECT api.transporteur.example:443, et rien d'interne
```

Le drop-in dans `/etc/systemd/system` survit au redémarrage et au redéploiement du service : le paquet ou l'outil de déploiement réécrit l'unité, pas le drop-in.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Ouvrir la sortie directe vers Internet pour ce serveur** : contraire à la politique #4860, et le transporteur ne serait plus le seul à sortir.
- **`HTTP_PROXY` seul** : pour une URL `https`, il ne sert à rien.
- **`http_proxy` et `https_proxy` sans `no_proxy`** : le transporteur passe, le stock et les tarifs partent vers le proxy, qui les refuse.
- **Les variables dans `/etc/environment`** : lues par les sessions (PAM), pas par les services systemd.
- **`systemctl set-environment`, ou `systemctl edit --runtime`** : en mémoire ou dans `/run`, perdu au prochain redémarrage.
- **`DefaultEnvironment=` dans `/etc/systemd/system.conf`** : tous les services de la machine reçoivent le proxy, y compris ceux qui n'ont rien à faire sur Internet.
- **Modifier l'unité livrée par le paquet** : le prochain redéploiement l'écrase.
- **Un fichier `/etc/proxy.env`, lu par le drop-in du service et par `/etc/profile.d`** : une seule source, les trois variables, en minuscules et en majuscules, et rien qui dépende d'un shell de connexion.

</details>

## En prod

- Un service systemd n'hérite pas de l'environnement d'un shell : ni `/etc/profile`, ni `/etc/profile.d`, ni `/etc/environment`. Son environnement se lit dans `/proc/<pid>/environ`.
- `http_proxy` sert aux URL `http`, `https_proxy` aux URL `https`. Une variable manquante, et l'outil part en direct, souvent jusqu'au timeout.
- `no_proxy` est indispensable dès qu'un proxy est configuré : `localhost`, `127.0.0.1`, les domaines internes. Sinon, tout l'interne part vers le proxy.
- Les outils ne lisent pas tous les mêmes variables : curl ignore `HTTP_PROXY` en majuscules, d'autres programmes ne lisent que les majuscules, et certains (comme `urllib` en Python) ignorent les plages d'adresses dans `no_proxy`. Donner les deux casses, et préférer des noms de domaine aux adresses.
- Pour un service : un drop-in dans `/etc/systemd/system/<service>.d/`, avec `Environment=` ou `EnvironmentFile=`. Jamais l'unité livrée par le paquet.
