# TP GameCloud Complet

## Objectif

Construire une plateforme multi-jeux sur Kubernetes local avec:

- un frontend `Nginx` (Game Center interactif)
- cinq APIs metier
- deux stockages techniques `PostgreSQL` et `Redis`
- un routage unifie via `Ingress`

## Ordre de travail recommande

1. Creer le cluster `Kind`
2. Builder les images et les charger dans Kind
3. Deployer `namespace`, `secrets`, `postgres`, `redis`
4. Deployer les services applicatifs
5. Activer l'Ingress et tester les routes
6. Valider les flux `register -> login -> token -> score`

## Endpoints attendus

- `GET /api/auth/healthz`
- `POST /api/auth/register`
- `POST /api/auth/login`
- `GET /api/pendu/healthz`
- `POST /api/pendu/game/start`
- `POST /api/pendu/game/<id>/guess`
- `GET /api/quiz/healthz`
- `GET /api/quiz/question`
- `GET /api/p4/healthz`
- `POST /api/p4/game/start`
- `POST /api/p4/game/<id>/move`
- `GET /api/memory/healthz`
- `POST /api/memory/session/start`
- `POST /api/memory/session/<id>/flip`
- `GET /api/scores/healthz`
- `POST /api/scores/score`
- `GET /api/scores/leaderboard`

## Validation minimale

```bash
kubectl get pods -n gamecloud
curl http://gamecloud.local/api/auth/healthz
curl http://gamecloud.local/api/pendu/healthz
curl http://gamecloud.local/api/quiz/healthz
curl http://gamecloud.local/api/p4/healthz
curl http://gamecloud.local/api/memory/healthz
curl http://gamecloud.local/api/scores/healthz
```

## Flux metier attendu

1. Creer un compte via `auth-api` (depuis l'interface de connexion)
2. Recuperer un JWT via `login` (automatique lors de la connexion)
3. Jouer a un mini-jeu (Pendu, Quiz, Puissance 4 ou Memory)
4. Poster un score sur `score-api` (propose a la fin d'une partie si connecte)
5. Lire le leaderboard global

## Fichiers clefs du depot

- `cluster/kind-config.yaml`
- `k8s/namespace.yaml`
- `k8s/ingress/ingress.yaml`
- `k8s/scores/deployment.yaml`
- `services/auth-api/app.py`
- `services/score-api/server.js`
