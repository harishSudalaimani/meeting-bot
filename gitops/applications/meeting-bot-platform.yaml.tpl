apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: meeting-bot-platform
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GIT_REPOSITORY_URL}
    targetRevision: main
    path: kubernetes/chart
    helm:
      valueFiles:
        - values-learning.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: meeting-bot
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
