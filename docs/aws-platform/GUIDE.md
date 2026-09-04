# GameCloud → Plateforme AWS EKS — Guide de reproduction

`game-cloud` était un TP pédagogique déployé sur un cluster Kind local, éphémère, sans
CI/CD. Ce document construit une vraie plateforme cloud AWS autour de cette application —
VPC/EKS privé, CI/CD GitOps, réseau, identités, observabilité, scaling — où GameCloud
n'est qu'une "app passagère" : la plateforme elle-même est la valeur démontrée, pensée
pour être réutilisable avec n'importe quelle autre application.

Chaque section explique **ce qu'on construit et pourquoi**, avec les fichiers concernés,
la commande exacte, et une vérification réelle (pas "ça devrait marcher"). Suivre ce
document dans l'ordre permet de reproduire exactement le travail fait.

---

## Phase 0 — Garde-fous

Avant de toucher à la moindre ressource AWS payante, on pose deux protections gratuites.

### Alerte budget

Un "AWS Budget" surveille automatiquement la facturation du compte et envoie un email
quand un seuil est franchi — ni plus ni moins qu'une alarme, il ne bloque rien tout seul
et ne coûte rien. Budget réel disponible pour tout le projet : ~26$. Seuil d'alerte fixé
à **20$** pour garder une marge de sécurité, avec trois notifications par email :
dépense réelle > 80%, dépense réelle > 100%, et dépense **prévisionnelle** de fin de mois
> 100% (une alerte précoce, avant même d'avoir réellement dépensé, si la trajectoire de
consommation le laisse prévoir).

```bash
aws budgets create-budget --account-id 915993062361 \
  --budget file://budget.json \
  --notifications-with-subscribers file://notifications.json
```

`budget.json` : `{ "BudgetName": "gamecloud-aws-platform", "BudgetLimit": {"Amount": "20", "Unit": "USD"}, "TimeUnit": "MONTHLY", "BudgetType": "COST" }`

`notifications.json` : 3 blocs `{Notification: {NotificationType, ComparisonOperator: GREATER_THAN, Threshold, ThresholdType: PERCENTAGE}, Subscribers: [{SubscriptionType: EMAIL, Address}]}` — seuils 80 (ACTUAL), 100 (ACTUAL), 100 (FORECASTED).

**Vérifier** : `aws budgets describe-budget --account-id 915993062361 --budget-name gamecloud-aws-platform` → `BudgetLimit.Amount` = `20.0`

### Protection du futur state Terraform

Terraform va bientôt générer un fichier `.tfstate` (la "mémoire" de ce qu'il a créé sur
AWS — sans lui, Terraform ne sait plus ce qui existe déjà) et un dossier `.terraform/`
(cache de plugins, plusieurs centaines de Mo). Les deux sont exclus de Git avant même
d'écrire le premier fichier `.tf`, car le state peut exposer des données sensibles en
clair. Le `.gitignore` racine reçoit :

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
crash.*.log
```

Note : `.terraform.lock.hcl` n'est **pas** ignoré — Terraform recommande de le committer,
il fixe les versions exactes des providers (comme un `package-lock.json`).

**Statut** : ✅ Fait. Coût : 0$.

---

## Phase 1 — Terraform : VPC + EKS privé + bastion

### 1a. Bootstrap : où Terraform stocke sa mémoire

Terraform compare en permanence ses fichiers `.tf` (ce qu'on veut) à son state (ce qui
existe réellement) pour savoir quoi créer, modifier ou détruire. Garder ce state
seulement en local est risqué : le perdre fait "oublier" à Terraform tout ce qu'il a créé
(des ressources continueraient de tourner et de coûter sans qu'on sache comment les
retrouver), et deux exécutions simultanées pourraient corrompre le fichier faute de
verrou. Solution standard : un **bucket S3** (stockage versionné et chiffré, avec
historique si une version se corrompt) + une **table DynamoDB** (un verrou empêchant deux
`terraform apply` de s'exécuter en même temps).

Ce petit module garde volontairement son propre state **en local** : il crée lui-même le
bucket qui servira de backend à tout le reste, impossible d'y stocker sa propre mémoire
avant que ce bucket existe (problème classique de l'œuf et la poule).

**Fichiers** : `infra/terraform/bootstrap/{main,variables,outputs}.tf`

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply -auto-approve
```

**Vérifier** :
```bash
aws s3api head-bucket --bucket gamecloud-tfstate-915993062361-euw3
aws dynamodb describe-table --table-name gamecloud-tfstate-lock --query Table.TableStatus
```
→ bucket accessible, table `ACTIVE`

### 1b. VPC : le réseau privé isolé

