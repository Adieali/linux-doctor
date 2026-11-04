# 06. « Cannot assign requested address » aux heures de pointe

## Le ticket

> **Ticket #4651, priorité haute**
> Aux heures de pointe, les pages catalogue du site renvoient des 502, par rafales. Le journal d'erreurs de nginx dit `Cannot assign requested address`. Hors pointe, rien.
> L'équipe catalogue affirme que son service (10.30.0.60:8080) n'a vu aucune erreur. Ses graphes le confirment : pendant les rafales, elle reçoit moins de requêtes, pas plus.
> Une première analyse a vérifié les adresses IP du serveur et la directive `listen` de nginx : rien d'anormal.
> Pour reproduire une pointe : `systemctl start lab-pointe` (30 secondes de trafic).
> Contraintes : le service de rapports de ce serveur écoute sur le port 45000 et doit pouvoir redémarrer à tout moment (incident #2291). Le catalogue appartient à une autre équipe.
> Les unités `lab-*` simulent le reste du réseau : considère-les comme des machines distantes, n'y touche pas.

## Impact business

Les 502 tombent précisément aux heures où le site vend le plus. Un visiteur qui voit une page d'erreur sur un produit ne revient pas le chercher. La panne ne laisse presque aucune trace : le catalogue ne voit rien, et la supervision moyenne sur cinq minutes lisse des rafales de quelques secondes. Sans diagnostic, la prochaine opération commerciale tombera dessus.

## Les enjeux

- Lire correctement un message d'erreur trompeur : l'adresse qui manque n'est pas celle qu'on croit.
- Comprendre pourquoi un seuil de débit existe, et le calculer.
- Supprimer la cause, pas seulement repousser le seuil.
- Garder la protection de l'incident #2291, en la faisant avec le bon outil.

## Ce qui est vérifié

- le service de rapports tourne sur le port 45000
- aucune connexion sortante ne peut prendre le port 45000
- la configuration de nginx est valide

Si c'est bon, le check envoie une pointe de 4000 pages en quelques secondes, puis vérifie :

- toutes les pages répondent 200
- nginx réutilise ses connexions vers le catalogue

## Indices

<details><summary>Indice 1</summary>

`Cannot assign requested address` est le texte d'`EADDRNOTAVAIL`, renvoyé ici par `connect()`. Une connexion TCP sortante a besoin de deux adresses : laquelle nginx ne trouve-t-il pas ?

</details>

<details><summary>Indice 2</summary>

Pendant et juste après une pointe : `ss -tan state time-wait dst 10.30.0.60 | wc -l`, puis `sysctl net.ipv4.ip_local_port_range`. Combien de temps dure `TIME_WAIT`, et qui s'y retrouve, celui qui ferme en premier ou l'autre ?

</details>

<details><summary>Indice 3</summary>

Combien de connexions nginx ouvre-t-il vers le catalogue pour 100 requêtes ? Cherche `keepalive` dans la documentation du module `ngx_http_upstream_module`, et ce qu'il exige de `proxy_http_version`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
grep -c 'Cannot assign requested address' /var/log/nginx/error.log
grep -m1 'Cannot assign' /var/log/nginx/error.log      # connect() to 10.30.0.60:8080 failed (99: ...) while connecting to upstream
```

Le message vient de `connect()`, quand nginx ouvre une connexion vers le catalogue. Une connexion sortante a besoin d'une adresse source et d'un port source, et le noyau prend ce port dans la plage éphémère. `EADDRNOTAVAIL` veut dire qu'il n'en reste aucun de libre pour cette destination. Les adresses IP du serveur ne sont pas en cause.

```bash
ss -Htan state time-wait dst 10.30.0.60 | wc -l       # près de mille juste après une pointe
sysctl net.ipv4.ip_local_port_range                    # 50000 50999 : mille ports
cat /etc/sysctl.d/60-ports-ephemeres.conf              # l'incident #2291
```

Le côté qui ferme une connexion TCP en premier la garde en `TIME_WAIT` pendant 60 secondes. Sous Linux, cette durée est fixe : `tcp_fin_timeout` règle un autre état, `FIN_WAIT_2`. Tant qu'elle dure, le couple (port local, destination) ne peut pas resservir. Or nginx ouvre une connexion par requête vers le catalogue, et la ferme lui-même dès la réponse lue :

```bash
grep -n proxy_ /etc/nginx/sites-enabled/default       # proxy_pass direct : HTTP/1.0, une connexion par requête
ss -Htan state time-wait dst 10.30.0.60 | head -3      # 10.20.0.10:50xxx vers 10.30.0.60:8080
```

Mille ports, 60 secondes chacun : nginx ne peut pas dépasser 16 requêtes par seconde vers le catalogue. Hors pointe, le site en fait 5. La pointe en demande 60 à 80 : en une dizaine de secondes, plus aucun port n'est libre, et chaque nouvelle requête reçoit 502 jusqu'à ce que des ports sortent de `TIME_WAIT`. Le catalogue ne voit rien, puisque ces connexions ne partent jamais.

La cause est la connexion par requête. Avec un bloc `upstream` et `keepalive`, nginx garde ses connexions vers le catalogue ouvertes et les réutilise. Il faut aussi HTTP/1.1, et vider l'en-tête `Connection`, que nginx remplit par défaut avec `close` :

```bash
cat > /etc/nginx/sites-enabled/default <<'EOF'
# Ticket #4651 : connexions réutilisées vers le catalogue, au lieu d'une connexion par requête.
upstream catalogue {
    server 10.30.0.60:8080;
    keepalive 64;
}

server {
    listen 80 default_server;

    location /catalogue/ {
        proxy_pass http://catalogue;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 2s;
    }
}
EOF
nginx -t && systemctl reload nginx
```

`keepalive 64` est le nombre de connexions inactives que chaque worker garde en réserve. Au-dessous de la concurrence réelle, les connexions en trop sont fermées après usage, et `TIME_WAIT` revient.

La plage de mille ports reste un piège pour le prochain service qui ouvrira beaucoup de connexions. L'incident #2291 avait un vrai besoin (que personne ne prenne le port 45000), mais le noyau a un réglage fait pour ça, `ip_local_reserved_ports` :

```bash
cat > /etc/sysctl.d/60-ports-ephemeres.conf <<'EOF'
# Incident #2291 : app-rapports écoute sur 45000, qu'aucune connexion sortante ne doit prendre.
# Ticket #4651 : plage par défaut, et le port réservé, au lieu d'une plage de mille ports qui le contourne.
net.ipv4.ip_local_port_range = 32768 60999
net.ipv4.ip_local_reserved_ports = 45000
EOF
sysctl -p /etc/sysctl.d/60-ports-ephemeres.conf
```

Pour finir, rejouer la pointe :

```bash
avant=$(grep -c 'Cannot assign' /var/log/nginx/error.log)
systemctl start lab-pointe
echo "nouvelles erreurs : $(( $(grep -c 'Cannot assign' /var/log/nginx/error.log) - avant ))"   # 0
ss -Htan state time-wait dst 10.30.0.60 | wc -l       # presque plus rien
ss -Htn state established dst 10.30.0.60 | wc -l      # les connexions gardées par nginx
```

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Vérifier les adresses IP et `listen`** : le message parle d'adresse, mais il s'agit du port source d'une connexion sortante. Rien à trouver de ce côté.
- **Baisser `tcp_fin_timeout`** : la fausse piste la plus répandue. Ce réglage concerne `FIN_WAIT_2`. La durée de `TIME_WAIT` est fixée à 60 secondes dans le noyau.
- **`tcp_tw_recycle`** : n'existe plus depuis Linux 4.12. Il cassait les clients derrière un NAT.
- **`tcp_tw_reuse=1`** : laisse le noyau reprendre pour une connexion sortante un port en `TIME_WAIT` depuis plus d'une seconde. Le mur recule sans disparaître : la pointe du check échoue encore, et chaque requête paie toujours sa poignée de main TCP.
- **Élargir seulement la plage** : la pointe passe aujourd'hui, avec 28 000 ports au lieu de 1000. Le mur existe toujours, 28 fois plus loin, et le port 45000 se retrouve dans la plage sans protection : l'incident #2291 peut revenir.
- **`keepalive` sans `proxy_http_version 1.1` ni `Connection ""`** : nginx envoie toujours `Connection: close`, le catalogue ferme après chaque réponse, et rien n'est réutilisé.
- **`keepalive` et `ip_local_reserved_ports`** : une connexion sert des milliers de requêtes, la poignée de main TCP disparaît du temps de réponse, et le port 45000 est protégé par le réglage prévu pour ça.

</details>

## En prod

- `Cannot assign requested address` sur un `connect()` veut presque toujours dire : plus de port source libre vers cette destination. Compter `TIME_WAIT` par destination avec `ss`.
- Le débit maximal vers une destination sans réutilisation de connexion se calcule : nombre de ports de la plage divisé par 60. Le comparer au trafic de pointe.
- Tout reverse proxy vers un service interne devrait réutiliser ses connexions : `keepalive` pour nginx, les pools de connexions côté applications.
- Pour réserver un port d'écoute, `ip_local_reserved_ports`, jamais une plage éphémère réduite.
- Superviser les 502 à la seconde près pendant les pointes. Une moyenne sur cinq minutes efface les rafales.
