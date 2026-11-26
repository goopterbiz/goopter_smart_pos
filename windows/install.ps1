$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$PosUser = 'goopter_pos'
$AppRepo = 'goopterbiz/goopter_smart_pos'
$BaseDir = Join-Path $env:ProgramData 'GoopterPOS'
$SetupDir = Join-Path $BaseDir 'setup'
$SetupPath = Join-Path $SetupDir 'Goopter-Smart-POS-Setup.exe'
$LauncherPath = Join-Path $BaseDir 'launcher.ps1'
$StateDir = Join-Path $BaseDir 'state'
$LogFile = Join-Path $BaseDir 'install.log'
$TailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$RustDeskExe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
$HiveKey = 'HKU\GoopterPOS'

$Store = "$env:GOOPTER_STORE"
$TsAuthKey = "$env:TS_AUTHKEY"
$TsHostname = "$env:TS_HOSTNAME"
$TailscaleJoin = if ($env:TAILSCALE_JOIN) { $env:TAILSCALE_JOIN } else { 'true' }
$AppReinstall = if ($env:APP_REINSTALL) { $env:APP_REINSTALL } else { 'false' }

$script:WorkDir = $null
$script:RustDeskPassword = $null
$script:Failed = $false

function Write-PosLog([string]$Message) {
    $line = '{0} [goopter-pos] {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "$FilePath exited with code $($p.ExitCode)" }
}

function Invoke-Capture([string]$FilePath, [string[]]$Arguments) {
    $out = Join-Path $script:WorkDir ([guid]::NewGuid().ToString() + '.txt')
    Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -NoNewWindow -RedirectStandardOutput $out | Out-Null
    $text = ''
    if (Test-Path $out) { $text = [string](Get-Content -Path $out -Raw) }
    Remove-Item -Path $out -Force -ErrorAction SilentlyContinue
    return $text.Trim()
}

function Get-File([string]$Url, [string]$Path) {
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
}

function Test-Signature([string]$Path, [string]$Signer) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*$Signer*") {
        throw "$Path is not validly signed by $Signer (status $($sig.Status))"
    }
}

function New-RandomPassword([int]$Length) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Test-Preflight {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in PowerShell opened with "Run as administrator"'
    }
    if (-not [Environment]::Is64BitOperatingSystem) { throw '64-bit Windows is required' }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) { throw "Windows 10 version 2004 or later is required, this is build $build" }
    foreach ($pair in @(@('TAILSCALE_JOIN', $TailscaleJoin), @('APP_REINSTALL', $AppReinstall))) {
        if ($pair[1] -ne 'true' -and $pair[1] -ne 'false') { throw "$($pair[0]) must be true or false" }
    }
    if ($Store -and $Store -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
        throw "GOOPTER_STORE must be the store subdomain, for example 'mystore' for mystore.goopter.com"
    }
    Invoke-WebRequest -Uri 'https://api.github.com' -UseBasicParsing -TimeoutSec 15 | Out-Null
}

