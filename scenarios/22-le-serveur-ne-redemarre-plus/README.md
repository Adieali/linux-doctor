# 22. Le serveur ne redémarre plus

## Le ticket

> **Ticket #4890, priorité critique**
> Cette nuit à 2 h, srv-prod-01 a redémarré pour la mise à jour du noyau, dans la fenêtre de maintenance. Il n'est pas revenu : la console affiche « You are in emergency mode », et la boutique est coupée depuis. C'était son premier redémarrage depuis neuf mois.
> `./doctor shell 22` t'ouvre la console du serveur (l'équivalent du KVM). Un `reboot` le redémarre pour de vrai : reviens ensuite avec `./doctor shell 22`.
> Pour tester : `curl http://localhost/` (la boutique), `curl -X POST http://localhost/api/factures` (une facture, comme à chaque commande).
> Contraintes : le durcissement CIS reste appliqué tel quel, `/tmp` en `noexec`, `nosuid` et `nodev` compris : l'audit le contrôle. Le générateur de factures est un binaire de l'éditeur, signé : on ne le modifie pas. Ce soir, le serveur redémarre encore pour finir la maintenance, sans personne devant : il doit revenir seul, et vite.

## Impact business

La boutique est fermée depuis 2 h du matin. Les commandes de la nuit sont perdues, et l'ouverture des bureaux approche, avec le pic de trafic du matin. Chaque redémarrage pour essayer une idée coûte au moins une minute et demie. Et une réparation qui ne tient pas recoupe la boutique ce soir, cette fois sans personne pour le voir.

## Les enjeux

- Travailler depuis le mode urgence : comprendre ce qui bloque, sans services et sans réseau.
- Faire démarrer le serveur sans préparer la panne du prochain redémarrage.
- Une fois la boutique revenue, vérifier ce qui dépend du démarrage : neuf mois de changements prennent effet d'un coup.
- Garder le durcissement CIS intact.

## Ce qui est vérifié

- le serveur a fini de démarrer
- la boutique répond, et une facture est générée

Si c'est bon, le check redémarre le serveur pour de vrai, puis vérifie :

- il démarre sans passer par le mode urgence, et sans attendre un disque
- aucune unité en échec
- `/tmp` reste en `noexec`, `nosuid`, `nodev` (CIS)
- la boutique répond, et une facture est générée
- le générateur de factures s'exécute dans un dossier à lui, pas dans un dossier partagé où tout le monde peut écrire

## Indices

<details><summary>Indice 1</summary>

Le mode urgence est une conséquence. La cause est plus haut dans le journal du démarrage : `journalctl -b -p err`, puis cherche « Dependency failed ». Le noyau n'y est pour rien.

</details>

<details><summary>Indice 2</summary>

Ce disque existe-t-il encore ? Cherche qui s'en sert : `grep -rl sauvegardes /etc/cron.d /usr/local/bin`.

</details>

<details><summary>Indice 3</summary>

