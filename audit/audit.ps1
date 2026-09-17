# Get all VMs
$allVMs = Get-AzVM | Select-Object Name, ResourceGroupName, Id

# Get DCR associations
$dcrAssociations = @()
foreach ($vm in $allVMs) {
    $associations = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction SilentlyContinue
    if ($associations) {
        $dcrAssociations += [PSCustomObject]@{
            VMName = $vm.Name
            ResourceGroup = $vm.ResourceGroupName
            HasDCR = $true
        }
    }
}

# Find VMs without DCR associations
$vmsWithoutDCR = $allVMs | Where-Object {
    $_.Name -notin $dcrAssociations.VMName
} | Select-Object Name, ResourceGroupName

$vmsWithoutDCR | Format-Table