$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..' 'aks-inventory.ps1'
$kubeconfig = New-TemporaryFile
$output = Join-Path ([System.IO.Path]::GetTempPath()) "aks-inventory-test-$([guid]::NewGuid()).json"
$guiOutput = Join-Path ([System.IO.Path]::GetTempPath()) "aks-inventory-gui-test-$([guid]::NewGuid()).json"
$mismatchOutput = Join-Path ([System.IO.Path]::GetTempPath()) "aks-inventory-mismatch-test-$([guid]::NewGuid()).json"
$global:badContext = $false

function az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account' -and $args[1] -eq 'list') {
        return '[{"name":"Test subscription","id":"sub-test","tenantId":"tenant-test","state":"Enabled"}]'
    }
    if ($args[0] -eq 'aks' -and $args[1] -eq 'list') {
        return '[{"name":"aks-test","resourceGroup":"rg-test","location":"francecentral"}]'
    }
    if ($args[0] -eq 'aks' -and $args[1] -eq 'show') {
        return '{"name":"aks-test","resourceGroup":"rg-test","nodeResourceGroup":"rg-nodes","fqdn":"aks.example.test","agentPoolProfiles":[]}'
    }
    return '[]'
}

function Out-GridView {
    param([string]$Title, [string]$OutputMode, [Parameter(ValueFromPipeline)]$InputObject)
    process { $InputObject }
}

function kubectl {
    $global:LASTEXITCODE = 0
    if ($args -contains 'view') {
        if ($global:badContext) {
            return '{"contexts":[{"name":"aks-test","context":{"cluster":"aks-test"}}],"clusters":[{"name":"aks-test","cluster":{"server":"https://other.example.test"}}]}'
        }
        return '{"contexts":[{"name":"aks-test","context":{"cluster":"aks-test"}}],"clusters":[{"name":"aks-test","cluster":{"server":"https://aks.example.test"}}]}'
    }
    if ($args -contains '--raw') {
        if ($args[-1] -match '/nodes$') {
            return '{"items":[{"metadata":{"name":"node-1"},"usage":{"cpu":"50m","memory":"100Mi"}}]}'
        }
        return '{"items":[{"metadata":{"namespace":"default","name":"pod-1"},"containers":[{"name":"app","usage":{"cpu":"20m","memory":"50Mi"}}]}]}'
    }
    $resource = $args[([array]::IndexOf($args, 'get') + 1)]
    switch ($resource) {
        'pods' { return '{"items":[{"metadata":{"namespace":"default","name":"pod-1"},"status":{"phase":"Running","containerStatuses":[{"name":"app","ready":true,"restartCount":1}]},"spec":{"nodeName":"node-1","containers":[{"name":"app","image":"app:v1","resources":{"requests":{"cpu":"100m"}}}]}}]}' }
        'nodes' { return '{"items":[{"metadata":{"name":"node-1"},"status":{"conditions":[{"type":"Ready","status":"True"}],"addresses":[{"type":"InternalIP","address":"10.0.0.1"}]}}]}' }
        'deployments' { return '{"items":[{"metadata":{"name":"web","namespace":"default"},"spec":{"replicas":3},"status":{"readyReplicas":2,"availableReplicas":2}}]}' }
        'secrets' { return '{"items":[{"metadata":{"name":"secret-name","namespace":"default"},"data":{"password":"c2VjcmV0"}}]}' }
        default { return '{"items":[]}' }
    }
}

try {
    & $scriptPath -SkipLogin -KubeConfigPath $kubeconfig.FullName -OutputPath $output -SubscriptionId 'sub-test' -ResourceGroup 'rg-test' -ClusterName 'aks-test' -Context 'aks-test'
    $data = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    if ($data.resources.pods.runningCount -ne 1) { throw 'Running pod count incorrect.' }
    if ($data.resources.nodes.readyCount -ne 1) { throw 'Ready node count incorrect.' }
    if ($data.resources.deployments.items[0].readyReplicas -ne 2) { throw 'Deployment readiness missing.' }
    if ($data.metrics.nodes.items[0].usage.cpu -ne '50m') { throw 'Node metrics missing.' }
    if ($data.resources.secrets.count -ne 1) { throw 'Secret count incorrect.' }
    if ($data.resources.secrets.PSObject.Properties.Name -contains 'items') { throw 'Secret data was exported.' }
    if ($data.azure.aks.name -ne 'aks-test') { throw 'AKS identity incorrect.' }
    & $scriptPath -SkipLogin -KubeConfigPath $kubeconfig.FullName -OutputPath $guiOutput
    $guiData = Get-Content -LiteralPath $guiOutput -Raw | ConvertFrom-Json
    if ($guiData.selection.subscriptionId -ne 'sub-test' -or $guiData.selection.context -ne 'aks-test') { throw 'Graphical selection incorrect.' }
    $global:badContext = $true
    $rejected = $false
    try {
        & $scriptPath -SkipLogin -KubeConfigPath $kubeconfig.FullName -OutputPath $mismatchOutput -SubscriptionId 'sub-test' -ResourceGroup 'rg-test' -ClusterName 'aks-test' -Context 'aks-test'
    }
    catch { $rejected = $_.Exception.Message -match 'different du cluster AKS' }
    if (-not $rejected -or (Test-Path -LiteralPath $mismatchOutput)) { throw 'Mismatched Kubernetes context was not rejected.' }
    Write-Host 'AKS inventory smoke test passed.'
}
finally {
    Remove-Item -LiteralPath $output, $guiOutput, $mismatchOutput, $kubeconfig.FullName -ErrorAction SilentlyContinue
}