Le VPC est le réseau qui contient tout le cluster — comme un quartier fermé dont on
contrôle chaque entrée/sortie. On répartit sur **3 zones de disponibilité** (3 data
centers physiquement séparés, pour la résilience) avec deux types de sous-réseaux :
**publics** (accessibles depuis Internet — pour le bastion et le futur ALB) et
**privés** (jamais joignables directement depuis l'extérieur — pour les nœuds EKS). Une
seule **NAT Gateway** (au lieu d'une par AZ) permet aux machines privées de sortir vers
Internet (tirer une image Docker, appeler une API AWS) sans être elles-mêmes exposées —
un choix d'économie assumé pour ce projet démo, au prix d'un point de défaillance unique
sur la sortie réseau. Les subnets reçoivent dès maintenant les tags
`kubernetes.io/cluster/<nom>` et `role/elb` / `internal-elb`, pour qu'EKS et l'AWS Load
Balancer Controller (phase 5) les découvrent automatiquement sans configuration
manuelle plus tard.

**Fichiers** : `infra/terraform/modules/vpc/`, branché dans `infra/terraform/{backend,providers,variables,main,outputs}.tf` (state distant, bucket du bootstrap).

```bash
cd infra/terraform
terraform init && terraform apply -auto-approve
```

**Vérifier** :
```bash
aws ec2 describe-vpcs --vpc-ids <id> --query "Vpcs[0].State"
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=<id>" --query "NatGateways[0].State"
```
→ `available` / `available`

### 1c. EKS privé : le cluster Kubernetes managé

Le cluster EKS avec son API **totalement inaccessible depuis Internet**
(`endpoint_public_access = false`, `endpoint_private_access = true`) : seul le bastion,
depuis l'intérieur du VPC, pourra lui parler. En plus du cluster lui-même (avec son rôle
IAM), un **node group** managé fournit les machines EC2 qui exécutent réellement les
pods, placées uniquement dans les subnets privés. Un **fournisseur OIDC** est posé ici
sans être encore utilisé — c'est la fondation technique d'IRSA (phase 6), qui permettra
plus tard à un rôle IAM de faire confiance aux tokens émis par ce cluster précis, sans
qu'aucune clé AWS ne soit jamais stockée dans un pod.

**Fichiers** : `infra/terraform/modules/eks/`

**Incident réel** : le node group est resté bloqué 33 minutes en `CREATE_FAILED`
(diagnostiqué via `aws autoscaling describe-scaling-activities --auto-scaling-group-name
<asg>`, pas juste en attendant Terraform). Cause : `t3.medium` refusé — ce compte AWS
restreint les instances EC2 aux types **éligibles Free Tier uniquement** (probable
protection sur un compte récent). Types réellement disponibles obtenus via `aws ec2
describe-instance-types --filters "Name=free-tier-eligible,Values=true"` :
`t3.micro/small`, `t4g.micro/small`, `c7i-flex.large`, `m7i-flex.large`. Choix retenu :
**`m7i-flex.large`** (8 Go RAM/2 vCPU) plutôt qu'un type plus petit — nécessaire pour
avoir de la marge une fois Prometheus/Elasticsearch/7 microservices/ArgoCD déployés sur
les mêmes nœuds (phases 3 et 7).

```bash
terraform apply -auto-approve
```

**Vérifier** :
```bash
aws eks describe-cluster --name gamecloud-eks --query "cluster.{Status:status,Public:resourcesVpcConfig.endpointPublicAccess}"
aws eks describe-nodegroup --cluster-name gamecloud-eks --nodegroup-name gamecloud-eks-main --query "nodegroup.{Status:status,Health:health}"
```
→ `ACTIVE` / `false` (accès public bien désactivé) — `ACTIVE` / aucune anomalie

**Preuve de l'isolation réseau** (le point le plus important de cette phase) : depuis le
PC local, `aws eks update-kubeconfig --name gamecloud-eks --region eu-west-3` puis
`kubectl get nodes` → **timeout**. Le kubeconfig est valide, les credentials AWS aussi,
mais l'API Kubernetes est physiquement injoignable depuis l'extérieur du VPC — la preuve
concrète que le paramètre fonctionne réellement, pas juste déclaré.

### 1d. Bastion : la seule porte d'entrée

La seule machine autorisée à parler au cluster. Accès via **AWS SSM Session Manager**
plutôt que SSH classique : aucun port ouvert, aucune paire de clés à gérer ou perdre —
l'agent SSM installé sur la machine se connecte lui-même en sortant vers AWS, jamais
l'inverse, donc pas besoin d'ouvrir la moindre entrée. Trois autorisations
**indépendantes** sont nécessaires pour que l'accès fonctionne réellement, et c'est un
point qui mérite d'être bien compris : IAM (le rôle du bastion a le droit d'appeler
l'API AWS EKS), RBAC Kubernetes (`aws_eks_access_entry` +
`aws_eks_access_policy_association` donnent au rôle IAM des droits sur les objets K8s
eux-mêmes — IAM et RBAC Kubernetes sont deux systèmes de permissions séparés sur EKS), et
réseau (le security group du control plane doit explicitement accepter le trafic venant
du security group du bastion).

