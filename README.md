# GameCloud ESGIS

Depot du TP complet `GameCloud` pour le cours de virtualisation cloud et data center, avec la partie de base Kubernetes puis l'extension `KEDA` pour le scale-to-zero.

Le depot suit maintenant la meme logique pedagogique que le support diffuse sur ESGIS CAMPUS:

1. Construire la plateforme multi-jeux GameCloud
2. La deployer sur Kind avec Kubernetes
3. Valider les flux applicatifs
4. Etendre `score-api` avec KEDA pour le comportement serverless

## Structure

```text
cluster/
  kind-config.yaml
docs/
  TP_GAMECLOUD_COMPLET.md
  TP_GAMECLOUD_KEDA.md
k8s/
  namespace.yaml
  postgres/
  redis/
  auth/
  pendu/
  quiz/
  puissance4/
  memory/
  scores/
  frontend/
  ingress/
scripts/
  build-and-load.sh
  deploy-gamecloud.sh
  install-keda.sh
  test-gamecloud.sh
  test-keda.sh
services/
  frontend/
  auth-api/
  pendu-api/
  quiz-api/
  puissance4-api/
  memory-api/
  score-api/
```

## Services

| `frontend` | Nginx + HTML/JS Arcade | `80` | Aucun (UI Interactive) |
| `auth-api` | Flask (JWT) | `5001` | PostgreSQL |
| `pendu-api` | Flask (Jeu) | `5002` | Redis |
| `quiz-api` | Express (Questions) | `3001` | Aucun |
| `puissance4-api` | Flask (IA) | `5003` | Redis |
| `memory-api` | Express (Session) | `3002` | Redis |
| `score-api` | Express (KEDA ready) | `3003` | PostgreSQL |

## Fonctionnalites de l'Arcade

L'interface frontend (`http://gamecloud.local`) propose :

- **Système de Login/Invité** : Jouez immédiatement ou créez un compte pour le classement.
- **4 Mini-jeux interactifs** : Pendu, Quiz, Puissance 4 (avec IA) et Memory.
- **Leaderboard Global** : Suivez les meilleurs scores en temps réel.
- **Monitoring Santé** : Dashboard d'état des micro-services intégré.

## Demarrage rapide

### 1. Creer le cluster Kind

```bash
kind create cluster --config cluster/kind-config.yaml
```

### 2. Construire et charger les images dans Kind

```bash
./scripts/build-and-load.sh
```

### 3. Installer l'Ingress NGINX

```bash
./scripts/install-ingress-nginx-kind.sh
```

### 4. Deployer GameCloud

```bash
./scripts/deploy-gamecloud.sh
```

### 5. Declarer le host local

```bash
echo "127.0.0.1 gamecloud.local" | sudo tee -a /etc/hosts
```

### 6. Verifier la plateforme

```bash
./scripts/test-gamecloud.sh
```

Si le port hote `80` est deja pris et que vous avez adapte `cluster/kind-config.yaml`
vers un autre port (par exemple `8081`), vous pouvez verifier via:

```bash
BASE_URL=http://gamecloud.local:8081 \
CURL_RESOLVE=gamecloud.local:8081:127.0.0.1 \
./scripts/test-gamecloud.sh
```

Le frontend sera ensuite disponible sur `http://gamecloud.local`.

## Extension KEDA

Quand la plateforme de base fonctionne, la partie serverless se lance avec:

```bash
./scripts/install-keda.sh
kubectl apply -f k8s/scores/scaled-object.yaml
kubectl apply -f k8s/ingress/ingress-keda.yaml
./scripts/test-keda.sh
```

## Documentation du TP

- [TP complet GameCloud](docs/TP_GAMECLOUD_COMPLET.md)
- [TP KEDA et scale-to-zero](docs/TP_GAMECLOUD_KEDA.md)

## Coherence avec ESGIS CAMPUS

Le support publie sur la plateforme ESGIS CAMPUS presente:

- la partie `GameCloud` de base
- puis la partie `KEDA`
- avec les memes services, ports, manifests et sequences de validation

Le README a ete remis a niveau pour refleter cette progression, et le depot contient maintenant la base technique qui manquait auparavant.
