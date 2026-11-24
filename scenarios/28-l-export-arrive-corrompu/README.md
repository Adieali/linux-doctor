# 28. L'export de nuit arrive corrompu chez le partenaire

## Le ticket

> **Ticket #4934, priorité haute**
> Depuis trois nuits, la place de marché rejette notre catalogue : « fichier invalide : 9 colonnes au lieu de 5 ». Nos 60 000 références sont dépubliées jusqu'au prochain fichier valide. L'export de nuit dit pourtant qu'il s'est bien passé, et relancé à la main dans la journée, il produit un fichier parfait.
> Pour regarder : `/srv/echanges/catalogue.csv` (le partenaire le récupère à 2 h 30), `journalctl -u export-catalogue`, `/var/log/export-catalogue.log`.
> Contraintes : l'export charge la base, jamais deux à la fois. L'astreinte doit pouvoir le relancer à la main à toute heure, avec la commande de sa procédure : `sudo -u export /usr/local/bin/export-catalogue`. Le durcissement de l'unité systemd, demandé par la sécurité (ticket #4790), reste en place. L'export dure de plus en plus longtemps : le partenaire peut passer pendant qu'il tourne.

## Impact business

La place de marché fait un tiers du chiffre d'affaires en ligne. Chaque nuit de rejet, les 60 000 références disparaissent de son site jusqu'au fichier suivant, et les ventes avec. Comme l'export « réussit » et qu'un essai dans la journée donne un fichier parfait, chacun accuse le partenaire, qui accuse le fichier.

## Les enjeux

- Comprendre ce qui ne se produit que la nuit, quand personne ne regarde.
- Garantir un seul export à la fois, quel que soit celui qui le lance : le minuteur ou l'astreinte.
- Ne jamais laisser le partenaire lire un fichier à moitié écrit.
- Garder le durcissement de l'unité.

## Ce qui est vérifié

- le minuteur systemd est actif, et plus aucune ligne cron ne lance l'export
- l'unité garde son durcissement (`PrivateTmp`, `ProtectSystem=strict`)
- un export seul produit un fichier que le partenaire accepte

Puis le check rejoue deux nuits : le minuteur lance l'export et l'astreinte le relance à la main pendant qu'il tourne, puis l'inverse. Pendant ce temps, il compte les extractions qui tournent et lit le fichier comme le partenaire. Il vérifie, pour chaque nuit :

- jamais deux extractions en même temps
- le partenaire n'a jamais vu de fichier incomplet
- le fichier final est accepté par le partenaire

## Indices

<details><summary>Indice 1</summary>

Combien de lignes dans le fichier, pour 60 000 références ? Qui lance l'export la nuit ? `systemctl list-timers`, `ls /etc/cron.d`, et les heures dans `/var/log/export-catalogue.log` et dans le journal.

</details>

<details><summary>Indice 2</summary>

Le script a un verrou. Où est-il, et voit-on le même fichier depuis l'unité systemd et depuis cron ? `systemctl show export-catalogue -p PrivateTmp`.

</details>

<details><summary>Indice 3</summary>

Que lit le partenaire s'il passe à 2 h 30, pendant que le fichier s'écrit ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
wc -l /srv/echanges/catalogue.csv                          # 120001 : deux fois trop
awk -F';' 'NF != 5' /srv/echanges/catalogue.csv | head -1   # deux références collées sur une ligne : 9 colonnes
cat /var/log/export-catalogue.log                          # lancé par cron : début et fin
journalctl -u export-catalogue --no-pager -o cat | grep export   # lancé par le minuteur : à la même seconde
cat /etc/cron.d/export-catalogue                           # 0 2 * * *, fichier vieux de cinq semaines
systemctl cat export-catalogue.timer | grep -E 'OnCalendar|Migration'   # 02:00, migration depuis cron (#4790)
```

L'export tourne deux fois chaque nuit : le minuteur de la migration vers systemd, et la ligne cron qui devait partir avec elle. Les deux écrivent le même fichier. Chacun le vide en écrivant l'en-tête, puis ajoute ses lignes par blocs. Résultat : 120 000 lignes, et des références coupées en plein milieu par les blocs de l'autre. Dans la journée, un seul export tourne, et le fichier est parfait.

Le script avait pourtant prévu ce cas :

```bash
sed -n '5,9p' /usr/local/bin/export-catalogue              # flock -n sur /tmp/export-catalogue.lock
systemctl show export-catalogue -p PrivateTmp              # PrivateTmp=yes
```

Avec `PrivateTmp=yes`, l'unité a son propre `/tmp`, invisible des autres processus. Le verrou du minuteur et celui de cron sont deux fichiers différents : chacun prend le sien, et les deux exports passent. Le durcissement de la migration a cassé le verrou sans que personne le remarque.

Trois corrections. Une seule planification d'abord : la ligne cron est désactivée, avec la raison.

```bash
sed -i 's|^0 2 |# Remplacé par export-catalogue.timer (migration #4790), désactivé (#4934) : &|' /etc/cron.d/export-catalogue
```

Ensuite, un verrou que tout le monde voit, pour les relances à la main : dans `/run/lock`. L'unité a `ProtectSystem=strict`, qui monte tout le système en lecture seule, `/run` compris : elle doit y avoir droit d'écriture, et seulement là. Enfin, une écriture atomique : le fichier s'écrit à côté, puis remplace l'ancien d'un coup. Le partenaire lit l'ancien fichier ou le nouveau, jamais un fichier à moitié écrit.

```bash
cat > /usr/local/bin/export-catalogue <<'EOF'
#!/bin/bash
# Export du catalogue vers la place de marché. Le partenaire récupère /srv/echanges/catalogue.csv à 2 h 30.
# Un seul export à la fois : il charge la base. Verrou dans /run/lock, visible du minuteur (malgré son
# PrivateTmp) comme des relances à la main (sudo -u export).
set -e
exec 9> /run/lock/export-catalogue.lock
if ! flock -n 9; then
    echo "export déjà en cours, abandon"
    exit 0
