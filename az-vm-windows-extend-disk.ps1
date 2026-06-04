param (
[Parameter(Mandatory=$false)]
 [string] $ClientSecretKey,
    [string] $ClientID,
    [string] $TenantID,
    [string] $VMName,
    [string] $ResourceGroupName,
    [string] $subscriptionID,
    [string] $hdnAdditionalDiskJson 
)
  $pass = ConvertTo-SecureString -string $ClientSecretKey -AsPlainText -Force
       $cred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $ClientID, $pass
        try 
        { 
            Login-AzAccount -Credential $cred -ServicePrincipal -TenantId $TenantId | Out-Null
   Select-AzSubscription -SubscriptionId $subscriptionID | Out-Null
        }
        catch
        {
            throw
        }
            
  # Select-AzSubscription $subscriptionID


 # Convert JSON
$disksToExtend = $hdnAdditionalDiskJson | ConvertFrom-Json
 
# Extract Drive Letters
$driveLetters = $disksToExtend | Select-Object -ExpandProperty DiskName
 
# Convert to comma-separated string for VM script
$driveString = ($driveLetters -join ",")
 
$x = Invoke-AzVMRunCommand `
    -ResourceGroupName $ResourceGroupName `
    -Name $VMName `
    -CommandId 'RunPowerShellScript' `
    -ScriptString @"
`$driveLetters = "$driveString".Split(",")
 
foreach (`$drive in `$driveLetters) {
 
    Write-Output "Processing Drive: `$drive"
 
    try {
 
        `$supportedSize = Get-PartitionSupportedSize -DriveLetter `$drive -ErrorAction Stop
        `$currentSize   = (Get-Partition -DriveLetter `$drive).Size
 
        if (`$supportedSize.SizeMax -gt `$currentSize) {
 
            Resize-Partition -DriveLetter `$drive -Size `$supportedSize.SizeMax
            Write-Output "Drive `$drive extended successfully."
        }
        else {
            Write-Output "Drive `$drive already at maximum size."
        }
 
    }
    catch {
        Write-Output "Error extending drive `$drive : `$($_.Exception.Message)"
    }
}
"@
 
# Print VM Output
Write-Output "$x.Value[0].Message"
 