**Fichiers** : `infra/terraform/modules/bastion/`, ressources d'accès dans `infra/terraform/main.tf`.

**Incident réel** : premier test `kubectl get nodes` depuis le bastion → `dial tcp
...:443: i/o timeout`, alors qu'IAM et RBAC étaient pourtant corrects. Cause : le
security group **auto-géré par EKS** pour le control plane n'autorise par défaut que le
trafic de ses propres nœuds, pas celui d'un security group externe comme celui du
bastion. Corrigé avec une règle `aws_security_group_rule` explicite (port 443, source =
SG du bastion). Bonne illustration que IAM + RBAC Kubernetes + réseau sont 3 couches
d'autorisation vraiment indépendantes sur AWS/EKS — il faut les trois.

```bash
terraform apply -auto-approve
```

**Vérifier** (le test qui compte vraiment) :
```bash
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters 'commands=["su - ec2-user -c \"kubectl get nodes\""]'
aws ssm get-command-invocation --command-id <id> --instance-id <id> --query StandardOutputContent
```
→ les 2 nœuds `Ready`, vus **depuis le bastion**, à l'intérieur du VPC — combiné à
l'échec confirmé plus haut depuis le PC local, c'est la preuve complète du schéma
"accès privé uniquement via bastion".

### Coût Phase 1 (tout allumé, en continu)

| Ressource | ~$/heure |
|---|---|
| EKS control plane | 0,10$ |
| 2× m7i-flex.large (nœuds) | 0,22$ |
| NAT Gateway | 0,05$ |
| Bastion t3.micro | 0,01$ |
| **Total** | **~0,38$/h** |

**Statut** : ✅ Phase 1 complète et vérifiée, incidents réels inclus.

---

## Phase 2 — CI GitHub Actions

### ECR + pont de confiance GitHub ↔ AWS

**ECR** est l'équivalent AWS de Docker Hub, mais privé : un dépôt par microservice (7 au
total), tags **immuables** (`IMMUTABLE` — un tag SHA une fois poussé ne peut jamais être
écrasé, cohérent avec le principe "un tag = un commit précis") et une règle de cycle de
vie qui ne garde que les 10 dernières images par dépôt (évite une facture de stockage qui
grossit indéfiniment).

Pour que GitHub Actions puisse pousser des images sans qu'une clé AWS secrète ne soit
jamais stockée dans le dépôt (risque de fuite), on configure un **pont de confiance
OIDC** : AWS fait confiance directement aux jetons que GitHub émet automatiquement à
chaque exécution de workflow. Le rôle IAM créé n'est assumable que par **notre repo
précis** (`repo:JuniorZ-spec/game-cloud:*`), avec des droits limités au push sur nos 7
dépôts ECR — aucun autre projet GitHub, même sur ce même compte AWS, ne peut l'utiliser.

**Fichiers** : `infra/terraform/modules/{ecr,github-oidc}/`, branchés dans `infra/terraform/main.tf`.

**Incident réel** : `aws_iam_openid_connect_provider` a échoué avec `EntityAlreadyExists`
— un fournisseur OIDC pour une URL donnée est **unique par compte AWS**, pas par projet ;
ce compte en avait déjà un, créé par un autre projet personnel (`ticketbus`). Corrigé en
remplaçant la ressource de création par une lecture (`data
"aws_iam_openid_connect_provider"`) du fournisseur existant — seul le rôle IAM du projet
reste spécifique à GameCloud.

```bash
terraform apply -auto-approve
```

**Vérifier** :
```bash
aws ecr describe-repositories --query "repositories[].repositoryName"
aws iam get-role --role-name gamecloud-github-actions-ci --query Role.AssumeRolePolicyDocument
```
→ 7 dépôts `gamecloud/*` ; trust policy scopée à `repo:JuniorZ-spec/game-cloud:*`

### Le workflow (`.github/workflows/ci.yml`)

Deux jobs enchaînés :
1. **`detect-changes`** — l'action `dorny/paths-filter` compare les fichiers modifiés
   dans le push aux chemins `services/<nom>/**`, et produit la liste des services
   réellement touchés. Si personne n'a touché à `services/`, rien ne se déclenche.
2. **`build-scan-push`** — une matrice dynamique sur cette liste (un job parallèle par
   service modifié, jamais les 7 à chaque fois) : credentials AWS temporaires obtenus via
   le pont OIDC, build de l'image Docker, scan de vulnérabilités **Trivy** (rapport
   visible dans les logs, non bloquant pour ne pas casser la CI d'un projet démo sur une
   base pas encore à jour), puis push vers ECR taguée par `${{ github.sha }}` — le SHA du
   commit exact qui a produit cette image.