La boutique revenue, les factures échouent : `journalctl -u boutique`. Qu'est-ce qui a changé pour `/tmp` à ce démarrage ? `findmnt /tmp`, et la date de `/etc/fstab`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
systemctl is-system-running                                # maintenance : le mode urgence
journalctl -b --no-pager | grep -E 'Timed out|Dependency failed'
# Timed out waiting for device /dev/disk/by-uuid/5f3a9c2e-1b7d-4e8a-9c41-2d6b8e0f7a13
# Dependency failed for srv-sauvegardes.mount, puis pour local-fs.target
grep -v '^#' /etc/fstab                                    # le disque de sauvegarde, et /tmp en tmpfs
```

systemd monte les systèmes de fichiers de `/etc/fstab` au démarrage. Pour un disque désigné par son UUID, il attend que le périphérique apparaisse, 1 min 30 par défaut, puis abandonne. Sans `nofail`, le montage est requis par `local-fs.target`, et son échec envoie le serveur en mode urgence, avant le réseau et les services. La ligne n'avait pas servi depuis neuf mois.

```bash
grep -rl sauvegardes /etc/cron.d /usr/local/bin            # /etc/cron.d/sauvegarde, /usr/local/bin/sauvegarde
sed -n '3,4p' /usr/local/bin/sauvegarde
# Depuis le 14 octobre (ticket #4410) : envoyée sur le NAS (sauvegarde.interne) par rsync.
# Le disque USB de /srv/sauvegardes a été débranché et rendu au datacenter le même jour.
```

Le disque est parti il y a six semaines, la ligne de `fstab` est restée. Elle ne servira plus : on la commente, avec la raison, pour que le prochain qui lira `fstab` sache ce qu'est devenu ce disque. `systemctl default` reprend ensuite le démarrage là où il s'est arrêté. Avant, `systemctl daemon-reload` : systemd a généré ses unités de montage depuis `fstab` au démarrage, et sans lui, il retenterait le disque.

```bash
cp -p /etc/fstab /etc/fstab.avant-4890
sed -i 's|^UUID=5f3a9c2e-1b7d-4e8a-9c41-2d6b8e0f7a13 |# Retiré le 14 octobre (ticket #4410) : &|' /etc/fstab
systemctl daemon-reload
systemctl default
sleep 2
systemctl is-system-running                                # running
curl -s http://localhost/; echo                            # {"boutique": "ouverte"}
curl -s -X POST http://localhost/api/factures; echo        # {"erreur": "génération de la facture impossible"}
```

La boutique répond, les factures non. Le serveur a démarré avec neuf mois de changements d'un coup, et le premier problème en cachait un autre.

```bash
journalctl -u boutique -n 1 --no-pager -o cat
# facture 52031 : échec du générateur (126) : /opt/facturation/facturation.run: 8: /tmp/facturation.BNPjjX/bin/generer: Permission denied
findmnt /tmp                                               # tmpfs rw,nosuid,nodev,noexec
ls -l --time-style=long-iso /etc/fstab.avant-4890          # modifié il y a trois semaines
sed -n '5,9p' /opt/facturation/facturation.run             # mktemp -d "${TMPDIR:-/tmp}/facturation.XXXXXX", puis exécution
```

La ligne `/tmp` du durcissement CIS date de trois semaines. Le rôle Ansible l'a écrite dans `fstab` sans monter `/tmp` (module `mount`, état `present`) : jusqu'à cette nuit, `/tmp` restait le dossier ordinaire, exécutable. Le générateur de factures est une archive autoextractible, comme celles de makeself : il se décompresse dans `$TMPDIR`, `/tmp` par défaut, et lance son moteur depuis là. Avec `noexec`, le noyau refuse.

Le CIS a raison : `/tmp` est écrit par tout le monde, rien ne doit s'y exécuter. Le générateur a donc besoin d'un dossier à lui, que seul l'utilisateur de la boutique peut écrire. `RuntimeDirectory=` le crée au démarrage du service, dans `/run`, et le vide à son arrêt.

```bash
mkdir -p /etc/systemd/system/boutique.service.d
cat > /etc/systemd/system/boutique.service.d/tmpdir.conf <<'EOF'
[Service]
# Ticket #4890 : /tmp est en noexec (CIS). Le générateur de factures s'extrait dans TMPDIR et s'y exécute :
# un dossier à la seule boutique, créé au démarrage du service et vidé à son arrêt.
RuntimeDirectory=boutique
RuntimeDirectoryMode=0700
Environment=TMPDIR=/run/boutique
EOF
systemctl daemon-reload && systemctl restart boutique && sleep 1
curl -s -X POST http://localhost/api/factures; echo        # {"facture": "/var/lib/boutique/factures/F-52031.pdf"}
```

Reste le vrai test : `reboot`, puis `./doctor shell 22`. Le serveur doit revenir en quelques secondes, en état `running`, et la facture passer sans rien toucher.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **`nofail` sur la ligne du disque** : le serveur démarre, mais attend toujours 1 min 30 un disque qui ne reviendra pas. Avec `x-systemd.device-timeout=`, l'attente raccourcit, et chaque démarrage garde une erreur de montage qui finira par masquer une vraie panne de disque.
- **Effacer la ligne sans laisser de trace** : le serveur démarre, et le prochain qui cherchera le disque de sauvegarde ne saura ni quand ni pourquoi il est parti.
- **Lancer la boutique à la main depuis le mode urgence** : elle revient, sur un serveur à moitié démarré, et rien n'est réglé pour ce soir.
- **`mount -o remount,exec /tmp`** : la facture passe jusqu'au prochain redémarrage, et l'audit CIS échoue d'ici là.
- **Retirer `noexec` de la ligne `/tmp`** : contraire au CIS, et c'est précisément le risque qu'il couvre, un dossier où tout le monde écrit et d'où tout pourrait s'exécuter.
- **`TMPDIR=/var/tmp` ou `/dev/shm`** : ça marche, parce que ces dossiers sont exécutables. Mais tout le monde peut y écrire, et le CIS demande aussi `noexec` sur eux : le contournement serait refusé au prochain audit.
- **`PrivateTmp=yes`** : le `/tmp` privé du service est un sous-dossier du `/tmp` commun, avec les mêmes options de montage. Toujours `noexec`.
- **`PrivateTmp=disconnected`** (systemd 256 et plus) : un tmpfs à part pour le service, sans `noexec`. Ça marche aussi.
- **`RuntimeDirectory=` et `TMPDIR`** : un dossier au seul utilisateur du service, visible dans l'unité, vidé à chaque arrêt.

</details>

## En prod

- Un serveur qui n'a pas redémarré depuis des mois accumule des changements jamais testés : `fstab`, unités, réglages du noyau. Redémarrer régulièrement, à une heure où quelqu'un regarde, c'est les tester un par un.
- Avant un redémarrage : `findmnt --verify` relit `fstab` et signale les sources introuvables.
- `nofail`, avec `x-systemd.device-timeout=`, pour ce dont les services n'ont pas besoin pour démarrer (sauvegardes, partages). Pas de `nofail` pour les données de la base : mieux vaut un serveur arrêté qu'une base qui démarre sur un dossier vide.
- Avec Ansible, le module `mount` en `state: present` écrit `fstab` sans monter. `state: mounted` monte aussi, et révèle une erreur le jour même, pas au redémarrage suivant.
- `/tmp` en `noexec` casse les programmes qui s'extraient pour s'exécuter : archives makeself, exécutables PyInstaller, bibliothèques natives de Java (JNA, Netty). Leur donner un dossier à eux (`TMPDIR`, `-Djava.io.tmpdir`) plutôt que rouvrir `/tmp`.
- En mode urgence, une correction de `fstab` se prend en compte avec `systemctl daemon-reload`, et `systemctl default` reprend le démarrage.
