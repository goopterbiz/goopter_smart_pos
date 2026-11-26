$ErrorActionPreference = 'Stop'

$PosUser = 'goopter_pos'
$BaseDir = Join-Path $env:ProgramData 'GoopterPOS'
$LogFile = Join-Path $BaseDir 'install.log'
$HiveKey = 'HKU\GoopterPOSReset'

function Write-PosLog([string]$Message) {
    $line = '{0} [goopter-pos-reset] {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    if (Test-Path $BaseDir) { Add-Content -Path $LogFile -Value $line -Encoding UTF8 }
}

function Get-PosProcess {
    Get-CimInstance -ClassName Win32_Process | Where-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
        $owner -and $owner.User -eq $PosUser
    }
}

function Stop-Pos {
    Write-PosLog 'Stopping Goopter Smart POS'
    $procs = @(Get-PosProcess)
    $launcher = $procs | Where-Object { $_.CommandLine -like '*GoopterPOS\launcher.ps1*' }
    foreach ($p in $launcher) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in ($procs | Where-Object { $_.Name -eq 'Goopter Smart POS.exe' })) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $sessions = @($procs | Select-Object -ExpandProperty SessionId -Unique | Where-Object { $_ -gt 0 })
    foreach ($p in @(Get-PosProcess)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $logoff = Join-Path $env:windir 'System32\logoff.exe'
    if (Test-Path $logoff) { foreach ($id in $sessions) { & $logoff $id 2>$null } }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Process -Name 'Goopter Smart POS' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if (Get-Process -Name 'Goopter Smart POS' -ErrorAction SilentlyContinue) { throw 'Goopter Smart POS is still running' }
    Write-PosLog 'Goopter Smart POS is stopped'
}

function Remove-PosPath([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-PosLog "Removed $Path"
    } else {
        Write-PosLog "Not present: $Path"
    }
}

function Remove-UninstallEntry([string]$Sid, [string]$ProfileDir) {
    $loaded = Test-Path "Registry::HKEY_USERS\$Sid"
    if (-not $loaded) {
        $hive = Join-Path $ProfileDir 'NTUSER.DAT'
        if (-not (Test-Path $hive)) { return }
        & reg.exe load $HiveKey $hive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'reg load of the POS user hive failed' }
    }
    $root = if ($loaded) { "HKEY_USERS\$Sid" } else { 'HKEY_USERS\GoopterPOSReset' }
    try {
        $keys = Get-ChildItem -Path "Registry::$root\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
        foreach ($k in $keys) {
            if ((Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).DisplayName -like 'Goopter Smart POS*') {
                $name = $k.PSChildName
                & reg.exe delete "$root\Software\Microsoft\Windows\CurrentVersion\Uninstall\$name" /f | Out-Null
                Write-PosLog "Removed the uninstall entry $name"
            }
        }
        $keys = $null
    } finally {
        if (-not $loaded) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload $HiveKey | Out-Null
        }
    }
}

function Reset-GoopterPos {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in PowerShell opened with "Run as administrator"'
    }
    if (Test-Path $BaseDir) { Add-Content -Path $LogFile -Value ('{0}===== {1} reset =====' -f [Environment]::NewLine, (Get-Date -Format o)) }
    Stop-Pos

    $user = Get-LocalUser -Name $PosUser -ErrorAction SilentlyContinue
    if ($user) {
        $sid = $user.SID.Value
        $listKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path $listKey) {
            $profileDir = (Get-ItemProperty -Path $listKey).ProfileImagePath
            Remove-PosPath (Join-Path $profileDir 'AppData\Local\Programs\goopter-smart-pos')
            Remove-PosPath (Join-Path $profileDir 'AppData\Local\Programs\Goopter Smart POS')
            Remove-PosPath (Join-Path $profileDir 'AppData\Local\goopter-smart-pos-updater')
            Remove-PosPath (Join-Path $profileDir 'AppData\Roaming\Goopter Smart POS')
            Remove-PosPath (Join-Path $profileDir 'AppData\Local\GoopterPOS')
            Remove-PosPath (Join-Path $profileDir 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Goopter Smart POS.lnk')
            Remove-PosPath (Join-Path $profileDir 'Desktop\Goopter Smart POS.lnk')
            Remove-UninstallEntry $sid $profileDir
        }
    } else {
        Write-PosLog "User $PosUser does not exist"
    }
    Remove-PosPath (Join-Path $BaseDir 'setup')
    Remove-PosPath (Join-Path $BaseDir 'state')
    Remove-PosPath (Join-Path $BaseDir 'launcher.ps1')
    Write-PosLog 'Reset done. The screen stays black for the POS user until the installer runs and the computer restarts'
    Write-PosLog 'Next: irm https://install.goopter.com/windows | iex'
}

try {
    Reset-GoopterPos
} catch {
    Write-PosLog "ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber)). Full log: $LogFile"
}
