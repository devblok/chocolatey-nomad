# Defaults
$serviceName = "nomad"
$binariesPath = $(Join-Path (Split-Path -parent $MyInvocation.MyCommand.Definition) "..\binaries\")
$toolsPath = (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$serviceInstallationDirectory = "$env:PROGRAMDATA\nomad"
$serviceLogDirectory = "$serviceInstallationDirectory\logs"
$serviceConfigDirectory = "$serviceInstallationDirectory\conf"
$serviceDataDirectory = "$serviceInstallationDirectory\data"

$packageParameters = $env:chocolateyPackageParameters
if (-not ($packageParameters)) {
  $packageParameters = ""
  Write-Debug "No Package Parameters Passed in"
}

# Nomad related variables
$nomadVersion = '0.10.9'
$sourcePath = if (Get-ProcessorBits 32) {
  $(Join-Path $binariesPath "$($nomadVersion)_windows_386.zip")
} else {
  $(Join-Path $binariesPath "$($nomadVersion)_windows_amd64.zip")
}

# Create Service Directories
Write-Host "Creating $serviceLogDirectory"
New-Item -ItemType directory -Path "$serviceLogDirectory" -ErrorAction SilentlyContinue | Out-Null
Write-Host "Creating $serviceConfigDirectory"
New-Item -ItemType directory -Path "$serviceConfigDirectory" -ErrorAction SilentlyContinue | Out-Null
Write-Host "Creating $serviceDataDirectory"
New-Item -ItemType directory -Path "$serviceDataDirectory" -ErrorAction SilentlyContinue | Out-Null

# Unzip and move Nomad
Get-ChocolateyUnzip  $sourcePath "$toolsPath"

#Copy default configuration
Copy-Item "$toolsPath/../configs/client.hcl" "$serviceConfigDirectory"

# Create event log source
# User -Force to avoid "A key at this path already exists" exception. Overwrite not an issue since key is not further modified
$registryPath = 'HKLM:\SYSTEM\CurrentControlSet\services\eventlog\Application'
New-Item -Path $registryPath -Name nomad -Force | Out-Null
# Set EventMessageFile value
Set-ItemProperty $registryPath\nomad EventMessageFile "C:\Windows\Microsoft.NET\Framework64\v2.0.50727\EventLogMessages.dll" | Out-Null

# Set up task scheduler for log rotation
$logrotate = ('%SYSTEMROOT%\System32\forfiles.exe /p \"{0}\" /s /m *.* /c \"cmd /c Del @path\" /d -7' -f "$serviceLogDirectory")
SchTasks.exe /Create /SC DAILY /TN ""NomadLogrotate"" /TR ""$($logrotate)"" /ST 09:00 /F | Out-Null

# Set up task scheduler for log rotation. Only works for Powershell 4 or Server 2012R2 so this block can replace
# using SchTasks.exe for registering services once machines have retired the older version of PS or upgraded to 2012R2
#$command = ('$now = Get-Date; dir "{0}" | where {{$_.LastWriteTime -le $now.AddDays(-7)}} | del -whatif' -f $serviceLogDirectory)
#$action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -command $($command)"
#$trigger = New-ScheduledTaskTrigger -Daily -At 9am
#Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "NomadLogrotate" -Description "Log rotation for nomad"

#Uninstall service if it already exists. Stops the service first if it's running
$service = Get-Service $serviceName -ErrorAction SilentlyContinue
if ($service) {
  Write-Host "Uninstalling existing service"
  if($service.Status -ne "Stopped" -and $service.Status -ne "Stopping") {
    Write-Host "Stopping nomad process ..."
    $service.Stop();
  }

  $service.WaitForStatus("Stopped", (New-TimeSpan -Minutes 1));
  if($service.Status -ne "Stopped") {
    throw "$serviceName could not be stopped within the allotted timespan.  Stop the service and try again."
  }

  $service = Get-WmiObject -Class Win32_Service -Filter "Name='$serviceName'"
  $service.delete() | Out-Null
}

# Install the service
Write-Host "Installing service: $serviceName"
& sc.exe create $serviceName binpath= "$(Join-Path $toolsPath "nomad.exe") agent -config=$serviceConfigDirectory/client.hcl -data-dir=$serviceDataDirectory $packageParameters" start= auto | Out-Null
cmd.exe /c "sc failure $serviceName reset= 0 actions= restart/60000" | Out-Null

# Let this call to Get-Service throw if the service does not exist
$service = Get-Service $serviceName
if($service.Status -ne "Stopped" -and $service.Status -ne "Stopping") {
  $service.Stop()
}

$service.WaitForStatus("Stopped", (New-TimeSpan -Minutes 1));
& sc.exe start $serviceName | Out-Null

Write-Host "Installed service: $serviceName"
