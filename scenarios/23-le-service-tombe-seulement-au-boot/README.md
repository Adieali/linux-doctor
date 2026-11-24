# 23. Le service tombe seulement au boot

## Le ticket

> **Ticket #4903, priorité critique**
> Cette nuit, srv-prod-01 a redémarré pour les correctifs du mois, et la boutique est coupée depuis : nginx est en échec. Relancé à la main, il démarre sans erreur, et la boutique revient. La semaine dernière, même chose sur srv-prod-02 après son redémarrage : l'astreinte l'a relancé, et le ticket a été fermé.
> La boutique tourne sur deux nœuds keepalived : srv-prod-01 (ce serveur) en maître, srv-prod-02 en secours, VIP 10.100.0.100. La bascule a été testée le mois dernier, elle marche.
> Pour tester : `client curl http://10.100.0.100/` (un client), `client curl http://10.100.0.21:8080/etat` (la page d'état que lit la supervision). Pour regarder l'autre nœud : `srv-prod-02 <commande>`.
> Contraintes : la boutique ne répond que sur la VIP, jamais sur l'adresse propre des serveurs (audit PCI DSS #4702). La supervision lit la page d'état de nginx sur chaque nœud, maître ou secours : un nœud sans nginx ne pourrait pas reprendre la boutique. Après une bascule, la boutique doit revenir en moins de 5 secondes. Tout doit tenir au redémarrage, sans intervention.
> Les netns `lan`, `client` et `srv-prod-02`, et les unités `lab-*`, simulent le reste : n'y touche pas.

## Impact business

La boutique est coupée depuis le redémarrage de cette nuit, et le restera à chaque redémarrage tant que quelqu'un ne relance pas nginx à la main. Le cluster existe pour que la boutique survive à la perte d'un nœud : aujourd'hui, elle ne survit même pas à un redémarrage prévu. Et le même défaut attend sur srv-prod-02.

## Les enjeux

- Comprendre pourquoi un service démarre à la main et pas au démarrage.
- Corriger la cause, pas seulement relancer : le ticket de la semaine dernière a été fermé sans ça.
- Penser aux deux nœuds : celui qui a la VIP, et celui qui ne l'a pas.
- Ne pas ouvrir la boutique sur l'adresse propre du serveur.

## Ce qui est vérifié

- nginx tourne, un client charge la boutique par la VIP
- la page d'état répond sur l'adresse du nœud, et la boutique n'y répond pas

Si c'est bon, le check redémarre srv-prod-01, et vérifie :

- srv-prod-01 reprend la VIP, nginx tourne, la boutique et la page d'état répondent

Puis il donne la priorité à srv-prod-02 et redémarre srv-prod-01, qui revient en nœud de secours. Il vérifie :

- nginx tourne sur srv-prod-01, sans la VIP, et sa page d'état répond
- srv-prod-02 tombe : srv-prod-01 sert la boutique moins de 5 s plus tard

## Indices

<details><summary>Indice 1</summary>

`systemctl status nginx`, puis `journalctl -u nginx -b`. Quelle erreur au démarrage, et pourquoi systemd a-t-il arrêté d'essayer ?

</details>

<details><summary>Indice 2</summary>

À quel moment la VIP arrive-t-elle sur le serveur, par rapport au démarrage de nginx ? `journalctl -o short-precise -u keepalived -u nginx`.

</details>

<details><summary>Indice 3</summary>

Sur le nœud de secours, la VIP n'arrive jamais. Que doit faire nginx là-bas ? Le noyau peut-il laisser un programme écouter sur une adresse qu'il n'a pas encore ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
systemctl --failed --no-pager                              # nginx.service failed
journalctl -u nginx -b --no-pager | grep -E 'bind|too quickly' | tail -2
# nginx: [emerg] bind() to 10.100.0.100:80 failed (99: Cannot assign requested address)
# nginx.service: Start request repeated too quickly.
ip -br addr show eth1                                      # 10.100.0.21/24 10.100.0.100/24 : la VIP est là
```

nginx a voulu écouter sur la VIP, et le noyau a refusé : cette adresse n'était pas encore sur le serveur. La VIP arrive maintenant. Relancé à la main, nginx démarrerait : c'est ce que l'astreinte a fait la semaine dernière sur srv-prod-02.

```bash
journalctl -b --no-pager -o short-precise -u keepalived -u nginx | grep -E 'MASTER|too quickly' | tail -2
# 13:19:32.670 nginx.service: Start request repeated too quickly.
# 13:19:34.948 (boutique) Entering MASTER STATE
systemctl cat nginx | grep -E '^(After|Wants|Restart)'
# After=network-online.target remote-fs.target nss-lookup.target
# Wants=network-online.target
# Restart=on-failure
```

Les deux nœuds démarrent en secours. keepalived ne prend la VIP qu'après l'élection : trois annonces manquées, un peu plus de 3 secondes. nginx, lui, démarre dès que le réseau est configuré. Le `Restart=on-failure` de l'incident #4512 le relance toutes les 100 ms (la valeur par défaut de `RestartSec`) : cinq échecs en une demi-seconde, et systemd abandonne (`StartLimitBurst=5` sur 10 s). La VIP arrive deux secondes trop tard.

Attendre ne règle rien. nginx attend déjà `network-online.target` : le réseau est « en ligne » quand eth1 a son adresse, et la VIP n'en fait pas partie. Attendre `keepalived.service` non plus : keepalived est démarré dès que son processus tourne, en secours, bien avant l'élection. Et sur srv-prod-02, ou sur ce serveur le jour où il démarre en secours, la VIP ne vient jamais : nginx ne démarrerait pas, la page d'état tomberait, et à la bascule personne n'écouterait sur la VIP.

nginx doit pouvoir écouter sur la VIP sans l'avoir. C'est ce que permet `net.ipv4.ip_nonlocal_bind` : le noyau accepte qu'un programme s'attache à une adresse absente, et lui envoie le trafic dès qu'elle arrive.

```bash
cat > /etc/sysctl.d/60-vip-keepalived.conf <<'EOF'
# Ticket #4903 : nginx écoute sur la VIP keepalived (10.100.0.100), qui n'est que sur le nœud maître.
# Il doit pouvoir s'y attacher sans l'avoir : au démarrage, avant l'élection, et sur le nœud de secours.
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl -p /etc/sysctl.d/60-vip-keepalived.conf
systemctl reset-failed nginx                               # remet à zéro le compteur de démarrages
```

Sans `reset-failed`, systemd refuserait encore de démarrer nginx pendant les 10 s de la fenêtre. Vérification sans redémarrer : srv-prod-01 passe en secours le temps de relancer nginx.

```bash
systemctl stop keepalived                                  # srv-prod-02 prend la VIP
systemctl restart nginx && systemctl is-active nginx       # active, sans la VIP
client curl -s http://10.100.0.21:8080/etat | head -1      # Active connections: 1
systemctl start keepalived && sleep 5                      # srv-prod-01 reprend la VIP (priorité 150)
client curl -s http://10.100.0.100/                        # Boutique, servie par srv-prod-01
```

Le même fichier va sur srv-prod-02, qui a le même défaut.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Relancer nginx à la main** : la boutique revient jusqu'au prochain redémarrage. C'est la clôture du ticket de la semaine dernière.
- **`After=network-online.target`** : nginx l'a déjà. La VIP arrive par keepalived, après l'élection, pas avec la configuration du réseau.
- **`After=keepalived.service`** : keepalived est démarré avant d'être maître. L'ordre ne change rien.
- **Un `RestartSec=` plus long** : passe au démarrage du maître, si l'élection tient dans le délai. Sur le nœud de secours, nginx échoue jusqu'à la limite, ou tourne en boucle si on la retire : la page d'état tombe, et à la bascule, rien n'écoute sur la VIP.
- **Démarrer nginx depuis un script `notify_master` de keepalived** : nginx ne tourne que sur le maître, la supervision perd le nœud de secours, et la bascule attend le démarrage de nginx.
- **`listen 80` sur toutes les adresses** : nginx démarre partout, et la boutique répond sur l'adresse propre des serveurs. Refusé par l'audit.
- **`net.ipv4.ip_nonlocal_bind = 1`** : nginx démarre sur les deux nœuds, au démarrage comme en secours, et sert la VIP dès qu'elle arrive. Le réglage vaut pour tout le serveur : un programme mal configuré pourra aussi écouter sur une adresse qu'il n'aura jamais, sans erreur. C'est le prix, connu, de cette solution, et la raison de la documenter.

</details>

## En prod

- Un service qui démarre à la main et pas au démarrage dépend de quelque chose qui n'est pas encore là au démarrage : une adresse, un montage, un autre service. `journalctl -b -o short-precise` sur toutes les unités concernées montre l'ordre réel.
- `network-online.target` veut dire « les interfaces configurées ont leur adresse ». Ni VIP, ni service distant joignable, ni DNS prêt.
- `Restart=on-failure` sans `RestartSec=` relance toutes les 100 ms : cinq échecs en une demi-seconde, et l'unité reste en échec (`start-limit-hit`). Toujours lui donner un délai réaliste.
- Pour un service qui écoute sur une VIP (nginx, HAProxy, PostgreSQL) : `net.ipv4.ip_nonlocal_bind = 1` (et `net.ipv6.ip_nonlocal_bind` en IPv6) sur tous les nœuds du cluster. HAProxy sait aussi le faire ligne par ligne, avec l'option `transparent` de `bind`.
- Un incident « réglé » en relançant le service doit garder un ticket ouvert : la même cause revient au redémarrage suivant, sur l'autre nœud.
