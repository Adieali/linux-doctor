# 15. Le certificat est valide, les partenaires ne passent plus

## Le ticket

> **Ticket #4806, priorité critique**
> Depuis cette nuit, les partenaires n'arrivent plus à appeler l'API (`https://api.boutique.lan`). Leurs intégrations tombent en erreur TLS : « unable to get local issuer certificate » pour les uns, « PKIX path building failed » pour les autres. Le certificat a été renouvelé cette nuit à 3 h, automatiquement, comme tous les trois mois.
> Pourtant, le certificat est valide jusqu'en février, le navigateur affiche le cadenas et la sonde TLS de la supervision est verte. Un partenaire demande si nous avons coupé TLS 1.2.
> Pour tester comme un partenaire : `partenaire curl https://api.boutique.lan/api/stock`.
> Contraintes : la banque partenaire a épinglé la clé publique du certificat, elle ne doit pas changer. Des partenaires gardent leurs connexions ouvertes toute la journée : nginx se recharge, il ne redémarre pas. Le prochain renouvellement est automatique, dans trois mois, et personne ne sera là pour le surveiller.
> Le netns `partenaire` et l'AC (`/var/lib/labo-acme`, `acme-renouveler`) simulent l'extérieur : ne les modifie pas.

## Impact business

Les partenaires ne synchronisent plus leurs stocks ni leurs commandes. Chacun se rabat sur des échanges par mail et des fichiers CSV, avec les erreurs de saisie qui vont avec, et la banque ne rapproche plus les paiements. Comme le navigateur et la supervision disent que tout va bien, le risque est de renvoyer le problème chez les partenaires (« chez nous, ça marche ») et de perdre une journée de plus.

## Les enjeux

- Comprendre pourquoi le même certificat passe dans un navigateur et pas chez un partenaire.
- Regarder ce que le serveur envoie vraiment, pas ce qu'on croit qu'il envoie.
- Réparer sans changer de clé et sans couper les connexions en cours.
- Faire en sorte que le prochain renouvellement ne recasse rien, et que la supervision voie la panne si elle revient.

## Ce qui est vérifié

- les partenaires passent, avec la seule racine de l'AC comme confiance
- nginx a été rechargé, pas redémarré
- la clé publique n'a pas changé (épinglée par la banque partenaire)
- nginx sert le certificat du dernier renouvellement
- la sonde TLS est verte

Si c'est bon, le check sert un instant notre certificat seul, sans intermédiaire, et vérifie que la sonde voit la chaîne incomplète. Puis il simule le renouvellement suivant, pour lequel l'AC signe avec un autre intermédiaire, et vérifie :

- nginx sert le nouveau certificat
- les partenaires passent toujours
- la clé publique n'a toujours pas changé

## Indices

<details><summary>Indice 1</summary>

Le partenaire et la sonde font la même requête vers la même API. Compare ce que chacun accepte comme confiance : `partenaire curl -v`, et la commande de l'unité `sonde-tls`.

</details>

<details><summary>Indice 2</summary>

`openssl s_client -showcerts` montre la chaîne que le serveur envoie. Pour chaque certificat, regarde le sujet (`s:`) et l'émetteur (`i:`) : chacun est-il signé par le suivant ?

</details>

<details><summary>Indice 3</summary>