fi
sortie=/srv/echanges/catalogue.csv
# Écrit à côté, puis renommé : le partenaire voit l'ancien fichier ou le nouveau, jamais un fichier partiel.
tmp=$(mktemp /srv/echanges/.catalogue.csv.XXXXXX)
trap 'rm -f "$tmp"' EXIT
echo "$(date '+%F %T') début de l'export"
echo "reference;libelle;prix;stock;categorie" > "$tmp"
python3 /opt/catalogue/extraire.py >> "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$sortie"
echo "$(date '+%F %T') fin de l'export : $(wc -l < "$sortie") lignes"
EOF
mkdir -p /etc/systemd/system/export-catalogue.service.d
cat > /etc/systemd/system/export-catalogue.service.d/verrou.conf <<'EOF'
[Service]
# Ticket #4934 : le verrou de l'export est dans /run/lock, partagé avec les relances à la main.
ReadWritePaths=/run/lock
EOF
systemctl daemon-reload
```

Essai : le minuteur et l'astreinte ensemble.

```bash
systemctl start --no-block export-catalogue; sleep 0.5
sudo -u export /usr/local/bin/export-catalogue             # export déjà en cours, abandon
sleep 6; wc -l /srv/echanges/catalogue.csv                 # 60001
```

La procédure de l'astreinte gagne à passer par `systemctl start export-catalogue` : systemd ne lance jamais une unité déjà en cours, et la relance profite du durcissement et du journal.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Supprimer seulement la ligne cron** : plus de double export la nuit, mais une relance à la main pendant l'export du minuteur passe toujours à côté du verrou, et le partenaire lit encore un fichier en cours d'écriture.
- **Retirer `PrivateTmp=yes`** : le verrou refonctionne, et le durcissement demandé par la sécurité recule pour corriger un chemin de fichier.
- **Verrou dans `/run/lock` sans `ReadWritePaths=`** : l'unité ne peut pas créer le fichier (système de fichiers en lecture seule), et l'export de nuit échoue.
- **`flock` sans `-n`** : la seconde exécution attend la fin de la première, puis exporte à son tour. Rien n'est corrompu, mais la base est chargée deux fois, et l'heure de fin recule.
- **Garder l'écriture directe dans `catalogue.csv`** : le partenaire qui passe pendant l'export récupère un fichier tronqué. Le problème reviendra le jour où l'export dépassera 2 h 30.
- **Une planification, un verrou visible de tous, une écriture atomique** : chaque cause de corruption est fermée séparément, et le durcissement reste.

</details>

## En prod

- Une migration de cron vers systemd n'est finie que quand l'ancienne ligne cron est partie. Chercher partout : `/etc/crontab`, `/etc/cron.d`, `crontab -l` de chaque utilisateur.
- `PrivateTmp=yes` donne à l'unité un `/tmp` et un `/var/tmp` à elle. Verrous, sockets et fichiers d'échange qui y vivent ne sont plus partagés : les mettre dans `/run/lock`, `/run/<appli>` ou un dossier de l'application.
- `ProtectSystem=strict` met tout en lecture seule, `/run` compris : chaque chemin écrit par le service se déclare dans `ReadWritePaths=` (ou `RuntimeDirectory=`, `StateDirectory=`).
- Un fichier lu par quelqu'un d'autre s'écrit à côté, dans le même système de fichiers, puis se renomme (`mv`) : le renommage est atomique, la lecture voit l'ancien ou le nouveau.
- systemd ne lance jamais deux fois la même unité en même temps : faire passer les relances manuelles par `systemctl start` règle la moitié du problème sans verrou.
