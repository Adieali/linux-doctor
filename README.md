# linux-doctor

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

## Bon à savoir

Le conteneur tourne avec `--privileged` : systemd en a besoin sous Docker, et les scénarios montent des systèmes de fichiers. C'est un labo, lance-le sur ton poste et pas sur un serveur partagé.

Licence MIT.
