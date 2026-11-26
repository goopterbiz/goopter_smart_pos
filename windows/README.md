# Goopter Smart POS on Windows

Prepares a Windows 10 or 11 (Home or Pro, 64-bit, version 2004 or later) computer as a Goopter Smart
POS till with one command. Open PowerShell with "Run as administrator" and run:

```powershell
irm https://install.goopter.com/windows | iex
```

If `install.goopter.com` is unreachable, use the GitHub address directly:

```powershell
irm https://raw.githubusercontent.com/goopterbiz/goopter_smart_pos/main/windows/install.ps1 | iex
```

The script asks for a Tailscale auth key, installs everything, validates the result and prints the
RustDesk ID and password once. Restart when it finishes (`Restart-Computer`). The till signs in as
`goopter_pos`, installs Goopter Smart POS on the first sign-in and starts it in kiosk mode.

## Architecture

| Part | How |
|---|---|
| Till user | `goopter_pos`, standard user, not an administrator, random 24-character password that nobody needs |
| Sign-in | Sysinternals Autologon (signature checked) signs in `goopter_pos` at boot. It stores the password encrypted, not in the registry in plain text |
| Kiosk | The Windows shell for `goopter_pos` only is replaced by `C:\ProgramData\GoopterPOS\launcher.ps1`, so there is no desktop, taskbar or Start menu. Task Manager is disabled for that user. Administrators keep the normal desktop. This works on Home and Pro, which have no Shell Launcher |
| App | The launcher installs the latest `desktop/v.*` release of this repo for `goopter_pos` on first sign-in, from a copy the installer downloaded and checked against the SHA-512 in `latest.yml`. The app is installed per user, so it updates itself without administrator rights. The app always opens in kiosk mode |
| Crash restart | The launcher starts the app again 2 s after it exits, or 10 s after an exit within 30 s of starting. It waits while the app runs, so an update restart does not start a second copy |
| Screen and power | Sleep, hibernate, screen timeout, screen saver and the sign-in on wake are off. First sign-in animation, privacy prompt and crash dialogs are off |
| Windows Update | Active hours 06:00 to 23:00. On Pro, no automatic restart while the till is signed in |
| Terminal sign-in key | Protected by Windows (DPAPI) for `goopter_pos` |
| Remote network | Tailscale in unattended mode, so it stays connected with nobody signed in to Tailscale |
| Remote desktop and support | RustDesk service on the public relay, random 16-character password set on every run. Windows has no Tailscale SSH, so support uses RustDesk |
| Files | `C:\ProgramData\GoopterPOS`: launcher, app installer, state and `install.log`. Administrators and SYSTEM can write there, users can only read |

## Options

Set options as environment variables in the same PowerShell window before the command:

```powershell
$env:GOOPTER_STORE = 'mystore'; irm https://install.goopter.com/windows | iex
```

| Variable | Default | Effect |
|---|---|---|
| `GOOPTER_STORE` | empty | Saves `mystore.goopter.com` in the app so it opens on the enrollment page. Ignored if the app already has a store |
| `TS_AUTHKEY` | prompt | Tailscale auth key. Prompted with hidden input when empty |
| `TS_HOSTNAME` | `pos-<store>-<id>` | Tailscale machine name |
| `TAILSCALE_JOIN` | `true` | `false` installs Tailscale without joining |
| `APP_REINSTALL` | `false` | `true` downloads the latest app installer again |

The script is safe to run again. It keeps the saved store, the Tailscale login and the installed app.
Every run sets a new RustDesk password and shows it once, so update the merchant record after any
run.

## Preparing a till

1. Install Windows 10 or 11, finish setup with any administrator account and connect to the Internet.
2. Create a Tailscale auth key that is reusable, pre-approved, tagged `tag:pos` and expires in 7 days
   or less.
3. Open PowerShell with "Run as administrator", run the command above and paste the key when asked.
4. Record the RustDesk ID and password from the end of the output in the merchant record.
5. Check that every line under "Validating" says `PASS`. `WARN` lines are allowed but read them.
6. `Restart-Computer`. The till signs in by itself, installs the app and starts it. The first start
   takes about a minute.

## Steps that stay manual

1. Installing Windows and creating the first administrator account.
2. Creating the Tailscale auth key.
3. Recording the RustDesk ID and password.
4. Terminal activation. On the till, enter the store name if it was not given as `GOOPTER_STORE`,
   then the terminal code on the enrollment page.
5. Installing drivers for USB receipt printers. Network printers need no setup.
6. Wi-Fi, if the till has no Ethernet.

## Reset a till

`reset.ps1` clears what the installer keeps between runs, so the next run starts clean. In
PowerShell with "Run as administrator":

```powershell
irm https://install.goopter.com/windows-reset | iex
irm https://install.goopter.com/windows | iex
Restart-Computer
```

It stops the launcher and Goopter Smart POS first, signs `goopter_pos` out, then removes:

- the app in `C:\Users\goopter_pos\AppData\Local\Programs` and its updater cache
- the app data `C:\Users\goopter_pos\AppData\Roaming\Goopter Smart POS` (saved store, cookies,
  terminal sign-in key, app log)
- the app's uninstall entry and shortcuts for `goopter_pos`
- the launcher, the downloaded app installer and the installer state in `C:\ProgramData\GoopterPOS`

Tailscale, RustDesk, the `goopter_pos` user and the system settings stay. The till must be enrolled
again with a new terminal code. Until the installer runs and the till restarts, `goopter_pos` signs in
to a black screen.

## Using the till as an administrator

The till signs in as `goopter_pos` at every boot. To reach the normal desktop, connect with RustDesk,
press Ctrl+Alt+Del, choose "Sign out", and sign in with an administrator account. Restart to return to
the kiosk.

## Troubleshooting

| Symptom | Check |
|---|---|
| Installer stopped | `C:\ProgramData\GoopterPOS\install.log`. The last `ERROR` line names the failed step. Fix the cause and run the command again |
| PowerShell says scripts are disabled or TLS fails | Run `Set-ExecutionPolicy -Scope Process Bypass` and `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'` in the same window, then the command again |
| Black screen after restart | Sign in as an administrator and read `C:\Users\goopter_pos\AppData\Local\GoopterPOS\launcher.log`. Check that `C:\ProgramData\GoopterPOS\launcher.ps1` and `setup\Goopter-Smart-POS-Setup.exe` exist |
| App keeps restarting | `launcher.log` lists each start and exit code |
| Windows shows the sign-in screen instead of the kiosk | Automatic sign-in failed. Rerun the installer, which sets a new `goopter_pos` password and Autologon again |
| Wrong app version | The app updates itself. A new install uses the latest release: run the reset and the installer |
| Till not in Tailscale | `& "$env:ProgramFiles\Tailscale\tailscale.exe" status`. Rejoin with `tailscale up --unattended --auth-key=<key>` |
| RustDesk offline | `Get-Service RustDesk`, `& "$env:ProgramFiles\RustDesk\rustdesk.exe" --get-id | more` |

## Testing status

Checked on Linux only: both scripts parse, and PSScriptAnalyzer finds no Windows PowerShell 5.1
syntax or cmdlet compatibility problems. Not yet run on Windows.
