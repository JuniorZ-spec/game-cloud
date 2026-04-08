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

| Service | Stack | Port interne | Stockage |
| --- | --- | --- | --- |
| `frontend` | Nginx + HTML/JS | `80` | Aucun |
| `auth-api` | Flask | `5001` | PostgreSQL |
| `pendu-api` | Flask | `5002` | Redis |
| `quiz-api` | Express | `3001` | Aucun |
| `puissance4-api` | Flask | `5003` | Redis |
| `memory-api` | Express | `3002` | Redis |
| `score-api` | Express | `3003` | PostgreSQL |

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
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
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