Le fichier que sert nginx est refabriqué à chaque renouvellement. Par qui, et à partir de quoi ? `journalctl -t acme`, `/etc/acme/deploy.d/`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
partenaire curl -sS -o /dev/null https://api.boutique.lan/api/stock      # unable to get local issuer certificate
openssl x509 -noout -issuer -enddate -in /etc/acme/live/api.boutique.lan/cert.pem   # émis par Labo R11, valide 90 jours
grep curl /etc/systemd/system/sonde-tls.service                          # --cacert /etc/sonde/ca-bundle.pem
grep -c 'BEGIN CERTIFICATE' /etc/sonde/ca-bundle.pem                     # 3 certificats de confiance pour la sonde
```

Le certificat est valide, la date aussi, et TLS 1.2 n'a pas bougé : le partenaire va jusqu'à la vérification du certificat, et c'est là qu'il échoue. Il ne trouve pas d'émetteur auquel il fait confiance. Ce que le serveur envoie :

```bash
partenaire openssl s_client -connect api.boutique.lan:443 -servername api.boutique.lan -showcerts </dev/null 2>/dev/null | grep -E '^ *[0-9]+ s:|^ +i:'
```

Deux certificats, la chaîne a l'air complète. Mais le premier, le nôtre, est émis par `Labo R11`, et le second est `Labo R10`. Ils ne se suivent pas. Un client ne fait confiance qu'à la racine (`Labo Racine X1`) : pour y arriver depuis notre certificat, il lui faut R11, que le serveur n'envoie pas. R10 ne lui sert à rien.

Le navigateur s'en sort parce qu'il complète la chaîne tout seul : il télécharge l'intermédiaire manquant à l'adresse indiquée dans le certificat, ou l'a déjà en cache. Les bibliothèques des partenaires (Java, Python, curl) ne le font pas. La sonde, elle, a R10 et R11 dans son propre bundle : elle trouve R11 chez elle, n'a besoin de rien de la part du serveur, et ne vérifie donc jamais ce qu'il envoie.

D'où vient ce R10 :

```bash
journalctl -t acme -o cat | tail -2                                      # août : émis par Labo R10. Cette nuit : Labo R11
cat /etc/acme/deploy.d/nginx                                             # cert.pem + /etc/nginx/ssl/intermediaire.pem
openssl x509 -noout -subject -in /etc/nginx/ssl/intermediaire.pem        # Labo R10, téléchargé en 2023
```

Le hook de déploiement colle notre certificat avec un intermédiaire figé dans un fichier local. Tant que l'AC signait avec R10, ça marchait. Cette nuit, elle a signé avec R11, et rien n'a suivi. Le client ACME fournit pourtant, à chaque renouvellement, `fullchain.pem` : notre certificat suivi de l'intermédiaire qui l'a réellement signé. Avant de s'en servir, on vérifie qu'il remonte bien à la racine :

```bash
openssl verify -CAfile /etc/ssl/certs/labo-racine-x1.pem -untrusted /etc/acme/live/api.boutique.lan/chain.pem /etc/acme/live/api.boutique.lan/cert.pem   # OK
```

Le hook réécrit avec `fullchain.pem`, la même clé, un test de configuration, puis un rechargement :

```bash
cat > /etc/acme/deploy.d/nginx <<'EOF'
#!/bin/bash
# Déploiement du certificat de l'API.
# Ticket #4806 : fullchain.pem, fourni par l'AC à chaque renouvellement. L'intermédiaire change d'un
# renouvellement à l'autre : il ne doit jamais être figé dans un fichier local.
set -e
install -m 644 "$RENEWED_LINEAGE/fullchain.pem" /etc/nginx/ssl/api.crt
install -m 600 "$RENEWED_LINEAGE/privkey.pem" /etc/nginx/ssl/api.key
nginx -t -q
systemctl reload nginx
EOF
RENEWED_LINEAGE=/etc/acme/live/api.boutique.lan /etc/acme/deploy.d/nginx
rm /etc/nginx/ssl/intermediaire.pem
timeout 10 bash -c 'until partenaire curl -fs -o /dev/null https://api.boutique.lan/api/stock; do sleep 0.2; done'
partenaire curl -sS https://api.boutique.lan/api/stock                   # {"reference":"CHAISE-ORME","stock":42}
```

`systemctl reload` fait relire la configuration et les certificats sans toucher au processus maître : les connexions ouvertes se terminent normalement, les nouvelles reçoivent la bonne chaîne. La commande rend la main avant que les nouveaux workers aient pris le relais : un test lancé aussitôt peut encore tomber sur l'ancienne chaîne et faire croire que la correction n'a pas pris. D'où la boucle d'attente, quelques fractions de seconde en général. La clé est la même, l'épinglage de la banque tient.

Reste la sonde, qui n'a rien vu et ne verrait rien la prochaine fois. Elle doit faire confiance comme un partenaire, à la racine seule :

```bash
cp /etc/ssl/certs/labo-racine-x1.pem /etc/sonde/ca-bundle.pem
systemctl start sonde-tls && echo "sonde verte"
```

Dernière étape, hors du serveur : prévenir les partenaires que la chaîne est corrigée, pour qu'ils relancent leurs synchronisations, et chercher les autres hooks du même auteur sur les autres serveurs.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Demander aux partenaires d'installer R11** : le problème part chez eux, et revient à chaque changement d'intermédiaire. Certains ne pourront pas modifier leur magasin de confiance.
- **Remplacer R10 par R11 dans `intermediaire.pem`** : ça passe aujourd'hui, et ça recasse au premier renouvellement qui change d'intermédiaire.
- **`ssl_trusted_certificate`** : nginx s'en sert pour l'OCSP et pour vérifier les certificats des clients. Il ne l'envoie jamais dans la chaîne.
- **Redémarrer nginx** : la chaîne est corrigée, mais les connexions ouvertes des partenaires sont coupées. Un rechargement suffit.
- **Une nouvelle clé, ou un certificat refait à la main** : l'épinglage de la banque casse, et le paiement s'arrête net.
- **Désactiver la vérification chez le partenaire (`-k`)** : la panne disparaît, la sécurité du lien avec elle.
- **`fullchain.pem` dans le hook, rechargement, sonde avec la racine seule** : la chaîne suit l'AC à chaque renouvellement, sans personne, et la supervision voit la panne si elle revient.

</details>

## En prod

- Toujours servir le certificat suivi de ses intermédiaires (`fullchain.pem`). Jamais un intermédiaire figé dans un fichier, et inutile d'y ajouter la racine.
- Tester une chaîne comme un client strict : `openssl s_client -verify_return_error` avec un magasin qui ne contient que la racine. Le navigateur ne prouve rien, il complète la chaîne tout seul.
- Une sonde TLS fait confiance à la racine seule. Des intermédiaires dans son magasin la rendent aveugle aux chaînes incomplètes.
- Certaines AC changent d'intermédiaire d'un renouvellement à l'autre. Vérifier la chaîne après chaque renouvellement automatique, pas seulement la date d'expiration.
- Avant de déployer : `openssl verify -CAfile racine.pem -untrusted chain.pem cert.pem`.
