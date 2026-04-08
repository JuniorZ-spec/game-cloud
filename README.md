# TP GameCloud - KEDA : Scaling Serverless avec Scale-to-Zero

## 📋 Vue d'ensemble

Ce TP est un **complément avancé** du projet GameCloud. Vous allez transformer le service `score-api` en un service **serverless** qui se met à l'échelle automatiquement jusqu'à **zéro replica** quand personne ne l'utilise.

### 🎯 Objectifs pédagogiques

- Comprendre la différence entre scaling classique (HPA) et serverless (KEDA)
- Installer et configurer KEDA sur Kubernetes
- Mettre en place le pattern **scale-to-zero**
- Observer et mesurer le phénomène de **cold start**
- Prendre conscience des compromis (coût vs latence)

---

## 🔍 Comparaison : HPA vs KEDA

| Critère | HPA (Scaling classique) | KEDA (Serverless) |
|---------|------------------------|-------------------|
| **Replicas au repos** | ≥ 1 toujours actif | **0** — pod éteint |
| **Coût en idle** | CPU + RAM consommés | **Zéro** consommation |
| **1ère réponse** | Immédiate (< 5ms) | **Cold start** : 1-4s |
| **Déclencheur** | CPU / mémoire | Trafic HTTP, queue, cron... |
| **Config K8s** | Deployment + HPA | Deployment + ScaledObject |

### Architecture comparée

```
AVANT (HPA) :                           APRÈS (KEDA) :
┌─────────────┐                        ┌─────────────┐
│   Ingress   │                        │   Ingress   │
└──────┬──────┘                        └──────┬──────┘
       │                                       │
       ▼                                       ▼
┌───────────────┐                    ┌─────────────────────┐
│ score-service │                    │  KEDA Interceptor   │
└───────┬───────┘                    │  (buffer + wake-up) │
        │                            └──────────┬──────────┘
        ▼                                       │
┌───────────────┐                               │ (0 req > 2min)
│ [pod] [pod]   │ ← toujours actifs             ▼
│ 50m+50m CPU  │                    ┌─────────────────────┐
└───────────────┘                    │   scale to 0 ✓      │
                                     │   CPU: 0m           │
                                     └─────────────────────┘
```

---

## 📚 Prérequis

### Obligatoires

- Cluster **Kind** opérationnel avec le projet GameCloud (services auth, pendu, quiz, p4)
- `kubectl` configuré et fonctionnel
- **Helm** installé :
  ```bash
  # macOS
  brew install helm
  
  # Windows
  choco install kubernetes-helm
  
  # Linux
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ```

### Vérification

```bash
# Le cluster doit être accessible
kubectl cluster-info

# Les services GameCloud doivent être déployés
kubectl get pods -n gamecloud
```

---

## 🚀 Étape 1 : Installation de KEDA

### 1.1 Ajouter le repository Helm KEDA

```bash
# Ajouter le repo officiel KEDA
helm repo add kedacore https://kedacore.github.io/charts

# Mettre à jour les index
helm repo update
```

### 1.2 Installer KEDA Core

KEDA Core est l'opérateur qui gère les ressources `ScaledObject`.

```bash
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait
```

### 1.3 Installer le HTTP Add-on

Le HTTP Add-on permet le scaling basé sur le trafic HTTP (scale-to-zero).

```bash
helm install http-add-on kedacore/keda-add-ons-http \
  --namespace keda \
  --wait
```

### 1.4 Vérifier l'installation

```bash
# Vérifier que tous les pods KEDA sont Running
kubectl get pods -n keda

# Sortie attendue :
# NAME                                        READY   STATUS
# keda-operator-xxx                           1/1     Running
# keda-operator-metrics-xxx                   1/1     Running
# keda-add-ons-http-controller-xx             1/1     Running
# keda-add-ons-http-interceptor-xx            1/1     Running  ← Important !
```

### 1.5 Vérifier l'interceptor HTTP

