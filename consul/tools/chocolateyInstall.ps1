try {
  $binariesPath = $(Join-Path (Split-Path -parent $MyInvocation.MyCommand.Definition) "..\binaries\")
  $toolsPath = (Split-Path -Parent $MyInvocation.MyCommand.Definition)

  # NSSM related variables
  $nssmVersion = '2.24'
  $nssmSourcePath = $(Join-Path $binariesPath "nssm-$nssmVersion.zip")

  # Consul related variables
  $consulVersion = '0.5.2'
  $sourcePath = $(Join-Path $binariesPath "$($consulVersion)_windows_386.zip")
  $sourcePathUI = $(Join-Path $binariesPath "$($consulVersion)_web_ui.zip")

  # Install NSSM locally within consul
  Get-ChocolateyUnzip $nssmSourcePath $toolsPath

  $folderToIgnore = 'win32'
  $forderToRun = 'win64'

  if (Get-ProcessorBits 32) {
    $folderToIgnore = 'win64'
    $forderToRun = 'win32'
  }

  Set-Content -Path ($toolsPath + "\nssm-$nssmVersion\$folderToIgnore\nssm.exe.ignore") -Value $null
  $nssmBinPath = ($toolsPath + "\nssm-$nssmVersion\$forderToRun\nssm.exe")

  # Unzip and move Consul
  Get-ChocolateyUnzip  $sourcePath "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
  Get-ChocolateyUnzip  $sourcePathUI "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"

  Write-Host "Creating $env:PROGRAMDATA\consul\logs"
  New-Item -ItemType directory -Path "$env:PROGRAMDATA\consul\logs" -ErrorAction SilentlyContinue | Out-Null
  Write-Host "Creating $env:PROGRAMDATA\consul\config"
  New-Item -ItemType directory -Path "$env:PROGRAMDATA\consul\config" -ErrorAction SilentlyContinue | Out-Null

  # Create event log source
  # User -Force to avoid "A key at this path already exists" exception. Overwrite not an issue since key is not further modified
  $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\services\eventlog\Application'
  New-Item -Path $registryPath -Name consul -Force | Out-Null
  # Set EventMessageFile value
  Set-ItemProperty $registryPath\consul EventMessageFile "C:\Windows\Microsoft.NET\Framework64\v2.0.50727\EventLogMessages.dll" | Out-Null

  # Set up task scheduler for log rotation
  $logrotate = '%SYSTEMROOT%\System32\forfiles.exe /p \"%PROGRAMDATA%\consul\logs\" /s /m *.* /c \"cmd /c Del @path\" /d -7'
  SchTasks.exe /Create /SC DAILY /TN ""ConsulLogrotate"" /TR ""$($logrotate)"" /ST 09:00 | Out-Null

  # Set up task scheduler for log rotation. Only works for Powershell 4 or Server 2012R2 so this block can replace
  # using SchTasks.exe for registering services once machines have retired the older version of PS or upgraded to 2012R2
  #$command = '$now = Get-Date; dir "$env:PROGRAMDATA\consul\logs" | where {$_.LastWriteTime -le $now.AddDays(-7)} | del -whatif'
  #$action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -command $($command)"
  #$trigger = New-ScheduledTaskTrigger -Daily -At 9am
  #Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "ConsulLogrotate" -Description "Log rotation for consul"

  #Uninstall service if it already exists. Stops the service first if it's running
  $service = Get-Service "consul" -ErrorAction SilentlyContinue
  if ($service) {
    Write-Host "Uninstalling existing service"
    if ($service.Status -eq "Running") {
      Write-Host "Stopping consul process ..."
      net stop consul | Out-Null
    }

    $service = Get-WmiObject -Class Win32_Service -Filter "Name='consul'"
    $service.delete() | Out-Null
  }

  Write-Host "Installing the consul service"
  # Install the service
  & $nssmBinPath install consul $(Join-Path $toolsPath "consul.exe") agent -config-dir=%PROGRAMDATA%\consul\config -data-dir=%PROGRAMDATA%\consul\data | Out-Null
  & $nssmBinPath set consul AppEnvironmentExtra GOMAXPROCS=$env:NUMBER_OF_PROCESSORS | Out-Null
  & $nssmBinPath set consul ObjectName NetworkService | Out-Null
  & $nssmBinPath set consul AppStdout "$env:PROGRAMDATA\consul\logs\consul-output.log" | Out-Null
  & $nssmBinPath set consul AppStderr "$env:PROGRAMDATA\consul\logs\consul-error.log" | Out-Null
  & $nssmBinPath set consul AppRotateBytes 10485760 | Out-Null
  & $nssmBinPath set consul AppRotateFiles 1 | Out-Null
  & $nssmBinPath set consul AppRotateOnline 1 | Out-Null

  # Restart service on failure natively via Windows sc. There is a memory leak if service restart is performed via NSSM
  # The NSSM configuration will set the default behavior of NSSM to stop the service if
  # consul fails (for example, unable to resolve cluster) and end the nssm.exe and consul.exe process.
  # The sc configuration will set Recovery under the Consul service properties such that a new instance will be started on failure,
  # spawning new nssm.exe and consul.exe processes. In short, nothing changed from a functionality perspective (the service will
  # still attempt to restart on failure) but this method kills the nssm.exe process thus avoiding memory hog.
  & $nssmBinPath set consul AppExit Default Exit | Out-Null
  cmd.exe /c "sc failure consul reset= 0 actions= restart/60000" | Out-Null

  Write-ChocolateySuccess 'consul'
} catch {
  Write-ChocolateyFailure 'consul' $($_.Exception.Message)
  throw
}