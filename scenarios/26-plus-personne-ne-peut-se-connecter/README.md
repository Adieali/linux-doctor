# 26. Plus personne ne peut se connecter

## Le ticket

> **Ticket #4950, priorité critique**
> Depuis ce matin, aucun admin ne peut se connecter à srv-prod-01 : la connexion SSH se ferme aussitôt, alors que la clé est acceptée. Hier soir, l'équipe sécurité a déployé SEC-118 : contrôle d'accès PAM, et verrouillage des comptes après trois échecs, comme le demande le CIS. La supervision, elle, se connecte toujours.
> Pour tester : `connexion alice` (une admin, depuis le bastion, avec sa clé), `connexion alice sudo id` (sudo, avec son mot de passe, comme elle le taperait), `connexion dev1` (un développeur), `connexion supervision uptime`.
> Contraintes : SEC-118 reste en place, contrôle d'accès et verrouillage des comptes compris. SSH reste joignable depuis Internet : des prestataires s'y connectent, par clé. Les netns et l'unité `lab-internet` simulent le reste : n'y touche pas.

## Impact business

Personne ne peut intervenir sur le serveur de production : ni mise en production, ni correction, ni réponse à un incident. Une panne aujourd'hui ne pourrait être traitée qu'en passant par la console de l'hébergeur. Et les admins qui retrouveront l'accès devront encore pouvoir passer root.

## Les enjeux

- Comprendre une règle d'accès qui laisse passer la supervision et refuse les admins.
- Rendre l'accès aux admins sans affaiblir SEC-118.
- Trouver pourquoi des comptes sont verrouillés, et pourquoi ils le seraient de nouveau demain.

## Ce qui est vérifié

- SEC-118 est en place : `pam_access` pour sshd, `pam_faillock` autour de `pam_unix`
- alice et bruno se connectent depuis le bastion, et `sudo` marche
- la supervision se connecte toujours ; dev1, qui n'est pas admin, est refusé ; alice est refusée ailleurs qu'au bastion
- SSH reste joignable depuis Internet, par clé, et ne demande plus de mot de passe depuis Internet
- le verrouillage marche toujours : trois échecs de dev1 à `sudo`, et son compte est verrouillé

Si c'est bon, le check envoie depuis Internet trois mots de passe faux pour alice et pour bruno, puis vérifie :

- aucun échec n'est compté pour alice
- alice et bruno ont toujours `sudo`

## Indices

<details><summary>Indice 1</summary>

Pourquoi la connexion se ferme-t-elle ? `journalctl -u ssh`. Puis `/etc/security/access.conf` et la ligne de `pam_access` dans `/etc/pam.d/sshd` : que veut dire l'option qui y figure ?

</details>

<details><summary>Indice 2</summary>

Une fois connectée, alice tape le bon mot de passe et `sudo` répond « Sorry, try again ». `faillock --user alice` : d'où viennent ces échecs ?

</details>

<details><summary>Indice 3</summary>