L'interceptor est le composant magique qui bufferise les requêtes pendant le cold start :

```bash
# Lister les services KEDA
kubectl get svc -n keda | grep interceptor

# Sortie attendue :
# keda-add-ons-http-interceptor-proxy   ClusterIP   10.x.x.x   8080/TCP
#                                                               ↑
# Ce port 8080 sera utilisé dans l'Ingress
```

---

## ⚙️ Étape 2 : Préparer score-api pour KEDA

### 2.1 Supprimer l'ancien HPA (si existant)

```bash
# Supprimer le HPA si vous en aviez créé un
kubectl delete hpa score-api -n gamecloud 2>/dev/null || echo "Pas de HPA existant"

# S'assurer que le Deployment existe avec 1 replica
kubectl scale deployment score-api --replicas=1 -n gamecloud
```

### 2.2 Vérifier le Deployment score-api

Le fichier `k8s/scores/deployment.yaml` doit définir :
- Un Deployment nommé `score-api`
- Un Service nommé `score-service` (port 80)
- Des labels `app: score-api`

```bash
# Vérifier
kubectl get deployment score-api -n gamecloud
kubectl get service score-service -n gamecloud
```

---

## 🔧 Étape 3 : Créer le HTTPScaledObject

Le `HTTPScaledObject` est la ressource KEDA qui définit les règles de scaling.

### 3.1 Comprendre le manifeste

```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: score-api-serverless
  namespace: gamecloud
spec:
  hosts:
    - gamecloud.local                    # Host concerné
  
  pathPrefixes:
    - /api/scores                        # Routes à surveiller
  
  scaleTargetRef:
    name: score-api                      # Deployment cible
    service: score-service               # Service associé
    port: 80
  
  replicas:
    min: 0                               # ← Scale to ZERO !
    max: 5                               # Max 5 pods
  
  scaledownPeriod: 120                   # 2 min d'inactivité → 0 pod
```

### 3.2 Appliquer le manifeste

```bash
kubectl apply -f k8s/scores/scaled-object.yaml
```

### 3.3 Vérifier que KEDA contrôle score-api

```bash
kubectl get httpscaledobject -n gamecloud

# Sortie attendue :
# NAME                   TARGETWORKLOAD   TARGETSERVICE   MIN   MAX
# score-api-serverless   score-api        score-service   0     5
```

---

## 🌐 Étape 4 : Modifier l'Ingress

### 4.1 Comprendre le changement

**AVANT (HPA)** : Le trafic va directement au service.

```yaml
backend:
  service:
    name: score-service
    port:
      number: 80
```

**APRÈS (KEDA)** : Le trafic passe par l'interceptor KEDA.

```yaml
backend:
  service:
    name: keda-add-ons-http-interceptor-proxy
    port:
      number: 8080
```

### 4.2 Appliquer la nouvelle configuration

```bash
kubectl apply -f k8s/ingress/ingress-keda.yaml
```

### 4.3 Vérifier l'Ingress

```bash
kubectl get ingress -n gamecloud
kubectl describe ingress gamecloud-ingress -n gamecloud
```

---

## 🧪 Étape 5 : Observer le cycle de vie serverless

### 5.1 Ouvrir 3 terminaux

**Terminal 1** - Surveillance des pods :
```bash
kubectl get pods -n gamecloud -l app=score-api --watch
```

**Terminal 2** - Vérification du scaling :
```bash
# Attendre 2 minutes sans requête
kubectl get deployment score-api -n gamecloud
# READY devrait passer à 0/0
```

**Terminal 3** - Tests de requêtes :
```bash
# 1. Premier test (cold start)
time curl -s http://gamecloud.local/api/scores/leaderboard | jq .

# 2. Deuxième test (pod chaud)
time curl -s http://gamecloud.local/api/scores/leaderboard | jq .

# 3. Comparer avec quiz-api (HPA, toujours chaud)
time curl -s http://gamecloud.local/api/quiz/question | jq .
```

