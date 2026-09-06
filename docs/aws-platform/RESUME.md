# GameCloud — Plateforme AWS EKS — Résumé

Plateforme cloud AWS complète et réutilisable, construite autour d'une application de démo
à 7 microservices. La plateforme elle-même est le sujet — chaque brique est pensée pour
fonctionner avec n'importe quelle autre application.

![Architecture GameCloud sur AWS EKS](captures/schema.jpeg)

**Réseau privé** — VPC sur 3 zones de disponibilité, cluster EKS dont l'API n'est jamais
exposée à Internet, accès admin uniquement via un bastion SSM (zéro clé SSH, zéro port
ouvert).

**CI** — GitHub Actions : build du seul service modifié, scan de vulnérabilités Trivy, push
vers Amazon ECR taggé par SHA de commit. Authentification OIDC, zéro clé AWS stockée dans
GitHub.

**CD GitOps** — ArgoCD (auto-sync, self-heal, prune) piloté par une ApplicationSet et un
chart Helm générique. ArgoCD Image Updater ferme la boucle : un commit finit déployé sans
aucune commande manuelle entre les deux.

**Réseau applicatif** — Gateway API + AWS Load Balancer Controller exposent un Application
Load Balancer public.

**Identités — zéro clé statique** — IRSA (fédération OIDC) et EKS Pod Identity, les deux
mécanismes d'identité IAM pour Kubernetes, démontrés et comparés directement sur des
composants réels.

**Observabilité réelle** — métriques (Prometheus/Grafana) et logs (Elasticsearch/Kibana)
sur des données de production, pas des dashboards vides.

**Discipline de coût** — infrastructure provisionnée par Terraform, détruite et reconstruite
plusieurs fois pendant le build pour ne payer que le temps réellement utilisé, alerte budget
AWS en garde-fou.

Chaque brique a été vérifiée avec de vraies commandes, pas des suppositions — et chaque
incident rencontré est documenté avec sa cause exacte.

**Guide complet, commandes et incidents détaillés** : `docs/aws-platform/GUIDE.md`
([English](docs/aws-platform/GUIDE.en.md)) · Code source : github.com/JuniorZ-spec/game-cloud