function Initialize-Directories {
    foreach ($dir in @($BaseDir, $SetupDir, $StateDir)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    }
    & icacls.exe $BaseDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $BaseDir" }
    $script:WorkDir = Join-Path $env:TEMP ('goopter-pos-' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:WorkDir | Out-Null
}

function Set-PosUser {
    Write-PosLog "Configuring user $PosUser"
    $password = ConvertTo-SecureString (New-RandomPassword 24) -AsPlainText -Force
    $user = Get-LocalUser -Name $PosUser -ErrorAction SilentlyContinue
    if ($user) {
        Set-LocalUser -Name $PosUser -Password $password -PasswordNeverExpires $true
        Enable-LocalUser -Name $PosUser
    } else {
        $user = New-LocalUser -Name $PosUser -Password $password -FullName 'Goopter POS' -Description 'Goopter Smart POS kiosk' -PasswordNeverExpires -UserMayNotChangePassword
    }
    try {
        Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545') -Member $PosUser -ErrorAction Stop
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        Write-Verbose "$PosUser is already in Users"
    }
    Remove-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544') -Member $PosUser -ErrorAction SilentlyContinue
    $script:PosSid = $user.SID.Value
    return $password
}

function Initialize-Profile {
    $listKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$script:PosSid"
    if (-not (Test-Path $listKey)) {
        Write-PosLog "Creating the profile for $PosUser"
        Add-Type -Namespace GoopterPos -Name UserEnv -MemberDefinition @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@
        $sb = New-Object System.Text.StringBuilder 260
        $hr = [GoopterPos.UserEnv]::CreateProfile($script:PosSid, $PosUser, $sb, 260)
        if ($hr -ne 0 -and $hr -ne -2147024713) { throw ('CreateProfile failed with 0x{0:X8}' -f $hr) }
    }
    $script:ProfileDir = (Get-ItemProperty -Path $listKey).ProfileImagePath
    if (-not (Test-Path (Join-Path $script:ProfileDir 'NTUSER.DAT'))) { throw "No NTUSER.DAT in $script:ProfileDir" }
}

function Set-UserRegistry([string]$SubKey, [string]$Name, [string]$Type, [string]$Data) {
    $loaded = Test-Path "Registry::HKEY_USERS\$script:PosSid"
    $root = if ($loaded) { "HKU\$script:PosSid" } else { $HiveKey }
    & reg.exe add "$root\$SubKey" /v $Name /t $Type /d $Data /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg add $SubKey\$Name failed" }
}

function Set-UserSettings {
    Write-PosLog 'Configuring the kiosk shell for the POS user'
    $loaded = Test-Path "Registry::HKEY_USERS\$script:PosSid"
    if (-not $loaded) {
        & reg.exe load $HiveKey (Join-Path $script:ProfileDir 'NTUSER.DAT') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'reg load of the POS user hive failed' }
    }
    try {
        $shell = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherPath`""
        Set-UserRegistry 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Shell' 'REG_SZ' $shell
        Set-UserRegistry 'Software\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableTaskMgr' 'REG_DWORD' '1'
        Set-UserRegistry 'Control Panel\Desktop' 'ScreenSaveActive' 'REG_SZ' '0'
        Set-UserRegistry 'Control Panel\Desktop' 'ScreenSaverIsSecure' 'REG_SZ' '0'
        Set-UserRegistry 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    } finally {
        if (-not $loaded) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload $HiveKey | Out-Null
        }
    }
}

function Set-Launcher {
    Write-PosLog 'Writing the kiosk launcher'
    $launcher = @'
$ErrorActionPreference = 'Continue'
$Setup = Join-Path $env:ProgramData 'GoopterPOS\setup\Goopter-Smart-POS-Setup.exe'
$LogDir = Join-Path $env:LOCALAPPDATA 'GoopterPOS'
$Log = Join-Path $LogDir 'launcher.log'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
function Write-LauncherLog([string]$Message) { Add-Content -Path $Log -Value ('{0} {1}' -f (Get-Date -Format o), $Message) }
function Find-App {
    $programs = Join-Path $env:LOCALAPPDATA 'Programs'
    foreach ($dir in @('goopter-smart-pos', 'Goopter Smart POS')) {
        $exe = Join-Path $programs "$dir\Goopter Smart POS.exe"
        if (Test-Path $exe) { return $exe }
    }
    $found = Get-ChildItem -Path $programs -Filter 'Goopter Smart POS.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}
while ($true) {
    while (Get-Process -Name 'Goopter Smart POS' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
    $app = Find-App
    if (-not $app) {
        if (Test-Path $Setup) {
            Write-LauncherLog 'Installing Goopter Smart POS'
            Start-Process -FilePath $Setup -ArgumentList '/S' -Wait
        } else {
            Write-LauncherLog "Setup not found at $Setup"
        }
        Start-Sleep -Seconds 10
        continue
    }
    $started = Get-Date
    Write-LauncherLog "Starting $app"
    $p = Start-Process -FilePath $app -PassThru
    $p.WaitForExit()
    Write-LauncherLog "Goopter Smart POS exited with code $($p.ExitCode)"
    if (((Get-Date) - $started).TotalSeconds -lt 30) { Start-Sleep -Seconds 10 } else { Start-Sleep -Seconds 2 }
}
'@
    Set-Content -Path $LauncherPath -Value $launcher -Encoding UTF8
}

function Set-AutoLogon([Security.SecureString]$Password) {
    Write-PosLog 'Configuring automatic sign-in with Sysinternals Autologon'
    $zip = Join-Path $script:WorkDir 'AutoLogon.zip'
    Get-File 'https://download.sysinternals.com/files/AutoLogon.zip' $zip
    Expand-Archive -Path $zip -DestinationPath (Join-Path $script:WorkDir 'autologon') -Force
    $exe = Join-Path $script:WorkDir 'autologon\Autologon64.exe'
    Test-Signature $exe 'Microsoft Corporation'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Invoke-Native $exe @($PosUser, $env:COMPUTERNAME, $plain, '/accepteula')
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Set-SystemSettings {
    Write-PosLog 'Disabling sleep, hibernate, screen timeout and the wake sign-in'
    foreach ($a in @('standby-timeout-ac', 'standby-timeout-dc', 'monitor-timeout-ac', 'monitor-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc')) {
        & powercfg.exe /change $a 0 | Out-Null
    }
    & powercfg.exe /hibernate off | Out-Null
    & powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null
    & powercfg.exe /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null
    & powercfg.exe /SETACTIVE SCHEME_CURRENT | Out-Null

    Write-PosLog 'Configuring first sign-in, error dialogs and Windows Update restarts'
    $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty -Path $sys -Name 'EnableFirstLogonAnimation' -Value 0 -Type DWord
    $oobe = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
    if (-not (Test-Path $oobe)) { New-Item -Path $oobe -Force | Out-Null }
    Set-ItemProperty -Path $oobe -Name 'DisablePrivacyExperience' -Value 1 -Type DWord
    $wer = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
    Set-ItemProperty -Path $wer -Name 'DontShowUI' -Value 1 -Type DWord
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    if (-not (Test-Path $ux)) { New-Item -Path $ux -Force | Out-Null }
    Set-ItemProperty -Path $ux -Name 'ActiveHoursStart' -Value 6 -Type DWord
    Set-ItemProperty -Path $ux -Name 'ActiveHoursEnd' -Value 23 -Type DWord
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
    Set-ItemProperty -Path $au -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
}

function Get-AppSetup {
    if ((Test-Path $SetupPath) -and $AppReinstall -ne 'true') {
        Write-PosLog 'The app installer is already downloaded. Set APP_REINSTALL=true to download the latest one'
        return
    }
    Write-PosLog "Finding the latest desktop release of $AppRepo"
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$AppRepo/releases?per_page=30" -UseBasicParsing
    $desktop = @($releases | Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -like 'desktop/*' })
    if ($desktop.Count -eq 0) { throw "no published desktop release found in $AppRepo" }
    $latest = $desktop | Sort-Object { [version](($_.tag_name -replace '^desktop/v\.?', '')) } | Select-Object -Last 1
    $base = "https://github.com/$AppRepo/releases/download/$($latest.tag_name)"
    $yml = Join-Path $script:WorkDir 'latest.yml'
    Get-File "$base/latest.yml" $yml
    $text = Get-Content -Path $yml -Raw
    $file = [regex]::Match($text, '(?m)^path:\s*(\S+)').Groups[1].Value
    $sha = [regex]::Match($text, '(?m)^sha512:\s*(\S+)').Groups[1].Value
    if (-not $file -or -not $sha) { throw "latest.yml in $($latest.tag_name) has no installer entry" }
    Write-PosLog "Downloading $file from $($latest.tag_name)"
    $download = Join-Path $script:WorkDir 'setup.exe'
    Get-File "$base/$file" $download
    $stream = [IO.File]::OpenRead($download)
    try { $actual = [Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash($stream)) } finally { $stream.Dispose() }
    if ($actual -ne $sha) { throw "SHA-512 of $file does not match latest.yml" }
    Copy-Item -Path $download -Destination $SetupPath -Force
    Set-Content -Path (Join-Path $StateDir 'installed-release') -Value $latest.tag_name
}

function Set-Store {
    if (-not $Store) { return }
    $dir = Join-Path $script:ProfileDir 'AppData\Roaming\Goopter Smart POS'
    $file = Join-Path $dir 'store.json'
    if (Test-Path $file) {
        Write-PosLog 'A store is already saved in the app, leaving it unchanged'
        return
    }
    Write-PosLog "Saving store $Store.goopter.com in the app"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllText($file, ('{"slug":"' + $Store + '"}'))
    & icacls.exe $dir /setowner $PosUser /T | Out-Null
    & icacls.exe $dir /grant "${PosUser}:(OI)(CI)F" /T | Out-Null
}

function Get-TailscaleState {
    if (-not (Test-Path $TailscaleExe)) { return 'Missing' }
    try {
        $json = Invoke-Capture $TailscaleExe @('status', '--json')
        return ($json | ConvertFrom-Json).BackendState
    } catch {
        return 'Unknown'
    }
}

function Install-Tailscale {
    if (-not (Test-Path $TailscaleExe)) {
        Write-PosLog 'Installing Tailscale'
        $msi = Join-Path $script:WorkDir 'tailscale.msi'
        Get-File 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' $msi
        Test-Signature $msi 'Tailscale'
        Invoke-Native 'msiexec.exe' @('/i', "`"$msi`"", '/qn', '/norestart', 'TS_UNATTENDEDMODE=always')
    }
    Set-Service -Name 'Tailscale' -StartupType Automatic
    Start-Service -Name 'Tailscale'
    Start-Sleep -Seconds 3
    if ((Get-TailscaleState) -eq 'Running') {
        Write-PosLog 'Tailscale is already joined'
        return
    }
    if ($TailscaleJoin -ne 'true') {
        Write-PosLog 'WARNING: TAILSCALE_JOIN=false, Tailscale is installed but not joined'
        return
    }
    $key = $TsAuthKey
    if (-not $key -and [Environment]::UserInteractive) {
        $secure = Read-Host -Prompt 'Tailscale auth key (input hidden)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $key) { throw 'TS_AUTHKEY is required to join Tailscale. Set TAILSCALE_JOIN=false to skip' }
    $machineId = ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -replace '-', '').Substring(0, 6).ToLower()
    $storePart = if ($Store) { $Store } else { 'unassigned' }
    $name = if ($TsHostname) { $TsHostname } else { "pos-$storePart-$machineId" }
    $keyFile = Join-Path $script:WorkDir 'ts-authkey'
    [IO.File]::WriteAllText($keyFile, $key)
    try {
        Write-PosLog "Joining Tailscale as $name"
        Invoke-Native $TailscaleExe @('up', "--auth-key=file:$keyFile", '--unattended', "--hostname=$name")
    } finally {
        Remove-Item -Path $keyFile -Force -ErrorAction SilentlyContinue
    }
}

