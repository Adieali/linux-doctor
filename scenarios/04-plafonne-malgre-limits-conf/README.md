# 04. limits.conf a été augmenté, l'appli plafonne toujours

## Le ticket

> **Ticket #4612, priorité haute**
> Hier à 18 h, l'API commandes ne répondait plus, avec `Too many open files` dans son journal. L'astreinte a passé `nofile` à 65535 dans /etc/security/limits.conf, la valeur validée par l'architecture pour ce service, a vérifié avec `ulimit -n` dans une session SSH, puis a redémarré l'API. Tout est revenu.
> Ce matin, ça recommence. À la pointe de 10 h, des 502 par vagues, avec `can't start new thread` dans le journal. Maintenant, toutes les requêtes reçoivent une 502, même les fiches articles les plus simples.
> À la pointe de midi, le répartiteur de charge compte jusqu'à 200 requêtes en cours vers ce serveur.
> Contraintes : /etc/systemd/system/app-api.service.d/10-durcissement.conf vient de l'audit sécurité, et Ansible le réécrit à chaque passage. L'équipe dev livre vendredi. D'ici là, elle accepte un correctif minimal de son code, preuve à l'appui.
> Les unités `lab-*` simulent le reste du réseau : considère-les comme des machines distantes, n'y touche pas.

## Impact business

Sans l'API, aucune fiche article n'affiche son stock et plus aucune commande ne passe. Le redémarrage d'hier soir a acheté une nuit, et l'équipe s'apprête à recommencer : chaque redémarrage coupe les commandes en cours, et la panne revient d'elle-même quelques heures plus tard. La pointe de midi, deux fois plus chargée que celle de 10 h, tombera sur un service qui n'a déjà pas tenu la première.

## Les enjeux

- Trouver la limite que le processus a vraiment, et pas celle qu'affiche un shell.
- Comprendre pourquoi la panne revient après chaque redémarrage. Une limite plus haute la retarde, elle ne l'empêche pas.
- Respecter le fichier de l'audit : Ansible le réécrit, il faut le compléter sans le modifier.
- Toucher au code de l'équipe dev le moins possible, et seulement avec une preuve.

## Ce qui est vérifié

Le check repasse d'abord Ansible sur le durcissement (le fichier revient à son contenu d'origine), redémarre l'API, puis vérifie :

- l'API tourne, avec le durcissement de l'audit
- elle a droit à 65535 fichiers ouverts, la valeur validée
- son nombre de tâches reste plafonné
- 200 requêtes simultanées passent toutes, comme à la pointe de midi
- 300 articles inconnus ne laissent aucun descripteur ouvert

## Indices

<details><summary>Indice 1</summary>

Compare trois chiffres : `ulimit -n` dans ton shell, `sudo -u api sh -c 'ulimit -n'`, et la ligne `Max open files` de /proc/<pid>/limits du service. Puis `grep -l pam_limits /etc/pam.d/*` : qui lit limits.conf, et à quel moment ?

</details>

<details><summary>Indice 2</summary>

Après un redémarrage, compte les descripteurs du service toutes les minutes : `ls /proc/<pid>/fd | wc -l`. Puis `ss -tnp` : vers où vont ces connexions, et dans quel état sont-elles ? Lequel des deux côtés doit encore agir ?

</details>

<details><summary>Indice 3</summary>

