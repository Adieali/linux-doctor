# 21. Le nom résout vers le mauvais serveur

## Le ticket

> **Ticket #4878, priorité critique**
> Depuis ce matin, plus aucun paiement ne passe : le service des paiements répond « paiement injoignable ». Le prestataire a éteint son ancienne plateforme ce matin, comme annoncé il y a six mois, et assure que la nouvelle va bien. D'ailleurs, `dig api.paiement.example` donne bien sa nouvelle adresse, 198.51.100.30.
> La semaine dernière, l'équipe infra a déployé sur le serveur le modèle commun de `resolv.conf` (v3).
> Pour tester : `curl -X POST http://localhost:8000/payer`.
> Contraintes : le DNS interne et sa zone appartiennent à l'équipe infra, joker compris (il sert les environnements de recette). Les services internes s'appellent par leur nom court (`stock`) : ça doit continuer de marcher. Le prestataire peut encore changer d'adresse, sans prévenir autrement que par son DNS.
> Les netns `routeur`, `dns`, `accueil`, `stock` et `internet`, et les unités `lab-*`, simulent le reste : n'y touche pas.

## Impact business

Aucun paiement ne passe : chaque panier validé finit en erreur, et la boutique ne vend plus rien. Le prestataire montre que sa plateforme répond, l'équipe réseau montre que le DNS donne la bonne adresse, et chacun renvoie le ticket au voisin. Chaque heure de panne, c'est une journée de chiffre d'affaires qui fond, et des clients qui achètent ailleurs.

## Les enjeux

- Comprendre pourquoi l'application n'obtient pas l'adresse que montre `dig`.
- Trouver, couche par couche, ce qui décide de l'adresse : fichiers locaux, liste de recherche, DNS.
- Réparer sans toucher au DNS de l'infra, ni casser les noms courts des services internes.
- Ne rien figer : le prestataire doit pouvoir changer d'adresse.

## Ce qui est vérifié

- le DNS interne a toujours son joker, pour la recette
- api.paiement.example résout vers le prestataire (198.51.100.30)
- un nom externe à un seul point aussi : transporteur.example (198.51.100.40)
- les noms courts internes marchent toujours : stock (10.63.0.21)
- un paiement passe de bout en bout

Les résolutions sont faites comme une application les fait (`getent`), pas avec `dig`. Si c'est bon, le check fait changer d'adresse le prestataire, publie la nouvelle dans son DNS, et vérifie qu'un paiement passe encore.

## Indices

<details><summary>Indice 1</summary>

`dig` interroge un serveur DNS. Une application demande à la bibliothèque C, qui suit `/etc/nsswitch.conf`. Compare `dig +short api.paiement.example` et `getent ahostsv4 api.paiement.example`.

</details>

<details><summary>Indice 2</summary>

Une fois `/etc/hosts` mis hors de cause, compare encore : `dig +short +search api.paiement.example`. Que contient `/etc/resolv.conf`, et que fait l'option `ndots` ?

</details>

<details><summary>Indice 3</summary>

Quel nom complet le résolveur a-t-il essayé en premier ? Et que répond le DNS interne à un nom qu'il ne connaît pas, en `.prod.boutique.lan` ?

</details>

## Démarche commentée

<details><summary>Voir la solution</summary>

```bash
curl -s -X POST http://localhost:8000/payer; echo        # paiement injoignable (...) : No route to host
dig +short api.paiement.example                          # 198.51.100.30
getent ahostsv4 api.paiement.example | head -1           # 198.51.100.99 : pas ce que montre dig
grep -B1 paiement /etc/hosts                             # 198.51.100.99, « Migration PSP (mars 2025), temporaire »
grep '^hosts' /etc/nsswitch.conf                         # files dns : /etc/hosts d'abord
```

`dig` interroge directement le serveur DNS. Une application, elle, demande à la bibliothèque C (`getaddrinfo`), qui suit `/etc/nsswitch.conf` : d'abord `/etc/hosts`, ensuite le DNS. L'entrée posée pendant la migration de mars 2025 envoie toujours le service vers l'ancienne plateforme, éteinte ce matin. Elle était « temporaire » :

```bash
grep -v -e 'Migration PSP' -e 'api\.paiement\.example' /etc/hosts > /tmp/hosts && cat /tmp/hosts > /etc/hosts
curl -s -X POST http://localhost:8000/payer; echo        # certificate verify failed: Hostname mismatch
getent ahostsv4 api.paiement.example | head -1           # 10.62.0.80 : toujours pas le prestataire
```