**Incident réel** : premier test en conditions réelles → le job `build-scan-push` échoue
instantanément à "Set up job", avant même le checkout. Diagnostic via l'API GitHub
(`GET /repos/{repo}/check-runs/{id}/annotations`, les logs bruts nécessitent des droits
admin même sur un repo public) : `Unable to resolve action
aquasecurity/trivy-action@0.28.0, unable to find version 0.28.0`. Cause : les releases de
`trivy-action` utilisent un préfixe `v` (`v0.28.0`, pas `0.28.0`). Vérifié les tags réels
via `curl https://api.github.com/repos/aquasecurity/trivy-action/tags`, corrigé vers
`v0.36.0` (dernière version stable). Un deuxième test confirme le succès.

**Vérifié en conditions réelles** : un commit modifiant uniquement `services/auth-api/`
n'a déclenché qu'un seul job (`build-scan-push (auth-api)`), les 6 autres services non
touchés. L'image a atterri dans `gamecloud/auth-api` avec le tag
`d97bf26d8858a7913e2634b60c1d319d7155db2d` — exactement le SHA du commit qui l'a produite.
Les 6 autres dépôts ECR vérifiés vides (`aws ecr describe-images --repository-name
gamecloud/<svc> --query "length(imageDetails)"` → `0` partout sauf auth-api).

**Statut** : ✅ Phase 2 complète, testée en conditions réelles, incident inclus.

---

## Phase 3 — CD GitOps ArgoCD (Helm + Kustomize)

### Architecture retenue

Plutôt que de forcer Kustomize à composer un chart Helm local (technique fragile,
pensée pour tirer des charts *distants*, pas pour en composer un local plusieurs fois),
le choix retenu est plus standard et plus robuste : **Helm** packages l'application (un
seul chart générique `deploy/helm/game-service`, réutilisé par les 7 microservices avec
des `values` différentes), **Kustomize** gère les ressources partagées de la plateforme
(`deploy/kustomize/base` : namespace, StorageClass, Postgres, Redis), et **ArgoCD**
orchestre les deux via un **ApplicationSet** (`argocd/applicationset-services.yaml`) —
un générateur `list` de 7 entrées pilote 7 `Application` depuis le même chart. Ajouter un
8ème service (ou une toute autre app) = une ligne dans la liste + un fichier
`values-<nom>.yaml`, rien à dupliquer. C'est ce qui rend la plateforme réellement
réutilisable, pas seulement pour GameCloud.

Le Secret `gamecloud-secrets` (mots de passe DB, JWT) n'est **pas** committé dans Git —
il est créé une seule fois à la main depuis le bastion (`kubectl create secret`, valeurs
générées aléatoirement par `openssl rand`). Le kustomize base ne le référence jamais en
tant que ressource : un objet non suivi par ArgoCD n'est jamais écrasé par le self-heal.
Ça évite de reproduire l'incident de clé committée déjà documenté dans
`RETOUR_EXPERIENCE.md`.

### Fichiers

- `deploy/helm/game-service/` — chart générique (Deployment, Service, ServiceAccount,
  HPA conditionnel) + `values/values-<service>.yaml` × 7.
- `deploy/kustomize/base/` — namespace, StorageClass, Postgres, Redis (adaptés de
  `k8s/postgres` et `k8s/redis`, sans le Secret en clair).
- `argocd/app-datastores.yaml` — Application pointant sur le kustomize base.
- `argocd/applicationset-services.yaml` — ApplicationSet pilotant les 7 services.

### Installation (depuis le bastion, via SSM)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
kubectl create namespace gamecloud
kubectl create secret generic gamecloud-secrets -n gamecloud \
  --from-literal=POSTGRES_PASSWORD=$(openssl rand -hex 16) \
  --from-literal=JWT_SECRET=$(openssl rand -hex 24) ...
