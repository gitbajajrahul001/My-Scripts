param(
[string] $ClientSecretKey,
[string] $UserId,
[string] $TenantId,
[string] $SubscriptionId,
[string] $resourceGroupName,
[string] $vmName,
[string] $driveLettersString,
[string] $LogFileLocation,
[string] $RequestNo,
[string] $NewDiskNamesArray
)

# === Logging Setup ===
if (-not (Test-Path $LogFileLocation)) {
 New-Item -Path $LogFileLocation -ItemType Directory -Force 
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = "$LogFileLocation\InitializeDisk_${RequestNo}_$timestamp.log"
Write-Output "Log File Path : $LogFile"

function Log {
    param ([string]$Message)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Add-Content -Path $LogFile -Value $entry
}


$delaySeconds = 3
Start-Sleep -Seconds $delaySeconds

Log "Starting script for VM: $vmName in Resource Group: $resourceGroupName"

$pass = ConvertTo-SecureString -string $ClientSecretKey -AsPlainText -Force
$cred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $UserId, $pass

if ("TrustAllCertsPolicy" -as [type]) {} else {
    add-type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
       }
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3, [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12
[System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

Log "Connecting to Azure..."
$AzureConnect = Connect-AzAccount -Credential $cred -ServicePrincipal -Tenant $TenantId | Out-Null
$Subs = Select-AzSubscription -SubscriptionId $SubscriptionId -Scope CurrentUser | Out-Null
Log "Connected to Azure and selected subscription: $SubscriptionId"

Start-Sleep -Seconds $delaySeconds

Log "Fetching VM data disks..."
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName
$dataDisks = @($vm.StorageProfile.DataDisks | Select-Object -Property Name, DiskSizeGB, Lun)
Log "Found $($dataDisks.Count) data disk(s) attached to VM."

$script = @'
$diskDetails = Get-WmiObject -Class Win32_DiskDrive
$diskDetails | ForEach-Object {
    [PSCustomObject]@{
        DiskNumber = $_.Index
        Model = $_.Model
        InterfaceType = $_.InterfaceType
        SizeGB = [math]::Round($_.Size / 1GB, 2)
        LunID = $_.SCSILogicalUnit
    }
} | ConvertTo-Json
'@

Start-Sleep -Seconds $delaySeconds
Log "Running script on VM to fetch actual disk details..."
$result = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $script
$jsonResult = $result.Value | ForEach-Object { $_.Message } | Out-String
$disks = $jsonResult | ConvertFrom-Json
Log "Retrieved disk details from VM."

function Get-DiskNumberByLunID {
    param (
        [int]$LunID,
        $Disks
    )
    foreach ($disk in $Disks) {
        if ($disk.LunID -eq $LunID) {
            return $disk.DiskNumber
        }
    }
}

$driveLetters = $driveLettersString -split ',' | ForEach-Object { ($_.Trim() -split ' ')[0] }

#####
# Only initializing the new disk 

$newDiskNames = $NewDiskNamesArray.Trim('{}') -split ',' |
    ForEach-Object { $_.Trim().ToLower() 
    }

$newDataDisks = @(
    $dataDisks | Where-Object {
        $newDiskNames -contains $_.Name.Trim().ToLower()
    }
)

if (-not $newDataDisks -or $newDataDisks.Count -eq 0) {
    Log "ERROR: No matching new disks found. Check disk names passed in NewDiskNamesArray."
    throw "No matching new disks found"
}

####



$results = @()
Start-Sleep -Seconds $delaySeconds
Log "Mapping LUN IDs to Disk Numbers and Drive Letters..."

for ($i = 0; $i -lt $newDataDisks.Count; $i++) {
    $dataDisk = $newDataDisks[$i]
    $lunid = $dataDisk.Lun
    $diskNumber = Get-DiskNumberByLunID -LunID $lunid -Disks $disks
    $driveLetter = $driveLetters[$i]

    $results += [PSCustomObject]@{
        LunID = $lunid
        DiskNumber = $diskNumber
        DiskName = $dataDisk.Name
        DiskSizeGB = $dataDisk.DiskSizeGB
        DriveLetter = $driveLetter
    }

    Log "Matched: Disk '$($dataDisk.Name)' (LUN $lunid) -> DiskNumber $diskNumber, DriveLetter $driveLetter"
    Write-Output "Matched: Disk '$($dataDisk.Name)' (LUN $lunid) -> DiskNumber $diskNumber, DriveLetter $driveLetter"
}

Start-Sleep -Seconds $delaySeconds

foreach ($disk in $results) {
    $DiskName = $disk.DiskName
    $DiskNumber = $disk.DiskNumber
    $DriveLetter = $disk.DriveLetter

    Log "Initializing and formatting disk: $DiskName (DiskNumber: $DiskNumber) with Drive Letter: $DriveLetter"

    $script = @"
    Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -PassThru | 
        New-Partition -UseMaximumSize -AssignDriveLetter | 
        Format-Volume -FileSystem NTFS -NewFileSystemLabel "DataDisk"

    Set-Partition -DiskNumber $DiskNumber -PartitionNumber 1 -NewDriveLetter $DriveLetter
"@

    Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName -CommandId 'RunPowerShellScript' -ScriptString $script
    Log "Disk $DiskName initialized and formatted successfully with Drive Letter: $DriveLetter"
}

Log "All disks initialized and formatted successfully."
Write-Output "All disks initialized and formatted successfully"