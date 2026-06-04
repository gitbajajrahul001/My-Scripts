#####Disk Block
param(
    [string] $ClientSecretKey,
    [string] $UserId,
    [string] $TenantId,
    [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $VMName,
    [string] $diskDatastr,
    [string] $LogFileLocation,
    [string] $RequestNo
)

# === Logging Setup ===
if (-not (Test-Path $LogFileLocation)) {
 New-Item -Path $LogFileLocation -ItemType Directory -Force 
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = "$LogFileLocation\AddDiskMount_${RequestNo}_$timestamp.log"
Write-Output "Log File Path : $LogFile"

function Log {
    param ([string]$Message)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Add-Content -Path $LogFile -Value $entry
}

Try{
 Log "Script started"
 #$diskcmdparam='/test01,64,vgsw01'
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
  
    Log "Setting up Azure connection"
    Connect-AzAccount -Credential $cred -ServicePrincipal -Tenant $TenantId # -Scope Process -Verbose -ErrorAction Stop | Out-Null
    Select-AzSubscription -SubscriptionId $SubscriptionId -Scope CurrentUser | Out-Null
 Log "Connected to Azure and selected subscription: $SubscriptionId"
    <#
    ##
    $diskcmd=''
 #$vgname='vgsw01'
 if($diskDatastr -ne '' -and $diskDatastr -ne $null)
 {
  $diskData=$diskDatastr |ConvertFrom-Json
  $diskData |ForEach-Object{
      $curr_DiskName=$_.DiskName
      $curr_DiskSize=$_.DiskSize
         $diskcmd=$diskcmd+$curr_DiskName+','+$curr_DiskSize+','+$vgname+' '
        }
    }
 Log "hdnDiskCommand:$diskcmd"
 Write-Output "hdnDiskCommand:$diskcmd"
    $diskcmdparam = $diskcmd
    ##
    #>
    # Define the path to the shell script
    $ShellScriptPath = "D:\MyCloud\Script\AzAddMountPointLatest.sh"

    # check whether file exists or not
    if (-Not (Test-Path $ShellScriptPath)) {
     Log "Error occurred:Shell script file '$ShellScriptPath' not found!"
        throw "Error occurred:Shell script file '$ShellScriptPath' not found!"
    }

    # Read the shell script content into a variable
    try 
    {
     Log "Reading Content from the path $ShellScriptPath"
        $ShellScriptContent = Get-Content -Path $ShellScriptPath -Raw
    } 
    catch 
    {
     Log "Error occurred:Failed to read the content of the script file: $_"
        throw "Error occurred:Failed to read the content of the script file: $_"
    }

    Log "Copying the file inside the guest os"

    try {
        $Result = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VMName `
            -CommandId RunShellScript `
            -ScriptString "cat > /tmp/AzAddMountPointLatest.sh << 'EOF'
$ShellScriptContent
EOF"

Log $Result
    }
    catch {
        Log "Failed to execute script on VM '$VMName'. Error: $_"
        throw "Failed to execute script on VM '$VMName'. Error: $_"
    }
        
    Log "File copied inside guest os"


    ##########Execute diskmountwithsize.sh
     
     $cmd = "sudo sh /tmp/AzAddMountPointLatest.sh"
     #$script = -join ($cmd, " ", $diskcmdparam)
     $script = "$cmd `"$diskDatastr`"" #newly added
     $combinedCommand = "sudo dos2unix /tmp/AzAddMountPointLatest.sh && sudo chmod 755 /tmp/AzAddMountPointLatest.sh"
    try 
    { 
     Log "Trying to execute the command $combinedCommand remotely inside the created VM $VMName"
        $combinedCommandExecResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunShellScript' -ScriptString $combinedCommand
  Log $combinedCommandExecResult
        Log "$combinedCommand Execution Completed Successfully"
    } 
    catch 
    {
     Log "$combinedCommand Execution failed"
        throw "Failed to execute script on VM '$VMName'. Error: $_"
    }

    try 
    {
     Log "Trying to execute the command $script remotely inside the created VM $VMName"
        $ScriptExecResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunShellScript' -ScriptString $script
        Log $ScriptExecResult
        Log "$script Execution Completed Successfully"
    } 
    catch 
    {
     Log "$script Execution failed"
        throw "Failed to execute script on VM '$VMName'. Error: $_"
    }

    <# Check if the command succeeded and display the result
    if (($Result.Value[0].Message -split '\[stderr\]' | Select-Object -Last 1).Trim().Length -eq 0) {
     Log "File created successfully on the VM."
        Write-Output "File created successfully on the VM."
        Log "Output: $($Result.Value[0].Message)"
        Write-Output "Output: $($Result.Value[0].Message)"
    } else {
     Log "Script execution failed on the VM. Status Code: $($Result.Value[0].Message)"
        Write-Error "Script execution failed on the VM. Status Code: $($Result.Value[0].Message)"
        throw "Error occurred: $($Result.Value[0].Message)"
    }
    if (($combinedCommandExecResult.Value[0].Message -split '\[stderr\]' | Select-Object -Last 1).Trim().Contains('dos2unix: converting file /tmp/diskmountwithsize.sh to Unix format') -or ($combinedCommandExecResult.Value[0].Message -split '\[stderr\]' | Select-Object -Last 1).Trim().Length -eq 0) {
  Log "dos2unix command executed successfully."
  Log "Output: $($combinedCommandExecResult.Value[0].Message)"
        Write-Output "dos2unix command executed successfully."
        Write-Output "Output: $($combinedCommandExecResult.Value[0].Message)"
    } else {
  Log "Script execution failed on the VM. Status Code: $($combinedCommandExecResult.Value[0].Message)"
        Write-Error "Script execution failed on the VM. Status Code: $($combinedCommandExecResult.Value[0].Message)"
        throw "Error occurred: $($combinedCommandExecResult.Value[0].Message)"
    }

    if (($ScriptExecResult.Value[0].Message -split '\[stderr\]' | Select-Object -Last 1).Trim().Length -eq 0) {
  Log "diskmountwithsize script executed successfully."
        Log "Output: $($ScriptExecResult.Value[0].Message)"
        Write-Output "diskmountwithsize script executed successfully."
        Write-Output "Output: $($ScriptExecResult.Value[0].Message)"
    } else {
  Log "Script execution failed on the VM. Status Code: $($ScriptExecResult.Value[0].Message)"
        Write-Error "Script execution failed on the VM. Status Code: $($ScriptExecResult.Value[0].Message)"
        throw "Error occurred: $($ScriptExecResult.Value[0].Message)"
    }#>
 Log "---Script completed successfully---"
}
Catch [Exception] {
  Log "ERROR: $($_.Exception.Message)"
        throw "$($_.Exception.Message)"
    }