Déverrouiller ne suffit pas : regarde de nouveau dans une minute. Pourquoi des inconnus peuvent-ils compter des échecs sur le compte d'alice ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
connexion alice true                                       # Connection closed by 10.70.0.10 port 22
journalctl -u ssh --no-pager -o cat | grep pam_access | tail -1
# pam_access(sshd:account): access denied for user `alice' from `10.71.0.5'
connexion supervision uptime >/dev/null && echo ok         # ok : la supervision passe
grep -v '^#' /etc/security/access.conf                     # +:supervision:10.72.0.20  +:admins:10.71.0.5  -:ALL:ALL
grep pam_access /etc/pam.d/sshd                            # account required pam_access.so nodefgroup
```

La clé est acceptée, puis la pile `account` de PAM refuse : `pam_access`. La règle des admins existe, mais l'option `nodefgroup` change le sens de `admins` : avec elle, un nom sans parenthèses ne désigne qu'un utilisateur, jamais un groupe. Il n'y a pas d'utilisateur `admins`, la ligne ne correspond à personne, et `-:ALL:ALL` refuse tout le monde. La supervision est désignée par son nom d'utilisateur : elle passe. `nodefgroup` est un bon choix (un utilisateur ne peut pas se faire passer pour un groupe) : on garde l'option, et on écrit le groupe comme elle l'attend.

```bash
sed -i 's/^+:admins:10.71.0.5$/+:(admins):10.71.0.5/' /etc/security/access.conf
connexion alice id                                         # uid=1000(alice) ... groups=...,27(sudo),1000(admins)
connexion dev1 true                                        # Connection closed : toujours refusé
connexion alice sudo id                                    # Sorry, try again : avec le bon mot de passe
faillock --user alice
# 2026-11-24 13:48:55 RHOST 203.0.113.50   V  (trois fois, ou plus)
journalctl -u ssh --no-pager -o cat | grep 'Failed password' | tail -3
# Failed password for alice from 203.0.113.50 ..., puis bruno, puis root
```

alice entre, et `sudo` refuse son mot de passe : son compte est verrouillé. `pam_faillock` compte les échecs de la pile `auth`, celle des mots de passe, quelle que soit l'origine. sshd accepte les mots de passe depuis Internet, et un robot y essaie des mots de passe sur les noms qu'il devine : alice, bruno, root. Trois échecs, et `unlock_time = 0` garde le compte verrouillé jusqu'à ce qu'un admin le libère. Les clés SSH ne passent pas par la pile `auth` : c'est pour ça que la connexion marche, et pas `sudo`.

`faillock --reset` libérerait alice pour une minute, le temps que le robot repasse. Tant que sshd accepte un mot de passe depuis Internet, n'importe qui peut verrouiller n'importe quel compte en se trompant trois fois. Les admins et les prestataires se connectent par clé : sshd n'a aucune raison d'accepter un mot de passe. Les mots de passe restent pour `sudo`, en local, et le verrouillage les protège là.

```bash
cat > /etc/ssh/sshd_config.d/10-cles-seulement.conf <<'EOF'
# Ticket #4950 : par SSH, des clés seulement. Les mots de passe ne servent qu'à sudo, en local.
# Sinon, n'importe qui sur Internet peut verrouiller un compte (pam_faillock, SEC-118) en se trompant trois fois.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl reload ssh
faillock --user alice --reset
faillock --user bruno --reset
connexion alice sudo id                                    # uid=0(root) gid=0(root) groups=0(root)
sleep 20; faillock --user alice | grep -c ' V$'            # 0 : le robot ne compte plus rien
```

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Retirer `pam_access`, ou la ligne `-:ALL:ALL`** : les admins entrent, et tout le monde avec eux. Contraire à SEC-118.
- **Retirer `nodefgroup`** : `admins` redevient un groupe, et la règle marche. Mais un utilisateur nommé comme un groupe pourrait de nouveau correspondre à sa règle : écrire `(admins)` garde la précision voulue.
- **`faillock --reset` seul** : alice retrouve `sudo` jusqu'au prochain passage du robot, dans la minute.
- **`unlock_time = 900`** : le verrou tombe après 15 minutes, et le robot le remet aussitôt. Les admins restent sans `sudo` tant que l'attaque dure.
- **Retirer `pam_faillock`** : plus de verrouillage, ni contre le robot, ni contre quelqu'un qui devinerait un mot de passe en local. Contraire à SEC-118.
- **Fermer SSH depuis Internet** : le robot s'arrête, et les prestataires aussi.
- **Des clés seulement pour SSH, et `pam_faillock` pour le reste** : Internet ne peut plus compter d'échecs, et le verrouillage protège encore `sudo` et la console.

</details>

## En prod

- Dans `access.conf`, avec `nodefgroup`, un groupe s'écrit entre parenthèses : `(admins)`. Sans l'option, un nom est cherché parmi les utilisateurs puis parmi les groupes. Une règle qui ne correspond à personne ne déclenche aucune erreur : elle laisse simplement passer la ligne suivante.
- `pam_access` agit dans la pile `account`, qui passe aussi pour une connexion par clé. `pam_faillock` agit dans la pile `auth`, celle des mots de passe : une clé ne l'atteint pas, `sudo` si.
- Un verrouillage après N échecs, sur un service qui accepte des mots de passe depuis Internet, donne à n'importe qui le moyen de bloquer n'importe quel compte. Verrouillage et mots de passe exposés ne vont pas ensemble.
- `faillock --user <compte>` montre les échecs et leur origine, `faillock --user <compte> --reset` les efface. Après un déverrouillage, revérifier une minute plus tard : si le compteur remonte, la cause est toujours là.
- Tester un changement PAM avec une session root ouverte à côté, et sur plusieurs comptes : celui qui doit passer, celui qui doit être refusé.
