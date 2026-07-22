# Retour d'experience - Apprendre le DevOps avec GameCloud

## Contexte

GameCloud est une plateforme d'arcade multi-jeux (Pendu, Quiz, Puissance 4, Memory)
construite en microservices (Flask + Express), deployee sur un cluster Kubernetes
local (Kind) derriere un Ingress Nginx, avec Postgres et Redis comme dependances
stateful. L'extension KEDA ajoute du scale-to-zero sur `score-api`.

Ce document rassemble les problemes reellement rencontres pendant la construction
du projet, et ce qu'ils ont appris sur le fonctionnement de Kubernetes en pratique -
pas seulement en theorie.

## 1. Le DNS interne Kubernetes n'est pas magique

**Symptome** : des 502 intermittents sur les appels API depuis le frontend, sans
cause evidente dans les logs applicatifs.

**Avant** (`services/frontend/nginx.conf`) :

```nginx
location /api/auth/ {
  proxy_pass http://auth-api:5001/;
}
```

Nginx resout le nom une seule fois au demarrage du conteneur et met l'IP en cache.
Si le pod backend redemarre (nouvelle IP, ce qui arrive tres souvent dans un
Deployment K8s), Nginx continue de taper l'ancienne IP jusqu'a son propre
redemarrage.

**Apres** :

```nginx
resolver kube-dns.kube-system.svc.cluster.local valid=5s;

location /api/auth/ {
  set $upstream http://auth-service.gamecloud.svc.cluster.local;
  proxy_pass $upstream/;
}
```

Le `set $upstream` force Nginx a re-resoudre le nom via le `resolver` declare,
au lieu de figer l'IP a la compilation de la configuration. Le FQDN complet
(`service.namespace.svc.cluster.local`) est aussi plus fiable que le nom court
en environnement multi-namespace.

**Lecon** : le DNS interne K8s change constamment (redemarrages, scaling,
rolling updates). Un reverse proxy doit etre configure pour re-resoudre, pas
pour resoudre une seule fois.

## 2. Des probes mal calibrees tuent des pods sains

**Symptome** : `CrashLoopBackOff` sur `auth-api` et `score-api` alors que les
services fonctionnaient correctement une fois demarres.

**Avant** (`k8s/auth/deployment.yaml`) :

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 5001
  initialDelaySeconds: 30
  periodSeconds: 10
```

Sans `failureThreshold` explicite, Kubernetes applique la valeur par defaut (3).
Trois echecs consecutifs de la liveness probe suffisaient a faire tuer le pod,
meme quand le retard venait simplement d'une dependance (connexion Postgres)
pas encore prete.

**Apres** :

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 5001
  initialDelaySeconds: 40
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
```

**Lecon** : `readinessProbe` et `livenessProbe` doivent etre calibrees sur le
temps de demarrage reel du service (connexions DB, chargement de donnees),
pas sur des valeurs par defaut copiees d'un tutoriel. `kubectl describe pod`
et `kubectl logs --previous` sont les premiers reflexes face a un
CrashLoopBackOff.

## 3. Un contrat d'API rompu entre services

**Symptome** : crash du frontend au chargement du jeu Memory.

**Avant** (`services/memory-api/server.js`) :

```js
res.status(201).json({
  id: sessionId,
  total_cards: session.cards.length,
  found: session.found
});
```

Le backend renvoyait un sous-ensemble de l'objet session. Le frontend, lui,
attendait l'objet complet (notamment `session.cards`) et plantait des la
reception d'une reponse partielle.

**Apres** :

```js
res.status(201).json(session);
```

**Lecon** : dans une architecture microservices, modifier la forme d'une
reponse API sans verifier tous les consommateurs casse silencieusement le
frontend. Ce genre de bug ne remonte pas dans les logs backend (le endpoint
repond 201 sans erreur) - seul le frontend explose.

## 4. L'ordre des regles d'Ingress compte

**Symptome** : les routes `/api/*` etaient parfois interceptees par la regle
catch-all du frontend.

**Avant** (`k8s/ingress/ingress-keda.yaml`) : la regle `path: /(/|$)(.*)`
(frontend) etait declaree en premier, avant les regles `/api/scores`,
`/api/quiz`, etc.

**Apres** : la regle catch-all est deplacee en derniere position.

**Lecon** : un Ingress Nginx evalue les regles dans l'ordre du manifest. Les
routes catch-all (`/`) doivent toujours etre placees en dernier, sinon elles
absorbent des requetes destinees a des routes plus specifiques.

## 5. Le scale-to-zero KEDA ne fonctionne pas sans intercepteur

`k8s/scores/scaled-object.yaml` declare un `HTTPScaledObject` avec
`min: 0, max: 5, scaledownPeriod: 120` : apres 120 secondes sans requete,
KEDA supprime le dernier pod `score-api`.

Le trafic ne va pas directement au service `score-api`. L'Ingress route
`/api/scores` vers `keda-add-ons-http-interceptor-proxy`
(`k8s/ingress/keda-interceptor-svc.yaml`, un `Service` de type `ExternalName`
pointant vers le namespace `keda`). C'est cet intercepteur qui :

1. retient la requete entrante quand 0 pod est disponible,
2. declenche le scale-up de 0 vers 1 replica,
3. attend que le pod soit `Ready`,
4. relaie enfin la requete.

**Lecon** : le scale-to-zero HTTP n'est pas une fonctionnalite native de
Kubernetes. Il repose sur un composant intermediaire (l'intercepteur KEDA)
qui bufferise la requete pendant le cold start. Sans cet intercepteur, la
premiere requete apres une periode d'inactivite echouerait purement et
simplement.

## 6. Un secret commite reste expose meme apres suppression

Une cle Supabase (`SUPABASE_KEY`) a ete codee en dur dans
`k8s/quiz/deployment.yaml` et poussee sur un depot GitHub public. La retirer
du fichier dans un commit ulterieur ne suffit pas : elle restait visible dans
l'historique Git tant que la cle n'etait pas revoquee cote Supabase.

**Lecon** : les identifiants ne doivent jamais apparaitre en clair dans un
manifest versionne. Un `Secret` Kubernetes (ou une variable d'environnement
injectee au runtime, hors du depot) est la seule option correcte. Et en cas
de fuite, la revocation de la cle est la seule mesure qui compte reellement -
supprimer le fichier ne fait que masquer le probleme dans le present, pas
dans l'historique.

## Ce que ce projet a permis d'apprendre concretement

- Lire un `kubectl describe pod` / `kubectl logs --previous` pour diagnostiquer
  un CrashLoopBackOff plutot que de deviner.
- Calibrer des probes Kubernetes sur le comportement reel d'un service, pas
  sur des valeurs par defaut.
- Comprendre pourquoi le DNS interne K8s exige une resolution active (`resolver`)
  et non une resolution figee au demarrage.
- Voir concretement comment KEDA implemente le scale-to-zero HTTP via un
  intercepteur, et pourquoi ce composant est indispensable.
- Traiter la gestion des secrets comme une contrainte non negociable des le
  premier commit, pas comme un correctif a posteriori.
