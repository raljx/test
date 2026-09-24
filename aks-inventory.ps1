[CmdletBinding()]
param(
    [string]$KubeConfigPath = 'C:\Users\RJMG5510\.kube\config',
    [string]$OutputPath = '.\aks-inventory.json',
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ClusterName,
    [string]$Context,
    [switch]$SkipLogin
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
}

function Invoke-JsonCommand {
    param([string]$Command, [string[]]$Arguments)
    Write-Log "$Command $($Arguments -join ' ')"
    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Command a echoue (code $LASTEXITCODE) : $($output -join ' ')"
    }
    $text = ($output -join "`n").Trim()
    if (-not $text) { return $null }
    return ConvertFrom-Json -InputObject $text
}

function Invoke-AzJson {
    param([string[]]$Arguments)
    return Invoke-JsonCommand -Command 'az' -Arguments ($Arguments + @('--only-show-errors', '--output', 'json'))
}

function Invoke-KubectlJson {
    param([string[]]$Arguments)
    return Invoke-JsonCommand -Command 'kubectl' -Arguments (@('--kubeconfig', $KubeConfigPath, '--context', $Context) + $Arguments)
}

function Select-One {
    param([object[]]$Items, [string]$Title)
    if (@($Items).Count -eq 0) { throw "Aucun element disponible : $Title" }
    $selection = @($Items | Out-GridView -Title $Title -OutputMode Single)
    if ($selection.Count -ne 1) { throw "Selection annulee : $Title" }
    return $selection[0]
}

function Get-Items {
    param($Object)
    if ($null -eq $Object -or $null -eq $Object.items) { return @() }
    return @($Object.items)
}

function Get-Section {
    param([scriptblock]$Collect)
    try {
        $result = & $Collect
        $result['available'] = $true
        return $result
    }
    catch {
        Write-Log $_.Exception.Message 'WARN'
        return [ordered]@{ available = $false; error = $_.Exception.Message }
    }
}

function Get-ResourceInventory {
    param([string]$Resource, [switch]$ClusterScoped, [switch]$CountOnly)
    return Get-Section {
        $args = @('get', $Resource)
        if (-not $ClusterScoped) { $args += '-A' }
        $items = Get-Items (Invoke-KubectlJson -Arguments ($args + @('-o', 'json')))
        $byNamespace = [ordered]@{}
        foreach ($group in @($items | Where-Object { $_.metadata.namespace } | Group-Object { $_.metadata.namespace })) {
            $byNamespace[$group.Name] = $group.Count
        }
        $result = [ordered]@{ count = $items.Count; countByNamespace = $byNamespace }
        if (-not $CountOnly) {
            $result.items = @($items | ForEach-Object {
                $item = $_
                $row = [ordered]@{
                    namespace = $item.metadata.namespace
                    name = $item.metadata.name
                    uid = $item.metadata.uid
                    createdAt = $item.metadata.creationTimestamp
                    labels = $item.metadata.labels
                }
                switch ($Resource) {
                    { $_ -in @('deployments', 'replicasets', 'statefulsets', 'daemonsets') } {
                        $row.desiredReplicas = if ($Resource -eq 'daemonsets') { $item.status.desiredNumberScheduled } else { $item.spec.replicas }
                        $row.readyReplicas = if ($Resource -eq 'daemonsets') { $item.status.numberReady } else { $item.status.readyReplicas }
                        $row.availableReplicas = $item.status.availableReplicas
                    }
                    'jobs' {
                        $row.succeeded = $item.status.succeeded
                        $row.failed = $item.status.failed
                        $row.active = $item.status.active
                    }
                    'cronjobs' {
                        $row.schedule = $item.spec.schedule
                        $row.suspend = $item.spec.suspend
                        $row.lastScheduleTime = $item.status.lastScheduleTime
                    }
                    'horizontalpodautoscalers' {
                        $row.currentReplicas = $item.status.currentReplicas
                        $row.desiredReplicas = $item.status.desiredReplicas
                        $row.currentMetrics = $item.status.currentMetrics
                    }
                    'poddisruptionbudgets' {
                        $row.currentHealthy = $item.status.currentHealthy
                        $row.desiredHealthy = $item.status.desiredHealthy
                        $row.disruptionsAllowed = $item.status.disruptionsAllowed
                    }
                    'events' {
                        $row.type = $item.type
                        $row.reason = $item.reason
                        $row.count = $item.count
                        $row.lastTimestamp = $item.lastTimestamp
                    }
                }
                $row
            })
        }
        return $result
    }
}