kubectl apply -f https://raw.githubusercontent.com/JuniorZ-spec/game-cloud/main/argocd/app-datastores.yaml
kubectl apply -f https://raw.githubusercontent.com/JuniorZ-spec/game-cloud/main/argocd/applicationset-services.yaml
```

(manifests appliqués directement depuis l'URL brute GitHub — le repo est public, pas
besoin de cloner sur le bastion)

### Trois incidents réels, en cascade (transparence)

Au premier déploiement, 6 des 7 microservices sont montés du premier coup — les vrais
problèmes étaient tous côté datastore :

1. **`postgres` bloqué en `Pending`** : `0/2 nodes are available: pod has unbound
   immediate PersistentVolumeClaims`. Cause : un cluster EKS créé via Terraform brut
   (contrairement à `eksctl`) n'installe **pas** le driver CSI EBS par défaut — sans lui,
   aucun volume ne peut être provisionné. Corrigé en ajoutant `aws_eks_addon
   "aws-ebs-csi-driver"` + un rôle IRSA dédié dans `infra/terraform/modules/eks/` (premier
   vrai usage d'IRSA du projet, en avance sur la Phase 6).
2. **PVC toujours `Pending` après le driver installé** : `no persistent volumes available
   for this claim and no storage class is set`. Le PVC ne précisait aucune
   `storageClassName` et aucune classe n'était marquée par défaut sur le cluster. Corrigé
   en ajoutant une `StorageClass gp3` explicite (`provisioner: ebs.csi.aws.com`) au
   kustomize base plutôt que de dépendre d'une classe par défaut ambiguë.
3. **`postgres` en `CrashLoopBackOff` une fois le volume monté** : `initdb: error:
   directory "/var/lib/postgresql/data" exists but is not empty` (contient un dossier
   `lost+found`, créé par le filesystem du volume EBS). Fix standard : `PGDATA` pointé
   vers un sous-dossier du point de montage (`/var/lib/postgresql/data/pgdata`).
4. **`score-api` en cascade** : plantait simplement parce que `postgres` n'était pas
   encore prêt (`ECONNREFUSED`) — résolu automatiquement une fois les 3 points ci-dessus
   corrigés, confirmé par un redémarrage du pod.

Chaque correctif a été poussé sur Git puis synchronisé (`argocd app sync --core`, mode
qui parle directement à l'API Kubernetes sans exposer l'UI ArgoCD) — jamais de `kubectl
edit` ou de correction manuelle sur le cluster qui aurait divergé de Git.

### Preuve finale

```bash
kubectl get applications -n argocd
kubectl get pods -n gamecloud
```
→ 8 `Application` (7 services + `gamecloud-datastores`) toutes `Synced`/`Healthy` ; 9
pods `Running` (7 microservices + postgres + redis).

**Statut** : ✅ Phase 3 complète, 4 incidents réels diagnostiqués et corrigés via Git
(jamais de correction manuelle sur le cluster).

---

## Phase 4 — ArgoCD Image Updater

### Objectif

Fermer la boucle : un commit de code doit finir déployé sans qu'aucune commande
manuelle ne soit tapée entre le `git push` et le pod qui tourne.

### IRSA + installation

Rôle IAM dédié (lecture seule ECR) assumable par le ServiceAccount
`argocd-image-updater`, ajouté dans `infra/terraform/modules/eks/main.tf`. Installé via
Helm (`argo/argocd-image-updater`) sur le bastion.

**Fichiers** : rôle IRSA dans `infra/terraform/modules/eks/`, config dans
`argocd/imageupdater.yaml` et annotations dans `argocd/applicationset-services.yaml`.

**Décision utilisateur** : plutôt que de créer un token GitHub (accès en écriture au
repo), le write-back se fait **côté ArgoCD** (`write-back-method: argocd`) — le tag est
écrit comme override sur l'Application via l'API Kubernetes, pas dans le fichier Git.
Compromis assumé : déploiement toujours 100% automatique, mais le tag exact déployé
n'est plus visible dans `values-*.yaml` sur Git.

### Incidents réels rencontrés et résolus (transparence — série la plus longue du projet)

1. **Architecture CRD inattendue** : la version installée (`v1.3.0`, puis vérifié
   identique en `v1.2.4`/`v1.2.2`) ne lit plus les annotations globalement — il faut une
   ressource `ImageUpdater` (CRD) explicite. Ajout de `argocd/imageupdater.yaml` avec
   `useAnnotations: true` pour réutiliser les annotations déjà posées.
2. **`no basic auth credentials` sur ECR malgré IRSA** : contrairement aux versions plus
   anciennes documentées en ligne, cette version n'a **aucun mécanisme natif** de
   détection ECR via IRSA, ni de script d'authentification externe fonctionnel (le
   `registries.conf` Helm ne se câble même pas dans le ConfigMap, et le conteneur a un
   filesystem en lecture seule qui casse `aws ecr get-login-password` par défaut).
   Résolu avec la seule option réellement supportée par la CRD : un `pullSecret`
   (Secret Kubernetes `docker-registry`, créé une fois avec un token ECR valide ~12h).
3. **Le `pullSecret` global (CR) ne suffisait pas** : en mode `useAnnotations: true`,
   les réglages globaux de la CR sont ignorés pour tout sauf la sélection des
   applications. Résolu en posant le `pullSecret` **par service**, en annotation sur
   l'ApplicationSet (`argocd-image-updater.argoproj.io/{{service}}.pull-secret`).
4. **`helm upgrade --wait` bloquait la remontée de statut SSM** indéfiniment sur les
   commandes longues (plusieurs minutes sans réponse, sans lien avec Kubernetes
   lui-même). Contourné en supprimant `--wait` et en vérifiant l'état des pods
   séparément avec des commandes courtes.

Limite connue et assumée : le token ECR du `pullSecret` expire après ~12h ; en
production, un CronJob le régénérerait périodiquement. Hors scope pour ce projet
(cluster détruit bien avant l'expiration).

### Preuve — le test qui compte

Commit modifiant uniquement `services/auth-api/Dockerfile` (SHA `329faab...`) :

```
CI (GitHub Actions) : detect-changes -> build-scan-push (auth-api uniquement) -> succes
ECR : nouvelle image gamecloud/auth-api:329faab... poussee
Image Updater (cycle suivant, ~2 min) : "images_considered=7 images_updated=1 errors=0"
                                         "Successfully updated application spec for auth-api"