function Install-RustDesk {
    if (-not (Test-Path $RustDeskExe)) {
        Write-PosLog 'Installing RustDesk'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -match '^rustdesk-[0-9.]+-x86_64\.msi$' } | Select-Object -First 1
        if (-not $asset) { throw 'no RustDesk x86_64 .msi found in the latest release' }
        $msi = Join-Path $script:WorkDir 'rustdesk.msi'
        Get-File $asset.browser_download_url $msi
        Invoke-Native 'msiexec.exe' @('/i', "`"$msi`"", '/qn', '/norestart')
    }
    $configs = @(Join-Path $env:windir 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml')
    $configs += Get-ChildItem -Path 'C:\Users\*\AppData\Roaming\RustDesk\config\RustDesk2.toml' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    foreach ($conf in $configs) {
        if ((Test-Path $conf) -and (Select-String -Path $conf -Pattern '^stop-service\s*=' -Quiet)) {
            Write-PosLog "Clearing the RustDesk stop-service setting in $conf"
            Stop-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
            (Get-Content -Path $conf) | Where-Object { $_ -notmatch '^stop-service\s*=' } | Set-Content -Path $conf
        }
    }
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    Set-Service -Name 'RustDesk' -StartupType Automatic
    Start-Service -Name 'RustDesk'
    Start-Sleep -Seconds 5

    if (-not [Environment]::UserInteractive) {
        Write-PosLog 'WARNING: no console to show a new RustDesk password, it was not set. Rerun the installer from an administrator PowerShell'
        return
    }
    $password = New-RandomPassword 16
    $out = Invoke-Capture $RustDeskExe @('--password', $password)
    if ($out -like '*Done!*') {
        $script:RustDeskPassword = $password
        Set-Content -Path (Join-Path $StateDir 'rustdesk-password-set') -Value (Get-Date -Format o)
        Write-PosLog 'RustDesk password set. It is shown once at the end and is not logged'
    } else {
        Write-PosLog "WARNING: RustDesk did not accept the password ($out)"
    }
}

function Test-NotAdmin {
    $group = (Get-LocalGroup -SID 'S-1-5-32-544').Name
    $members = & net.exe localgroup $group
    return -not ($members | Where-Object { $_.Trim() -eq $PosUser -or $_.Trim() -like "*\$PosUser" })
}

function Test-Install {
    Write-PosLog 'Validating'
    $checks = @(
        @('FAIL', "user $PosUser exists", { [bool](Get-LocalUser -Name $PosUser -ErrorAction SilentlyContinue) }),
        @('FAIL', "user $PosUser is not an administrator", { Test-NotAdmin }),
        @('FAIL', 'automatic sign-in is configured', { $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; $w.AutoAdminLogon -eq '1' -and $w.DefaultUserName -eq $PosUser }),
        @('FAIL', 'kiosk launcher is installed', { Test-Path $LauncherPath }),
        @('FAIL', 'Goopter Smart POS installer is downloaded', { Test-Path $SetupPath }),
        @('FAIL', 'hibernate is off', { -not (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power').HibernateEnabled }),
        @('FAIL', 'Tailscale service is running', { (Get-Service -Name 'Tailscale').Status -eq 'Running' }),
        @($(if ($TailscaleJoin -eq 'true') { 'FAIL' } else { 'WARN' }), 'Tailscale is joined', { (Get-TailscaleState) -eq 'Running' }),
        @('FAIL', 'RustDesk service is running', { (Get-Service -Name 'RustDesk').Status -eq 'Running' }),
        @('WARN', 'RustDesk password is set', { Test-Path (Join-Path $StateDir 'rustdesk-password-set') })
    )
    foreach ($c in $checks) {
        $ok = $false
        try { $ok = [bool](& $c[2]) } catch { $ok = $false }
        if ($ok) { Write-PosLog "PASS  $($c[1])" } else {
            Write-PosLog "$($c[0])  $($c[1])"
            if ($c[0] -eq 'FAIL') { $script:Failed = $true }
        }
    }
}

function Write-Summary {
    $id = ''
    if (Test-Path $RustDeskExe) { $id = Invoke-Capture $RustDeskExe @('--get-id') }
    $release = Get-Content -Path (Join-Path $StateDir 'installed-release') -ErrorAction SilentlyContinue
    Write-PosLog "Done. Goopter Smart POS release: $release"
    Write-PosLog "Tailscale: $(Get-TailscaleState)"
    Write-PosLog "RustDesk ID: $id"
    if ($script:RustDeskPassword) {
        Write-Host ''
        Write-Host "RustDesk ID: $id"
        Write-Host "RustDesk password: $($script:RustDeskPassword)"
        Write-Host 'Record both in the merchant record now. The password is not shown again.'
        Write-Host ''
    }
    Write-PosLog 'Restart to start the kiosk: Restart-Computer'
}

function Install-GoopterPos {
    Test-Preflight
    Initialize-Directories
    Add-Content -Path $LogFile -Value ('{0}===== {1} =====' -f [Environment]::NewLine, (Get-Date -Format o))
    Write-PosLog 'Goopter Smart POS provisioning started'
    $password = Set-PosUser
    Initialize-Profile
    Set-Launcher
    Set-UserSettings
    Set-AutoLogon $password
    Set-SystemSettings
    Get-AppSetup
    Set-Store
    Install-Tailscale
    Install-RustDesk
    Test-Install
    if ($script:Failed) { throw "validation failed, see the FAIL lines above and $LogFile" }
    Set-Content -Path (Join-Path $StateDir 'provisioned') -Value (Get-Date -Format o)
    Write-Summary
}

try {
    Install-GoopterPos
} catch {
    $msg = "ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber)). Full log: $LogFile"
    if (Test-Path $BaseDir) { Write-PosLog $msg } else { Write-Host $msg -ForegroundColor Red }
} finally {
    if ($script:WorkDir -and (Test-Path $script:WorkDir)) { Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}