Une deuxième mauvaise adresse, et une erreur de certificat qui fait chercher du côté de TLS. Le certificat n'y est pour rien : le service parle au mauvais serveur, qui présente le sien. `dig` dit toujours 198.51.100.30. Mais pas avec la liste de recherche :

```bash
dig +short +search api.paiement.example                  # 10.62.0.80
cat /etc/resolv.conf                                     # search prod.boutique.lan boutique.lan ; options ndots:5
dig +short api.paiement.example.prod.boutique.lan        # 10.62.0.80 : le joker de la recette
```

`ndots:5` dit au résolveur : un nom qui a moins de 5 points est d'abord complété avec la liste de recherche. `api.paiement.example` n'en a que 2 : le résolveur demande d'abord `api.paiement.example.prod.boutique.lan`. Sans joker, le DNS répondrait « inconnu » et le résolveur passerait au nom tel quel. Mais le DNS interne a un joker sur `*.prod.boutique.lan`, pour les environnements de recette : il répond avec l'adresse du frontal d'accueil, et le résolveur s'arrête là. Tout nom externe à moins de 5 points est détourné de la même façon.

`ndots:5` est la valeur des pods Kubernetes, où les noms de services du cluster ont besoin de la liste de recherche. Sur un serveur, la valeur par défaut, 1, suffit : un nom qui a au moins un point est d'abord cherché tel quel, et seuls les noms courts, comme `stock`, passent par la liste de recherche.

```bash
cat > /etc/resolv.conf <<'EOF'
# Résolveur interne (modèle commun de l'équipe infra).
# Ticket #4878 : ndots:1, la valeur par défaut. Un nom qui a au moins un point est d'abord cherché tel quel ;
# seuls les noms courts (stock) passent par la liste de recherche. ndots:5 est un réglage des pods Kubernetes :
# ici, avec le joker de la recette, il détournait tous les noms externes vers le frontal d'accueil.
nameserver 10.61.0.53
search prod.boutique.lan boutique.lan
options ndots:1 timeout:1 attempts:2
EOF
getent ahostsv4 api.paiement.example | head -1           # 198.51.100.30
getent ahostsv4 stock | head -1                          # 10.63.0.21 : les noms courts marchent toujours
curl -s -X POST http://localhost:8000/payer; echo        # {"paiement": "accepté"}
```

Rien n'est figé : si le prestataire change d'adresse, le DNS la donnera, et le service suivra. Dernière étape, hors du serveur : demander à l'équipe infra de corriger son modèle commun, sinon le prochain déploiement remettra `ndots:5` sur tous les serveurs.

</details>

## Pourquoi cette approche

<details><summary>Voir la comparaison</summary>

- **Mettre la nouvelle adresse dans `/etc/hosts`** : le paiement passe aujourd'hui, jusqu'au prochain changement d'adresse du prestataire. Le check en fait l'essai.
- **Retirer la ligne `search`** : les noms externes passent, les noms courts des services internes ne résolvent plus.
- **Faire retirer le joker du DNS interne** : il appartient à l'infra, il sert la recette, et le prochain joker refera la même chose.
- **Écrire le nom avec un point final dans la configuration du service (`api.paiement.example.`)** : ce nom-là passe, mais chaque application et chaque nom doivent être corrigés, et le point final perturbe certaines vérifications de certificat.
- **Désactiver la vérification du certificat** : le service parlerait au frontal d'accueil, ou à n'importe qui d'autre.
- **Retirer l'entrée de `/etc/hosts` et revenir à `ndots:1`** : l'application obtient l'adresse que publie le prestataire, les noms courts internes marchent, et rien n'est figé.

</details>

## En prod

- `dig` n'est pas une application. Il interroge le DNS directement, sans `/etc/hosts` ni liste de recherche par défaut. Pour savoir ce qu'obtient un service : `getent ahosts <nom>`, ou `dig +search` pour la partie DNS.
- `/etc/nsswitch.conf` décide de l'ordre : en général `files dns`. Une entrée de `/etc/hosts` cache tout changement fait dans le DNS.
- Une entrée « temporaire » dans `/etc/hosts` mérite une date, un propriétaire et un ticket de retrait.
- `ndots` est un réglage de Kubernetes. Sur un serveur, garder la valeur par défaut (1) : sinon, chaque nom externe passe d'abord par la liste de recherche, ce qui coûte des requêtes, et devient dangereux dès qu'un joker existe dans un domaine de recherche.
- Un joker DNS dans un domaine de la liste de recherche capte tous les noms qui y passent : à éviter, ou à sortir de la liste de recherche.