function Get-PodInventory {
    return Get-Section {
        $items = Get-Items (Invoke-KubectlJson -Arguments @('get', 'pods', '-A', '-o', 'json'))
        $pods = @($items | ForEach-Object {
            $pod = $_
            [ordered]@{
                namespace = $pod.metadata.namespace
                name = $pod.metadata.name
                phase = $pod.status.phase
                node = $pod.spec.nodeName
                qosClass = $pod.status.qosClass
                podIP = $pod.status.podIP
                startTime = $pod.status.startTime
                ownerReferences = @($pod.metadata.ownerReferences | ForEach-Object { [ordered]@{ kind = $_.kind; name = $_.name } })
                containers = @($pod.spec.containers | ForEach-Object {
                    $container = $_
                    $state = @($pod.status.containerStatuses | Where-Object { $_.name -eq $container.name } | Select-Object -First 1)
                    [ordered]@{
                        name = $container.name
                        image = $container.image
                        requests = $container.resources.requests
                        limits = $container.resources.limits
                        ready = if ($state.Count) { $state[0].ready } else { $null }
                        restartCount = if ($state.Count) { $state[0].restartCount } else { $null }
                    }
                })
            }
        })
        $phases = [ordered]@{}
        foreach ($group in @($pods | Group-Object { $_.phase })) { $phases[$group.Name] = $group.Count }
        return [ordered]@{
            count = $pods.Count
            runningCount = @($pods | Where-Object { $_.phase -eq 'Running' }).Count
            phaseCounts = $phases
            items = $pods
        }
    }
}

function Get-NodeInventory {
    return Get-Section {
        $items = Get-Items (Invoke-KubectlJson -Arguments @('get', 'nodes', '-o', 'json'))
        $nodes = @($items | ForEach-Object {
            $node = $_
            $ready = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1)
            [ordered]@{
                name = $node.metadata.name
                ready = if ($ready.Count) { $ready[0].status } else { $null }
                internalIP = @($node.status.addresses | Where-Object { $_.type -eq 'InternalIP' } | Select-Object -First 1 | ForEach-Object { $_.address })[0]
                externalIP = @($node.status.addresses | Where-Object { $_.type -eq 'ExternalIP' } | Select-Object -First 1 | ForEach-Object { $_.address })[0]
                capacity = $node.status.capacity
                allocatable = $node.status.allocatable
                conditions = $node.status.conditions
                nodeInfo = $node.status.nodeInfo
                taints = @($node.spec.taints)
                labels = $node.metadata.labels
            }
        })
        return [ordered]@{ count = $nodes.Count; readyCount = @($nodes | Where-Object { $_.ready -eq 'True' }).Count; items = $nodes }
    }
}

function Get-ServiceInventory {
    return Get-Section {
        $items = Get-Items (Invoke-KubectlJson -Arguments @('get', 'services', '-A', '-o', 'json'))
        $services = @($items | ForEach-Object {
            [ordered]@{
                namespace = $_.metadata.namespace
                name = $_.metadata.name
                type = $_.spec.type
                clusterIP = $_.spec.clusterIP
                externalIPs = @($_.spec.externalIPs | Where-Object { $null -ne $_ })
                loadBalancerIngress = @($_.status.loadBalancer.ingress | Where-Object { $null -ne $_ })
                ports = @($_.spec.ports)
                selector = $_.spec.selector
            }
        })
        return [ordered]@{ count = $services.Count; loadBalancerCount = @($services | Where-Object { $_.type -eq 'LoadBalancer' }).Count; items = $services }
    }
}

function Get-StorageInventory {
    return Get-Section {
        $pvcs = Get-Items (Invoke-KubectlJson -Arguments @('get', 'persistentvolumeclaims', '-A', '-o', 'json'))
        $pvs = Get-Items (Invoke-KubectlJson -Arguments @('get', 'persistentvolumes', '-o', 'json'))
        return [ordered]@{
            pvcCount = $pvcs.Count
            pvCount = $pvs.Count
            pvcs = @($pvcs | ForEach-Object { [ordered]@{ namespace = $_.metadata.namespace; name = $_.metadata.name; phase = $_.status.phase; requestedStorage = $_.spec.resources.requests.storage; storageClass = $_.spec.storageClassName; volumeName = $_.spec.volumeName } })
            pvs = @($pvs | ForEach-Object { [ordered]@{ name = $_.metadata.name; phase = $_.status.phase; capacity = $_.spec.capacity; storageClass = $_.spec.storageClassName; claimNamespace = $_.spec.claimRef.namespace; claimName = $_.spec.claimRef.name } })
        }
    }
}

function Get-Metrics {
    param([string]$Resource)
    return Get-Section {
        $data = Invoke-KubectlJson -Arguments @('get', '--raw', "/apis/metrics.k8s.io/v1beta1/$Resource")
        $items = Get-Items $data
        return [ordered]@{
            count = $items.Count
            items = @($items | ForEach-Object {
                if ($Resource -eq 'nodes') {
                    [ordered]@{ name = $_.metadata.name; timestamp = $_.timestamp; window = $_.window; usage = $_.usage }
                }
                else {
                    [ordered]@{ namespace = $_.metadata.namespace; name = $_.metadata.name; timestamp = $_.timestamp; window = $_.window; containers = @($_.containers | ForEach-Object { [ordered]@{ name = $_.name; usage = $_.usage } }) }
                }
            })
        }
    }
}