### 5.2 Test de charge (scale-up)

```bash
# Récupérer un token
TOKEN=$(curl -s -X POST http://gamecloud.local/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"joueur1","password":"test123"}' | jq -r .token)

# Envoyer 20 scores en parallèle
for i in {1..20}; do
  curl -s -X POST http://gamecloud.local/api/scores/score \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"game\":\"quiz\",\"score\":$((RANDOM % 1000))}" &
done
wait

# Observer le scale-up dans Terminal 1
kubectl get pods -n gamecloud -l app=score-api
```

---

## 📊 Questions de réflexion

Répondez à ces questions dans votre rapport :

1. **Quelle est la durée mesurée du cold start sur votre machine ?**
   - Comparez avec les valeurs théoriques (1-4 secondes)

2. **Un utilisateur en train de jouer au pendu remarquerait-il le cold start de score-api ?**
   - Pensez à l'UX : quand est-ce que score-api est appelé ?

3. **Quels autres services du TP pourraient bénéficier du scale-to-zero ?**
   - Analysez le pattern d'utilisation de chaque service

4. **Dans quels cas le cold start serait-il inacceptable ?**
   - Pensez aux APIs temps réel, aux transactions financières...

---

## 🏆 Points de validation (8 points bonus)

| Critère | Points |
|---------|--------|
| KEDA core + HTTP Add-on installés et Running | 2 pts |
| HTTPScaledObject créé et KEDA contrôle score-api | 2 pts |
| Démonstration du scale-to-zero (0 replica) | 2 pts |
| Mesures documentées (cold start vs chaud vs HPA) | 1 pt |
| Réponses aux 4 questions de réflexion | 1 pt |

---

## 🐛 Dépannage

### Problème : L'interceptor n'est pas créé

```bash
# Vérifier les logs du controller
kubectl logs -n keda -l app.kubernetes.io/name=keda-add-ons-http-controller
```

### Problème : Le pod ne scale pas à 0

```bash
# Vérifier le HTTPScaledObject
kubectl describe httpscaledobject score-api-serverless -n gamecloud

# Vérifier les événements KEDA
kubectl get events -n gamecloud --field-selector reason=ScaledObjectReady
```

### Problème : Cold start trop long

```bash
# Vérifier les ressources du pod
kubectl describe pod -l app=score-api -n gamecloud

# Augmenter les ressources si nécessaire dans deployment.yaml
```

---

## 📖 Ressources utiles

- [Documentation KEDA](https://keda.sh/docs/)
- [KEDA HTTP Add-on](https://github.com/kedacore/http-add-on)
- [Comprendre le cold start](https://docs.microsoft.com/azure/azure-functions/functions-scale)

---

## 📝 Résumé visuel

```
┌─────────────────────────────────────────────────────────────────┐
│                    ARCHITECTURE FINALE                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  http://gamecloud.local                                          │
│         │                                                        │
│         ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              NGINX Ingress Controller                    │    │
│  └──┬───────────┬────────────┬──────────┬────────────┬──────┘    │
│     │           │            │          │            │           │
│     ▼           ▼            ▼          ▼            ▼           │
│  Frontend    auth-api    pendu-api   quiz-api   KEDA Interceptor │
│   ×2 pods     ×2 pods      ×2 pods    ×2 pods    (buffer)        │
│     │           │            │          │            │           │
│  HPA min:2   HPA min:2   HPA min:2  HPA min:2       ▼           │
│                                                   score-api      │
│                                                   KEDA min:0     │
│                                                   max:5          │
│                                                                  │
│  ⚖️ HPA : Services critiques (jeux en cours)                    │
│  ⚡ KEDA : Services périphériques (scores, rapports)            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

**Auteur** : Floriace FAVI  
**Cours** : Master 1 - Système, Réseau et Cloud  
**Date** : 2025
