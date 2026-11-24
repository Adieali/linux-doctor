# 25. L'audit SSH doit passer, sans couper le transporteur

## Le ticket

> **Ticket #4945, priorité haute**
> L'audit de sécurité de novembre a relevé quatre constats sur le SSH de srv-prod-01 (rapport : `/root/audit-ssh.txt`). L'équipe sécurité fait son contre-audit avant le 30 novembre, depuis 10.80.0.99 : tout doit être corrigé d'ici là.
> Le transporteur dépose nos bons de livraison en SFTP toutes les cinq minutes (compte `edi`, depuis 10.80.0.15). Son client ne sera mis à jour qu'au deuxième trimestre 2027, et la sécurité a accordé une dérogation, décrite dans le rapport.
> Pour tester : `transporteur envoi` (un dépôt, exactement comme leur client), `bastion ssh admin@10.80.0.10` (un admin), `audit <commande>` (depuis le poste de l'équipe sécurité).
> Contraintes : les admins se connectent par clé depuis le bastion, et ne doivent pas perdre l'accès. Les dépôts du transporteur ne s'arrêtent pas. Les netns `lan`, `bastion`, `audit` et `transporteur` simulent le reste : n'y touche pas.

## Impact business

Le contre-audit conditionne le renouvellement de la certification PCI DSS : sans elle, le prestataire de paiement peut suspendre l'acceptation des cartes. Et si les dépôts du transporteur s'arrêtent, les livraisons ne sont plus confirmées aux clients : le service client reçoit les appels, et les litiges de livraison ne peuvent plus être tranchés.

## Les enjeux

- Corriger les quatre constats pour de vrai, et le vérifier comme l'auditeur, depuis le réseau, pas seulement en relisant un fichier.
- Réduire l'exception du transporteur au périmètre exact de la dérogation.
- Ne couper ni le transporteur, ni les admins.

## Ce qui est vérifié

- la configuration de sshd est valide, et sshd tourne
- admin se connecte depuis le bastion, par clé
- seule l'authentification par clé est proposée
- root ne se connecte pas, même avec la clé du bastion
- l'échange de clés `diffie-hellman-group14-sha1` est refusé
- les MAC `hmac-sha1` et `hmac-sha1-etm` sont refusés
- `ssh-rsa` est refusé pour `edi` depuis une autre adresse que celle du transporteur, et pour tout autre compte
- le transporteur dépose toujours ses bons de livraison
- une clé refusée laisse son empreinte dans le journal

## Indices

<details><summary>Indice 1</summary>

Ce que sshd applique vraiment : `sshd -T`. Et pour une connexion précise : `sshd -T -C user=edi,addr=10.80.0.15,host=x`. Si ton fichier ne change rien, dans quel ordre sshd lit-il `sshd_config.d`, et quelle valeur garde-t-il quand une directive apparaît deux fois ?

</details>

<details><summary>Indice 2</summary>

Une exception pour un compte et une adresse : `Match`, dans `man sshd_config`. Toutes les directives n'y sont pas permises.

</details>

<details><summary>Indice 3</summary>

De quoi le client du transporteur a-t-il vraiment besoin ? La documentation de 2019 n'est pas une preuve : `transporteur envoi` après chaque changement, et `journalctl -u ssh`.

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
sshd -T | grep -E '^(passwordauthentication|permitrootlogin|loglevel) '
# passwordauthentication yes, permitrootlogin without-password, loglevel INFO
sshd -T | grep -E '^(kexalgorithms|macs|pubkeyacceptedalgorithms) ' | tr ', ' '\n' | grep -E 'sha1|^ssh-rsa$'
# diffie-hellman-group14-sha1, hmac-sha1-etm@openssh.com, hmac-sha1, ssh-rsa
grep -r . /etc/ssh/sshd_config.d/
```

`sshd -T` donne la configuration effective, celle que l'auditeur verra. Trois sources pour les constats : `50-cloud-init.conf`, resté du modèle de machine virtuelle, active le mot de passe. `40-transporteur.conf` (2019) ajoute pour tout le monde la signature `ssh-rsa`, l'échange de clés et le MAC en SHA-1. Et `hmac-sha1` fait partie des MAC proposés par défaut par OpenSSH : personne ne l'a ajouté, il faut le retirer.

Le réflexe serait d'écrire un `99-audit.conf` avec les bonnes valeurs. Il ne changerait presque rien : pour chaque directive, sshd garde la première valeur qu'il lit, et il lit `sshd_config.d` dans l'ordre alphabétique. `40-transporteur.conf` et `50-cloud-init.conf` passent avant. Le durcissement va donc dans un fichier lu en premier, et l'emporte sur ce qui suit, y compris un `50-cloud-init.conf` qu'un outil réécrirait.

```bash
cat > /etc/ssh/sshd_config.d/10-audit.conf <<'EOF'
# Audit de sécurité de novembre 2026 (ticket #4945).
# sshd garde la première valeur lue pour chaque directive : ce fichier est lu avant les autres et l'emporte.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
# Empreinte de chaque clé présentée, acceptée ou refusée.
LogLevel VERBOSE
# Rien en SHA-1. Seule exception, ssh-rsa pour edi depuis le transporteur (dérogation SEC-112) : 40-transporteur.conf.
KexAlgorithms -diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1
MACs -hmac-sha1,hmac-sha1-etm@openssh.com
PubkeyAcceptedAlgorithms -ssh-rsa
EOF
```

L'exception du transporteur se limite à ce que dit la dérogation : un compte, une adresse, et la signature `ssh-rsa`. Un bloc `Match` le permet pour `PubkeyAcceptedAlgorithms`. Il ne le permettrait pas pour `KexAlgorithms` ou `MACs`, qui ne se règlent que pour tout le serveur. Reste à savoir si leur client en a besoin : la ligne de 2019 dit « algorithmes SHA-1 requis ». On les retire, et on essaie.

```bash
cat > /etc/ssh/sshd_config.d/40-transporteur.conf <<'EOF'
# Transporteur (ticket #2231, 2019) : dépôt SFTP des bons de livraison, compte edi, depuis 10.80.0.15.
# Leur client ne signe qu'en ssh-rsa (SHA-1) : dérogation SEC-112, pour ce compte et cette adresse seulement,
# jusqu'à sa mise à jour (deuxième trimestre 2027). Il négocie ecdh-sha2-nistp256 et hmac-sha2-256 : pas
# d'échange de clés ni de MAC en SHA-1 (vérifié le jour de l'audit, ticket #4945).
Match User edi Address 10.80.0.15
    PubkeyAcceptedAlgorithms +ssh-rsa

Match User edi
    AuthorizedKeysFile /etc/ssh/cles-autorisees/%u
    ChrootDirectory /srv/sftp/edi
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
rm /etc/ssh/sshd_config.d/50-cloud-init.conf
rm /root/.ssh/authorized_keys                              # root n'a plus de raison d'avoir une clé
sshd -t && systemctl reload ssh                            # valider avant de recharger
```

`sshd -t` refuse une configuration invalide avant qu'elle ne coupe quoi que ce soit. `reload` garde les sessions ouvertes : en vrai, une session de secours reste ouverte jusqu'à la fin des essais.

```bash
transporteur envoi && echo "dépôt ok"                      # sftp> put /tmp/bon-... : dépôt ok
bastion ssh -n admin@10.80.0.10 'id -nG'                   # admin sudo
bastion ssh -n -o BatchMode=yes root@10.80.0.10 true       # Permission denied (publickey)
sshd -T -C user=edi,addr=10.80.0.15,host=x | grep '^pubkeyacceptedalgorithms ' | tr ', ' '\n' | grep -x ssh-rsa   # ssh-rsa
sshd -T -C user=edi,addr=10.80.0.99,host=x | grep '^pubkeyacceptedalgorithms ' | tr ', ' '\n' | grep -cx ssh-rsa  # 0
journalctl -u ssh -n 20 --no-pager -o cat | grep -m1 'Accepted publickey for edi'
# Accepted publickey for edi from 10.80.0.15 port ... ssh2: RSA SHA256:...
```

Le transporteur passe sans SHA-1 ailleurs que dans sa signature. Avec `LogLevel VERBOSE`, chaque clé présentée laisse son empreinte, acceptée ou refusée : c'est la trace que demandait l'audit.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Un `99-audit.conf` avec les bonnes valeurs** : sshd garde la première valeur lue. Le mot de passe et le SHA-1 restent, et `sshd -T` le montre.
- **Modifier `sshd_config` directement** : le fichier principal lit `sshd_config.d` dès sa première ligne. Ses propres valeurs passent après, et la prochaine mise à jour du paquet proposera de l'écraser.
- **Retirer `ssh-rsa` pour tout le monde** : l'audit passe, et le transporteur ne dépose plus rien. La dérogation existe pour ça.
- **Garder `PubkeyAcceptedAlgorithms +ssh-rsa` global** : le transporteur passe, et n'importe quel compte peut encore signer en SHA-1. L'auditeur le verra depuis son poste.
- **Garder l'échange de clés et le MAC en SHA-1 « pour le transporteur »** : impossible à limiter à un compte (pas de `KexAlgorithms` ni de `MACs` dans un `Match`), et son client n'en a pas besoin.
- **`systemctl restart` sans `sshd -t`** : une faute de frappe, et sshd ne redémarre pas. Les sessions ouvertes survivent, les nouvelles, non.
- **Un fichier lu en premier, une exception dans un `Match` limité au compte et à l'adresse, et chaque constat vérifié depuis le réseau** : la configuration dit ce qu'elle fait, et l'exception reste dans le périmètre de la dérogation.

</details>

## En prod

- sshd garde la **première** valeur lue pour chaque directive, à l'inverse de la plupart des logiciels. `sshd_config` inclut `sshd_config.d/*.conf` dès sa première ligne : un durcissement va dans un fichier au nom qui passe avant les autres (`10-…`).
- `sshd -T` montre la configuration effective, et `sshd -T -C user=…,addr=…,host=…` celle qu'une connexion précise recevra, blocs `Match` compris. C'est la seule façon fiable de savoir ce qui s'applique.
- Dans un `Match`, seules certaines directives sont permises : `PubkeyAcceptedAlgorithms` oui, `KexAlgorithms`, `MACs` et `Ciphers` non. Une dérogation sur ces algorithmes vaut pour tout le serveur.
- Une clé RSA n'est pas un problème : c'est la signature `ssh-rsa` (SHA-1) qui l'est. La même clé signe en `rsa-sha2-256` avec un client récent.
- `sshd -t` avant chaque rechargement, et une session de secours ouverte jusqu'à ce que les nouvelles connexions soient testées.
- Une documentation d'intégration de 2019 n'est pas une preuve : la négociation réelle se lit dans le journal (`LogLevel DEBUG` le temps d'un essai) ou se teste.
