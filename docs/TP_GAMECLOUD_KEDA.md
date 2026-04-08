# TP KEDA

## Objectif

Transformer `score-api` en service HTTP scalable avec `KEDA`, jusqu'a `0` replica en periode d'inactivite.

## Sequence

1. Installer `KEDA`
2. Conserver `score-api` comme cible de scaling
3. Declarer `HTTPScaledObject`
4. Remplacer la route `/api/scores` de l'Ingress par l'interceptor KEDA
5. Mesurer le `cold start`

## Fichiers utilises

- `scripts/install-keda.sh`
- `scripts/test-keda.sh`
- `k8s/scores/scaled-object.yaml`
- `k8s/ingress/ingress-keda.yaml`

## Verification

```bash
kubectl get pods -n keda
kubectl get httpscaledobject -n gamecloud
kubectl get deployment score-api -n gamecloud
```

## Resultat attendu

- `score-api` passe de `1` replica a `0`
- une requete HTTP sur `/api/scores/*` reveille le service
- la premiere reponse est plus lente qu'une reponse a chaud