ArgoCD : application auth-api re-synchronisee automatiquement
```

**Vérifier** :
```bash
kubectl get pods -n gamecloud -l app=auth-api -o jsonpath='{.items[0].spec.containers[0].image}'
kubectl get application auth-api -n argocd -o jsonpath='{.spec.source.helm.parameters}'
```
→ image du pod : `.../gamecloud/auth-api:329faab4f0ea7082646984eb65a71777163d6eaa` —
exactement le SHA du commit, sans qu'aucun `kubectl`/`argocd`/`docker push` n'ait été
tapé manuellement après le `git push` initial.

**Statut** : ✅ Phase 4 complète, chaîne bout-en-bout vérifiée en conditions réelles.

---

## Phase 5 — Réseau (Gateway API + AWS Load Balancer Controller)

### Objectif

Remplacer l'Ingress nginx (mode Kind local) par un vrai ALB public, piloté par
**Gateway API** — le standard qui succède à Ingress. Pas de nom de domaine → pas
d'external-dns, pas de certificat ACM → accès HTTP simple via le nom DNS auto-généré
par AWS.

### Installation

IRSA pour le contrôleur (policy IAM officielle du projet, téléchargée) dans
`infra/terraform/modules/eks/`. CRDs Gateway API + contrôleur installés sur le bastion :

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system -f lbc-values.yaml
```

**Fichiers** : `deploy/kustomize/base/gateway/` (GatewayClass, Gateway, HTTPRoute,
LoadBalancerConfiguration), `deploy/helm/game-service/templates/targetgroupconfiguration.yaml`.

### Incidents réels — la série la plus longue du projet (transparence)

Cette phase a révélé que **les annotations style Ingress (`alb.ingress.kubernetes.io/*`)
ne sont tout simplement pas lues sur le chemin Gateway API** de ce contrôleur — leçon
générale, pas juste des bugs isolés :

1. **`TargetGroup port is empty`** : l'annotation `target-type: ip` posée sur le Gateway,
   puis sur chaque Service, n'a aucun effet. Le vrai mécanisme est une CRD dédiée,
   **`TargetGroupConfiguration`** (`gateway.k8s.aws/v1`), liée au Service via
   `spec.targetReference`. Une par service, ajoutée au chart Helm générique.
2. **ALB créé mais en `internal-...`** malgré `scheme: internet-facing` en annotation :
   même famille de problème. Le vrai mécanisme est **`Gateway.spec.infrastructure.parametersRef`**
   pointant sur une CRD **`LoadBalancerConfiguration`** (`gateway.k8s.aws/v1`,
   `spec.scheme: internet-facing`).
3. **`TargetGroupAssociationLimit`** en changeant le scheme après coup : AWS refuse de
   réassocier les mêmes target groups à un nouveau load balancer tant que l'ancien existe.
   Résolu en supprimant le `Gateway` (ArgoCD self-heal le recrée proprement depuis Git,
   avec la bonne config dès la création — pas de changement à chaud).

