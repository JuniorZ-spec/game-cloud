#!/bin/bash
# Script d'installation de KEDA pour le TP GameCloud
# Usage: ./install-keda.sh

set -e

echo "=========================================="
echo "Installation de KEDA pour GameCloud"
echo "=========================================="

# Couleurs pour les messages
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Fonction de log
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

# Vérifier les prérequis
log "Vérification des prérequis..."

if ! command -v kubectl &> /dev/null; then
    error "kubectl n'est pas installé"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    error "Helm n'est pas installé"
    echo "Installez Helm : https://helm.sh/docs/intro/install/"
    exit 1
fi

success "Prérequis OK"

# Vérifier que le cluster est accessible
log "Vérification du cluster Kubernetes..."
if ! kubectl cluster-info &> /dev/null; then
    error "Impossible de se connecter au cluster Kubernetes"
    exit 1
fi
success "Cluster Kubernetes accessible"

# Vérifier le namespace gamecloud
log "Vérification du namespace gamecloud..."
if ! kubectl get namespace gamecloud &> /dev/null; then
    error "Le namespace 'gamecloud' n'existe pas"
    echo "Assurez-vous d'avoir déployé le projet GameCloud avant ce TP"
    exit 1
fi
success "Namespace gamecloud trouvé"

# Ajouter le repo KEDA
log "Ajout du repository Helm KEDA..."
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || log "Repo déjà ajouté"
helm repo update
success "Repository KEDA ajouté"

# Installer KEDA Core
log "Installation de KEDA Core..."
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait \
  --timeout 5m

success "KEDA Core installé"

# Installer le HTTP Add-on
log "Installation du HTTP Add-on..."
helm upgrade --install http-add-on kedacore/keda-add-ons-http \
  --namespace keda \
  --wait \
  --timeout 5m

success "HTTP Add-on installé"

# Vérifier l'installation
log "Vérification de l'installation..."
echo ""
echo "Pods KEDA :"
kubectl get pods -n keda

echo ""
echo "Services KEDA :"
kubectl get svc -n keda | grep -E "(NAME|interceptor)"

# Vérifier que l'interceptor est bien créé
if kubectl get svc keda-add-ons-http-interceptor-proxy -n keda &> /dev/null; then
    success "Installation KEDA réussie !"
    echo ""
    echo "Prochaine étape : Appliquer le HTTPScaledObject"
    echo "  kubectl apply -f k8s/scores/scaled-object.yaml"
else
    error "L'interceptor KEDA n'a pas été créé"
    echo "Vérifiez les logs avec :"
    echo "  kubectl logs -n keda -l app.kubernetes.io/name=keda-add-ons-http-controller"
    exit 1
fi
