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

**Vérifier** : un push modifiant un seul service doit ne déclencher qu'un seul job dans
l'onglet Actions, et l'image doit apparaître dans son dépôt ECR avec le tag SHA
correspondant.

**Statut** : ⏳ Code écrit, test réel en attente d'un push sur le dépôt distant (GitHub
Actions ne s'exécute que sur du code effectivement poussé).

---

## Phases suivantes (à venir)

- Phase 3 — CD GitOps ArgoCD (Helm + Kustomize)
- Phase 4 — ArgoCD Image Updater
- Phase 5 — Réseau (Gateway API + AWS Load Balancer Controller)
- Phase 6 — Identités (IRSA + Pod Identity)
- Phase 7 — Observabilité (kube-prometheus-stack + EFK/ECK)
- Phase 8 — Scaling (HPA + générateur de charge)
- Phase 9 — Documentation finale + destruction complète
