# linux-doctor

[![CI](https://github.com/Adieali/linux-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/Adieali/linux-doctor/actions/workflows/ci.yml)

Des incidents de production Linux, de niveau senior, à résoudre depuis ton terminal.

Chaque scénario démarre un vrai serveur Debian (systemd, nginx, cron) dans un conteneur et y reproduit un incident tiré de cas réels en entreprise : plusieurs symptômes, des fausses pistes, des contraintes de production. Tu reçois le ticket, tu diagnostiques, tu répares, puis un script vérifie le résultat. Il refuse aussi les réparations rapides qui créent un autre problème.

Le projet avance sous forme de défi : un nouvel incident chaque jour pendant 30 jours, à partir du 2 novembre 2026. Chaque scénario explique aussi ce que la panne coûte à l'entreprise, ce qui peut mal tourner pendant l'intervention, et pourquoi la réparation proposée vaut mieux que les réflexes habituels.

## Démarrage

Prérequis : Docker et bash. Testé sous Linux et sous WSL 2 ; macOS avec Docker Desktop devrait fonctionner, sans garantie.

```bash
git clone https://github.com/Adieali/linux-doctor.git
cd linux-doctor
./doctor list
./doctor start 01    # prépare l'incident et ouvre un shell root sur le serveur
./doctor check 01    # vérifie ta réparation
./doctor stop 01     # supprime le serveur
```

`./doctor shell 01` rouvre un shell sur le serveur si tu l'as quitté avant d'avoir fini.

## Scénarios

| # | Incident | Notions |
|---|---|---|
| [01](scenarios/01-disque-plein-inexplique) | Le disque est plein, et rien ne l'explique | `df`, `du`, `lsof`, `findmnt`, unités systemd |
| [02](scenarios/02-chaque-rotation-remplit-le-disque) | Chaque rotation de logs remplit un peu plus le disque | `logrotate`, `ls -s`, `du`, `/proc`, unités systemd |
| [03](scenarios/03-cinq-secondes-pile) | Certaines requêtes prennent 5 secondes pile | `curl -w`, `strace`, `dig`, `tcpdump`, DHCP |

Le README de chaque scénario contient le ticket, l'impact business, les enjeux de l'intervention, des indices, la démarche commentée, la comparaison avec les autres réparations possibles et ce qu'il faut mettre en place en prod pour que l'incident ne revienne pas. Ne lis pas `break.sh` avant d'avoir joué : c'est lui qui crée la panne.

## Bon à savoir

Le conteneur tourne avec `--privileged` : systemd en a besoin sous Docker, et les scénarios montent des systèmes de fichiers. C'est un labo, lance-le sur ton poste et pas sur un serveur partagé.

Les solutions publiées sont vérifiées. À chaque push, la CI rejoue chaque scénario avec `tests/scenarios.sh` : la panne s'installe, le check doit la refuser, puis les commandes de la démarche commentée sont exécutées telles qu'elles sont écrites, et le check doit les accepter.

Licence MIT.
