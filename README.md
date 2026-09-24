# test

## Inventaire AKS

`aks-inventory.ps1` produit un inventaire JSON d'un cluster AKS : ressources Kubernetes,
pods et noeuds avec leurs capacites, reservations et etats, services et stockage,
mesures CPU/memoire fournies par Metrics Server, ainsi que la configuration AKS,
les load balancers et les adresses IP publiques Azure.

Prerequis sous Windows : PowerShell avec `Out-GridView`, Azure CLI (`az`), `kubectl`,
un acces au cluster et un kubeconfig dans `C:\Users\RJMG5510\.kube\config`.
Le script ouvre `az login` dans le navigateur, puis affiche trois choix graphiques :
abonnement, cluster AKS et contexte kubectl. Il verifie que le serveur du contexte
correspond au cluster Azure choisi avant toute collecte.

```powershell
.\aks-inventory.ps1 -OutputPath .\aks-inventory.json
```

Pour une execution sans fenetres de selection, fournir les quatre identifiants.
`-SkipLogin` reutilise une session Azure CLI deja authentifiee :

```powershell
.\aks-inventory.ps1 -SkipLogin -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>' -ClusterName '<aks-name>' -Context '<kube-context>' -KubeConfigPath 'C:\Users\RJMG5510\.kube\config'
```

Chaque section du JSON indique `available`. Une section inaccessible contient
`available: false` et son erreur ; la collecte continue pour les autres sections.
Les secrets ne sont que comptes, sans export de leurs noms ni de leurs valeurs.
Les mesures CPU/memoire restent indisponibles si Metrics Server est absent.

Le test de fumee utilise des commandes `az` et `kubectl` simulees :

```powershell
pwsh -NoProfile -File tests/aks-inventory.Smoke.ps1
```