function Get-AzureInventory {
    return Get-Section {
        $aks = Invoke-AzJson -Arguments @('aks', 'show', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $ClusterName)
        $nodeResourceGroup = $aks.nodeResourceGroup
        $lbs = @(Invoke-AzJson -Arguments @('network', 'lb', 'list', '--subscription', $SubscriptionId, '--resource-group', $nodeResourceGroup))
        $ips = @(Invoke-AzJson -Arguments @('network', 'public-ip', 'list', '--subscription', $SubscriptionId, '--resource-group', $nodeResourceGroup))
        return [ordered]@{
            aks = [ordered]@{
                name = $aks.name; id = $aks.id; resourceGroup = $aks.resourceGroup; nodeResourceGroup = $nodeResourceGroup
                location = $aks.location; kubernetesVersion = $aks.currentKubernetesVersion; powerState = $aks.powerState
                sku = $aks.sku; networkProfile = $aks.networkProfile; agentPoolProfiles = $aks.agentPoolProfiles
                addonProfiles = $aks.addonProfiles; identity = $aks.identity.type; autoUpgradeProfile = $aks.autoUpgradeProfile
            }
            loadBalancers = [ordered]@{ count = $lbs.Count; items = @($lbs | ForEach-Object { [ordered]@{ name = $_.name; id = $_.id; sku = $_.sku; frontendIPConfigurations = $_.frontendIPConfigurations; backendAddressPools = @($_.backendAddressPools | ForEach-Object { $_.name }); loadBalancingRules = @($_.loadBalancingRules | ForEach-Object { $_.name }) } }) }
            publicIPs = [ordered]@{ count = $ips.Count; items = @($ips | ForEach-Object { [ordered]@{ name = $_.name; id = $_.id; ipAddress = $_.ipAddress; allocationMethod = $_.publicIPAllocationMethod; sku = $_.sku; dnsSettings = $_.dnsSettings } }) }
        }
    }
}

foreach ($command in @('az', 'kubectl')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command est introuvable dans le PATH." }
}
if (-not (Test-Path -LiteralPath $KubeConfigPath -PathType Leaf)) { throw "Kubeconfig introuvable : $KubeConfigPath" }

if (-not $SkipLogin) {
    Write-Log 'Ouverture de la connexion Azure dans le navigateur.'
    $loginOutput = & az login --only-show-errors --output none 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az login a echoue : $($loginOutput -join ' ')" }
}

if (-not $SubscriptionId) {
    $subscriptions = @(Invoke-AzJson -Arguments @('account', 'list', '--all') | Where-Object { $_.state -eq 'Enabled' })
    $choice = Select-One -Items @($subscriptions | ForEach-Object { [pscustomobject]@{ name = $_.name; id = $_.id; tenantId = $_.tenantId } }) -Title 'Choisir un abonnement Azure'
    $SubscriptionId = $choice.id
}
Write-Log "Abonnement selectionne : $SubscriptionId"

if (-not $ResourceGroup -or -not $ClusterName) {
    $clusters = @(Invoke-AzJson -Arguments @('aks', 'list', '--subscription', $SubscriptionId))
    $choice = Select-One -Items @($clusters | ForEach-Object { [pscustomobject]@{ name = $_.name; resourceGroup = $_.resourceGroup; location = $_.location; kubernetesVersion = $_.currentKubernetesVersion } }) -Title 'Choisir un cluster AKS'
    $ResourceGroup = $choice.resourceGroup
    $ClusterName = $choice.name
}
Write-Log "Cluster Azure selectionne : $ResourceGroup/$ClusterName"

if (-not $Context) {
    $config = Invoke-JsonCommand -Command 'kubectl' -Arguments @('--kubeconfig', $KubeConfigPath, 'config', 'view', '-o', 'json')
    $contexts = @($config.contexts | ForEach-Object { [pscustomobject]@{ name = $_.name; cluster = $_.context.cluster; user = $_.context.user } })
    $choice = Select-One -Items $contexts -Title 'Choisir le contexte kubectl du cluster'
    $Context = $choice.name
}
Write-Log "Contexte Kubernetes selectionne : $Context"