### Preuve — accès public réel

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(DNSName,'gameclou')].{DNS:DNSName,State:State.Code,Scheme:Scheme}"
curl http://<dns-alb>/
curl http://<dns-alb>/api/auth/healthz
```

→ `Scheme: internet-facing`, `State: active`. La racine renvoie le HTML réel du
frontend (`<title>GameCloud - ESGIS Arcade</title>`), et chaque chemin `/api/<service>`
atteint bien son propre backend (réponses 404 distinctes — Flask pour auth-api, Express
pour score-api — confirmant le bon routage, pas juste "ça répond"). Testé depuis une
requête HTTP publique réelle, pas depuis le tunnel SSM.

**Statut** : ✅ Phase 5 complète, 3 incidents réels résolus, accès public vérifié.

---

## Pause budget (2026-09-03) — destruction complète avant une coupure de plusieurs heures

Après la Phase 5, l'utilisateur devait s'absenter plusieurs heures. Conformément à la
discipline de coût du projet (rien ne tourne sans raison entre deux sessions), tout a été
détruit :

1. Suppression du `Gateway`/`HTTPRoute` **via Git** (retrait de
   `deploy/kustomize/base/kustomization.yaml` + sync ArgoCD avec `prune`) — pas un
   `kubectl delete` direct, qui aurait été immédiatement annulé par le `selfHeal` d'ArgoCD.
   Étape obligatoire avant de couper le cluster : sans elle, l'ALB (géré par un contrôleur
   qui aurait disparu avec le cluster) serait resté orphelin et aurait continué à facturer.
2. `terraform destroy` sur `infra/terraform/` (VPC, EKS, bastion, ECR, IAM — tout sauf le
   bootstrap S3/DynamoDB, gardé pour la prochaine session).

**Incident réel** : pour corriger un detail (`force_delete` manquant sur les dépôts ECR,
qui bloquait leur suppression car non-vides), un `terraform apply` a été lancé au lieu
d'un nouveau `destroy`. **`apply` réconcilie tout l'état désiré du code** — comme le VPC/
EKS/bastion étaient toujours définis dans les fichiers `.tf` (seulement absents du state
après le destroy), `apply` les a **entièrement recréés**. Erreur corrigée immédiatement
par un second `terraform destroy`. Leçon retenue : après un destroy volontaire, ne plus
jamais lancer `apply` pour un correctif mineur — soit `destroy -target=...` ciblé, soit
corriger puis `destroy` à nouveau, jamais `apply`.

**Vérification finale** (lecture seule, tout confirmé vide) :
```bash
aws eks list-clusters
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=gamecloud-vpc"
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending"
aws ec2 describe-nat-gateways --filter "Name=state,Values=available,pending"
aws elbv2 describe-load-balancers
aws ecr describe-repositories
terraform state list   # vide
```
→ 0 partout. Coût réel après cette pause : **0$/h**. Le bucket S3 + la table DynamoDB du
bootstrap restent (quelques centimes/mois), ainsi que tout le code sur GitHub — la
prochaine session repart avec `terraform apply` (VPC+EKS+bastion, ~15-20 min) puis
réinstallation des outils in-cluster (ArgoCD, Image Updater, Gateway API, contrôleur ALB —
commandes déjà documentées ci-dessus, aucun des incidents déjà résolus ne devrait se
reproduire puisque les correctifs sont dans le code Git).

### Reconstruction confirmée (même jour, quelques heures plus tard)

Prédiction vérifiée : `terraform apply` (VPC+EKS+bastion+ECR+IAM, 59 ressources) puis
réinstallation des outils in-cluster (ArgoCD, CRDs Gateway API, contrôleur ALB, Image
Updater) — **aucun des incidents précédents ne s'est reproduit** (EBS CSI, StorageClass,
PGDATA, TargetGroupConfiguration, LoadBalancerConfiguration, pull-secret par service :
tous fonctionnels du premier coup, correctifs déjà dans le code). Seule action manuelle
nécessaire : les dépôts ECR étant repartis vides, un nouveau build CI a été déclenché et
les fichiers `values-*.yaml` mis à jour avec le nouveau tag avant le premier sync ArgoCD.
8 Applications `Synced`/`Healthy`, 9 pods `Running`, nouvel ALB public actif et vérifié
par `curl` en moins de 30 minutes au total.

---

## Phase 6 — Identités (IRSA + Pod Identity)

### Objectif

Démontrer les deux mécanismes d'identité AWS pour des pods Kubernetes, sans jamais
stocker de clé AWS statique dans le cluster.

### IRSA — déjà largement utilisé

IRSA (IAM Roles for Service Accounts) est le mécanisme utilisé depuis la Phase 1 pour
**EBS CSI driver**, **AWS Load Balancer Controller**, et **ArgoCD Image Updater** —
chaque pod obtient un rôle IAM via un jeton OIDC fédéré (le fournisseur OIDC du cluster,
posé dès la Phase 1). Fonctionnement prouvé indirectement mais concrètement à chaque
phase précédente : l'EBS CSI driver crée de vrais volumes, l'ALB Controller crée de
vrais load balancers, l'Image Updater lit vraiment ECR — aucun n'aurait fonctionné sans
IRSA opérationnel.

### Pod Identity — nouveau mécanisme, démontré sur un composant dédié

Plus récent qu'IRSA, plus simple : pas de fédération OIDC, juste une "association"
namespace + ServiceAccount → rôle IAM, gérée par un agent (add-on EKS
`eks-pod-identity-agent`).

**Fichiers** : `infra/terraform/modules/eks/main.tf` (addon + rôle IAM + association
`aws_eks_pod_identity_association`), `deploy/kustomize/base/pod-identity-demo-sa.yaml`
(ServiceAccount `pod-identity-demo`, **sans aucune annotation** — contrairement à IRSA,
c'est justement la différence clé : l'association vit côté AWS, pas dans une annotation
Kubernetes).

### Preuve — comparaison directe des deux mécanismes

Pod jetable avec le ServiceAccount `pod-identity-demo` :
```bash
kubectl run pod-identity-test -n gamecloud --image=public.ecr.aws/aws-cli/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"pod-identity-demo"}}' --command -- sleep 300
kubectl exec pod-identity-test -n gamecloud -- aws sts get-caller-identity
```
→ `Arn: arn:aws:sts::915993062361:assumed-role/gamecloud-eks-pod-identity-demo/...` —
rôle IAM assumé sans aucune clé, aucun secret monté dans le pod.

**Comparaison des variables d'environnement injectées automatiquement**, qui prouve que
ce sont bien deux mécanismes distincts, pas juste deux noms pour la même chose :

| | IRSA (pod Image Updater) | Pod Identity (pod de démo) |
|---|---|---|
| Variables clé | `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` | `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` |
| Chemin du token | `/var/run/secrets/**eks.amazonaws.com**/serviceaccount/token` | `/var/run/secrets/**pods.eks.amazonaws.com**/serviceaccount/...` |
| Mécanisme | Fédération OIDC (JWT vérifié par IAM) | Agent local (`169.254.170.23`), pas d'OIDC |

Pod de test supprimé après vérification (`kubectl delete pod pod-identity-test`) —
ressource jetable, pas de coût résiduel.

**Statut** : ✅ Phase 6 complète — IRSA prouvé fonctionnel via 3 composants réels
(EBS CSI, ALB Controller, Image Updater), Pod Identity prouvé via un composant dédié
avec comparaison directe des deux mécanismes.

---

## Pause budget #2 (2026-09-03, même jour) — après la Phase 6

Même procédure que la première pause : retrait du Gateway/HTTPRoute de Git + sync
ArgoCD avec `prune`, puis `terraform destroy`.

**Incident réel** : le Gateway est resté bloqué en suppression quelques dizaines de
secondes — `failed to delete securityGroup: ... DependencyViolation: resource
sg-... has a dependent object`. Cause classique : latence de cohérence AWS le temps que
les ENI/règles réseau associées au security group managé du LB se détachent
complètement avant que le security group lui-même puisse être supprimé. S'est résolu
tout seul après un court délai (aucune action requise) — noter que **ce n'est pas une
erreur bloquante**, juste une question de patience de quelques dizaines de secondes
avant `terraform destroy`.

`terraform destroy` a ensuite réussi du premier coup (63 ressources, 0 erreur) — le
`force_delete` sur ECR ajouté après le premier teardown a fonctionné directement,
aucune correction en urgence nécessaire cette fois. Vérification finale identique à la
première pause : tout confirmé à 0 (EKS, VPC, instances, NAT, ALB, ECR, state Terraform
vide).

---

## Reconstruction #2 (2026-09-04) — incident de verrou d'état Terraform

Même procédure de reconstruction que la première fois (`terraform apply` + réinstallation
des outils + rebuild CI + mise à jour des tags). Un service (`quiz-api`) a échoué au
premier essai CI avec une erreur de permission ECR — propagation IAM pas encore
terminée juste après la recréation du rôle `gamecloud-github-actions-ci`, résolu par un
simple nouveau commit déclenchant uniquement ce service.

**Incident réel plus sérieux** : `terraform apply` a réussi à créer les 63 ressources
mais a échoué en relâchant le verrou d'état (`Error releasing the state lock: ...
unexpected end of JSON input`). Le verrou est resté bloqué dans la table DynamoDB, et
même `terraform force-unlock` échouait avec la même erreur de parsing — ce backend de
verrouillage (déjà signalé comme déprécié en Phase 1, `use_lockfile` recommandé à la
place) semble avoir un vrai bug de corruption occasionnel. Résolu en supprimant
directement l'entrée bloquée via `aws dynamodb delete-item` (sûr après avoir confirmé
via `aws dynamodb scan` qu'il s'agissait bien de notre propre verrou). Un deuxième
verrou corrompu est réapparu au `terraform plan` suivant — même traitement, puis
`-lock=false` utilisé pour le reste de la session (acceptable en solo, à éviter en
équipe). **Piste pour la suite** : migrer vers `use_lockfile = true` (verrouillage natif
S3, sans DynamoDB) pour éliminer cette classe de bug.

Reconstruction complète confirmée : 8 Applications `Synced`/`Healthy`, 9 pods `Running`,
nouvel ALB public vérifié par `curl`.

---

## Phases suivantes (à venir)

- Phase 7 — Observabilité (kube-prometheus-stack + EFK/ECK)
- Phase 8 — Scaling (HPA + générateur de charge)
- Phase 9 — Documentation finale + destruction complète