`systemctl status app-api` affiche une limite à côté de `Tasks`. `systemctl cat app-api` montre d'où elle vient. Ce fichier ne t'appartient pas : comment systemd combine-t-il plusieurs fichiers du dossier `app-api.service.d` ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
curl -s -o /dev/null -w '%{http_code} en %{time_total} s\n' localhost/api/articles/42   # 502, tout de suite
journalctl -u app-api -o cat -n 3     # [Errno 24] Too many open files, à chaque requête
pid=$(systemctl show -p MainPID --value app-api)
grep 'open files' /proc/"$pid"/limits # limite molle : 1024
ls /proc/"$pid"/fd | wc -l            # 1023
```

Il reste un seul descripteur libre. La connexion entrante le prend, l'appel au stock n'en trouve plus (`EMFILE`, l'erreur 24), et la requête repart en 502. La limite est 1024, pas 65535 :

```bash
grep -l pam_limits /etc/pam.d/*          # sshd, su, sudo... : des ouvertures de session
sudo -u api sh -c 'ulimit -n'            # 65535 : sudo ouvre une session PAM, limits.conf s'applique
ulimit -n                                # ce que Docker donne à docker exec, sans rapport avec le service
systemctl show -p DefaultLimitNOFILESoft # 1024 : ce que systemd donne à un service sans LimitNOFILE
```

/etc/security/limits.conf n'est lu que par `pam_limits`, à l'ouverture d'une session : SSH, `su`, `sudo`, la console. systemd ne passe pas par PAM pour lancer un service. Il applique `LimitNOFILE` de l'unité, et à défaut sa valeur par défaut, 1024 en limite molle. L'astreinte a vérifié au seul endroit où son changement avait un effet.

Ce n'est pas tout : 65535 n'aurait fait que retarder la panne. L'API redémarrée hier soir a rempli ses descripteurs en une nuit. À quoi servent-ils ?

```bash
ss -Htnp state close-wait | head -3                    # vers 10.30.0.50:8081, le stock, côté app-api
ss -Htn state close-wait dst 10.30.0.50 | wc -l        # un millier
journalctl -u app-api -o cat | grep -c 'réponse 404'   # le même chiffre : un par article inconnu
```

`CLOSE_WAIT` veut dire que l'autre côté a fermé sa moitié de la connexion (le stock coupe une connexion inactive au bout d'une seconde) et que le noyau attend que l'application appelle `close()`. Aucun minuteur du noyau ne libère cet état : tant que le processus vit, le descripteur reste pris. Le journal donne la corrélation, le code donne la cause :

```bash
grep -n -A20 '^def stock' /usr/local/bin/app-api
```

Sur une réponse autre que 200, `stock()` sort sans appeler `fermer(conn)`. La connexion reste dans l'ensemble `ouvertes`, prévu pour tout fermer proprement à l'arrêt : c'est ce registre qui la garde en vie. Sans lui, Python l'aurait fermée en libérant l'objet. Le correctif tient en une ligne, sur le seul chemin qui fuit :

```bash
cp /usr/local/bin/app-api /root/app-api.avant-4612
sed -i 's/^        return rep.status, corps$/        fermer(conn)\n&/' /usr/local/bin/app-api
diff -u /root/app-api.avant-4612 /usr/local/bin/app-api
```

Ce diff part à l'équipe dev avec la preuve : le décompte de `ss` et celui du journal. La forme durable est un `try/finally` autour de l'appel, qui ferme la connexion quel que soit le chemin de sortie. À eux de l'écrire pour vendredi.

Reste la pointe. L'API lance un thread par requête, et le durcissement la plafonne :

```bash
systemctl status app-api --no-pager | grep Tasks                       # limit: 64
journalctl -u app-api -o cat | grep -m1 "can't start new thread"
systemctl cat app-api | grep -E '^# /|TasksMax'                        # TasksMax=64, dans 10-durcissement.conf
```

`TasksMax` compte les threads comme des tâches, thread principal compris. Au-delà de 63 requêtes en cours, la création du thread échoue, le serveur ferme la connexion sans répondre, et nginx renvoie 502. Le fichier de l'audit appartient à Ansible : le modifier tiendrait jusqu'au prochain passage. systemd lit les fichiers du dossier `.d` par ordre alphabétique, et pour un réglage à valeur unique comme `TasksMax`, le dernier lu l'emporte. Un fichier `20-` complète donc le durcissement sans y toucher, et tout le reste du durcissement continue de s'appliquer :

```bash
cat > /etc/systemd/system/app-api.service.d/20-capacite.conf <<'EOF'
# Ticket #4612. Lu après 10-durcissement.conf (Ansible) : ces deux valeurs l'emportent, le reste s'applique.
# Pointe de midi : 200 requêtes en cours, un thread chacune. 512 garde un plafond avec de la marge.
[Service]
LimitNOFILE=65535
TasksMax=512
EOF
systemctl daemon-reload
systemctl restart app-api
systemctl show app-api -p LimitNOFILESoft -p TasksMax -p NoNewPrivileges
```

Le plafond reste fini. 200 requêtes en cours font 201 tâches ; à 512, un emballement de threads s'arrête encore bien avant de saturer la machine, ce que l'audit voulait. Un seul redémarrage, après le correctif : il libère les connexions bloquées, et une limite ne s'applique qu'au lancement du processus.

```bash
sleep 1
pid=$(systemctl show -p MainPID --value app-api)
grep 'open files' /proc/"$pid"/limits                  # 65535
for n in $(seq 990001 990040); do curl -s -o /dev/null localhost/api/articles/$n; done
ls /proc/"$pid"/fd | wc -l                             # une poignée, et le chiffre ne monte plus
```

Dernières étapes, hors du serveur. Prévenir l'équipe sécurité que `20-capacite.conf` relève `TasksMax`, avec le calcul, pour que le rôle Ansible porte la valeur : sinon le prochain audit la signalera comme une dérive. Et retirer les lignes ajoutées hier à limits.conf, qui n'ont rien changé pour l'API : le prochain qui les lira croira qu'elles servent.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **limits.conf, ou un fichier dans /etc/security/limits.d** : lus par `pam_limits`, donc seulement par les sessions. Aucun effet sur un service systemd.
- **`DefaultLimitNOFILE` dans /etc/systemd/system.conf** : marche après un `systemctl daemon-reexec`, mais change la limite de tous les services de la machine, alors que la décision ne portait que sur l'API.
- **`prlimit --pid <pid> --nofile=65535`** : débloque le processus tout de suite, sans redémarrage. Utile pour gagner une heure, mais perdu au prochain redémarrage, et la fuite continue.
- **Monter la limite sans corriger la fuite** : à 65535 au lieu de 1024, la panne revient environ 64 fois plus tard. Le ticket est fermé, et l'incident revient seul, la nuit, avec un autre astreint.
- **Redémarrer l'API chaque nuit par cron** : cache la fuite, coupe les commandes en cours, et ne tient plus le jour où le trafic double.
- **Les sysctl TCP (`tcp_fin_timeout`, keepalive)** : `tcp_fin_timeout` règle `FIN_WAIT_2`, du côté qui a fermé en premier. `CLOSE_WAIT` attend l'application, aucun réglage du noyau ne le libère.
- **`fs.file-max`** : la limite de toute la machine, loin d'être atteinte (`cat /proc/sys/fs/file-nr`). La panne est une limite par processus.
- **Modifier 10-durcissement.conf** : marche jusqu'au prochain passage d'Ansible, qui remet 64. La pointe suivante retombe sur le même mur.
- **`TasksMax=infinity`** : la pointe passe, et la protection voulue par l'audit disparaît. Un emballement de threads peut de nouveau épuiser la machine.
- **Réécrire `stock()` avec un `try/finally`** : la bonne forme, mais c'est un changement de code plus large, en urgence, sur le code d'une autre équipe. La ligne ajoutée corrige le seul chemin qui fuit, et le `try/finally` arrive vendredi, relu par ses auteurs.
- **Un fichier `20-capacite.conf` et une ligne de correctif** : la valeur validée s'applique enfin, la pointe passe, le durcissement reste en place, et la fuite est corrigée à la source.

</details>

## En prod

- Après tout changement de limite, lire /proc/<pid>/limits du processus concerné. `ulimit -n` dans un shell décrit ce shell, rien d'autre.
- Superviser les descripteurs ouverts de chaque service contre sa limite, et alerter vers 80 %. Une courbe qui monte sans redescendre est une fuite, quelle que soit la limite.
- Un nombre de `CLOSE_WAIT` qui ne redescend pas est toujours un bug de l'application. `ss -tan state close-wait` le montre, et la destination désigne le code en cause.
- Mettre les limites d'un service dans son unité, déployée avec lui (le rôle Ansible de l'application), et pas dans limits.conf.
- Un thread par requête lie la capacité du service à `TasksMax`. Un pool de taille fixe, côté application, rend cette limite prévisible.