$config = Invoke-JsonCommand -Command 'kubectl' -Arguments @('--kubeconfig', $KubeConfigPath, 'config', 'view', '-o', 'json')
if (-not @($config.contexts | Where-Object { $_.name -eq $Context }).Count) { throw "Contexte absent du kubeconfig : $Context" }
$aksIdentity = Invoke-AzJson -Arguments @('aks', 'show', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $ClusterName)
$selectedContext = @($config.contexts | Where-Object { $_.name -eq $Context })[0]
$selectedCluster = @($config.clusters | Where-Object { $_.name -eq $selectedContext.context.cluster })[0]
$apiHost = if ($selectedCluster.cluster.server) { ([uri]$selectedCluster.cluster.server).Host } else { $null }
$expectedHosts = @($aksIdentity.fqdn, $aksIdentity.privateFqdn) | Where-Object { $_ }
if ($expectedHosts.Count -and $apiHost -notin $expectedHosts) {
    throw "Le contexte $Context pointe vers $apiHost, different du cluster AKS $ClusterName ($($expectedHosts -join ', '))."
}

$definitions = [ordered]@{
    namespaces = @{ resource = 'namespaces'; clusterScoped = $true }
    secrets = @{ resource = 'secrets'; countOnly = $true }
    configmaps = @{ resource = 'configmaps' }
    deployments = @{ resource = 'deployments' }
    replicasets = @{ resource = 'replicasets' }
    statefulsets = @{ resource = 'statefulsets' }
    daemonsets = @{ resource = 'daemonsets' }
    jobs = @{ resource = 'jobs' }
    cronjobs = @{ resource = 'cronjobs' }
    ingresses = @{ resource = 'ingresses' }
    ingressclasses = @{ resource = 'ingressclasses'; clusterScoped = $true }
    networkpolicies = @{ resource = 'networkpolicies' }
    serviceaccounts = @{ resource = 'serviceaccounts' }
    endpointslices = @{ resource = 'endpointslices' }
    horizontalpodautoscalers = @{ resource = 'horizontalpodautoscalers' }
    poddisruptionbudgets = @{ resource = 'poddisruptionbudgets' }
    events = @{ resource = 'events' }
    resourcequotas = @{ resource = 'resourcequotas' }
    limitranges = @{ resource = 'limitranges' }
    storageclasses = @{ resource = 'storageclasses'; clusterScoped = $true }
    priorityclasses = @{ resource = 'priorityclasses'; clusterScoped = $true }
    roles = @{ resource = 'roles' }
    rolebindings = @{ resource = 'rolebindings' }
    clusterroles = @{ resource = 'clusterroles'; clusterScoped = $true }
    clusterrolebindings = @{ resource = 'clusterrolebindings'; clusterScoped = $true }
    customresourcedefinitions = @{ resource = 'customresourcedefinitions'; clusterScoped = $true }
}

$resources = [ordered]@{}
foreach ($entry in $definitions.GetEnumerator()) {
    Write-Log "Inventaire Kubernetes : $($entry.Key)"
    $resources[$entry.Key] = Get-ResourceInventory -Resource $entry.Value.resource -ClusterScoped:([bool]$entry.Value.clusterScoped) -CountOnly:([bool]$entry.Value.countOnly)
}
Write-Log 'Inventaire Kubernetes : pods'
$resources.pods = Get-PodInventory
Write-Log 'Inventaire Kubernetes : nodes'
$resources.nodes = Get-NodeInventory
Write-Log 'Inventaire Kubernetes : services'
$resources.services = Get-ServiceInventory
Write-Log 'Inventaire Kubernetes : storage'
$resources.storage = Get-StorageInventory

Write-Log 'Collecte des metriques CPU et memoire.'
$metrics = [ordered]@{
    nodes = Get-Metrics -Resource 'nodes'
    pods = Get-Metrics -Resource 'pods'
}
Write-Log 'Collecte des ressources Azure.'
$azure = Get-AzureInventory

$result = [ordered]@{
    schemaVersion = '2.0'
    collectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    computerName = $env:COMPUTERNAME
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    selection = [ordered]@{ subscriptionId = $SubscriptionId; resourceGroup = $ResourceGroup; clusterName = $ClusterName; kubeconfig = $KubeConfigPath; context = $Context; apiServer = $apiHost }
    resources = $resources
    metrics = $metrics
    azure = $azure
    notes = @(
        'Les metriques CPU et memoire necessitent Metrics Server et representent une mesure recente.',
        'Les requests et limits sont des reservations, pas la consommation reelle.',
        'Les PV/PVC indiquent des capacites demandees ou provisionnees, pas le volume utilise.',
        'Les secrets sont uniquement comptes ; leurs noms et valeurs ne sont pas exportes.',
        'Chaque section indisponible contient available=false et une erreur explicite.'
    )
}

$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Log "JSON genere : $((Resolve-Path -LiteralPath $OutputPath).Path)"
Write-Log "Noeuds : $($resources.nodes.count) ; pods : $($resources.pods.count) ; pods Running : $($resources.pods.runningCount)"
