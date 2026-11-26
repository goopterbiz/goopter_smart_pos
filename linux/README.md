# Goopter Smart POS on Ubuntu

Prepares an Ubuntu 26.04 LTS x86_64 computer as a Goopter Smart POS till with one command.

```sh
curl -fsSL https://install.goopter.com/linux | sudo bash
```

If `install.goopter.com` is unreachable, use the GitHub address directly:

```sh
curl -fsSL https://raw.githubusercontent.com/goopterbiz/goopter_smart_pos/main/linux/install.sh | sudo bash
```

The script asks for a Tailscale auth key, installs everything, validates the result and prints the
RustDesk ID and password once. Reboot when it finishes. The till then starts straight into Goopter
Smart POS.

## Architecture

| Part | How |
|---|---|
| Till user | `goopter_pos`, password locked, no sudo, groups `lp`, `dialout`, `audio`, `video` |
| Display | Xorg with LightDM auto-login into a dedicated `goopter-pos` session running Openbox. No GNOME desktop. RustDesk needs X11 for unattended access, and Ubuntu 26.04 GNOME is Wayland only |
| App | The latest `desktop/v.*` release of this repo, installed as `/home/goopter_pos/Applications/GoopterSmartPOS.AppImage` after its SHA-512 is checked against `latest-linux.yml`. The file belongs to `goopter_pos`, so the app updates itself without root. The app always opens in kiosk mode |
| Crash restart | `/usr/local/bin/goopter-pos-session` starts the app again 2 s after it exits, or 10 s after an exit within 30 s of starting. It waits while another instance runs, so the app's own "Restart and install" does not start a second copy |
| Screen and power | Screen saver, blanking and DPMS off. Sleep, suspend and hibernate masked. Lid and idle actions ignored |
| Terminal sign-in key | Stored in an unlocked `login` keyring with an empty password, so it opens without anyone typing at boot. Anyone who can read `goopter_pos` files can read that key |
| Electron sandbox | AppArmor profile `goopter-smart-pos` allows user namespaces for the AppImage binary |
| Remote shell | Tailscale with Tailscale SSH. No local admin account and no OpenSSH server |
| Remote desktop | RustDesk on the public relay, system service, random 16-character password per till |
| Printing | CUPS installed. USB printers are added by support over Tailscale SSH (`lpadmin`) |

## Options

Pass options as environment variables after `sudo`:

```sh
curl -fsSL https://install.goopter.com/linux | sudo GOOPTER_STORE=mystore bash
```

| Variable | Default | Effect |
|---|---|---|
| `GOOPTER_STORE` | empty | Saves `mystore.goopter.com` in the app so it opens on the enrollment page. Ignored if the app already has a store |
| `TS_AUTHKEY` | prompt | Tailscale auth key. Prompted with hidden input when empty |
| `TS_HOSTNAME` | `pos-<store>-<id>` | Tailscale machine name |
| `TAILSCALE_JOIN` | `true` | `false` installs Tailscale without joining |
| `APP_REINSTALL` | `false` | `true` replaces the installed app with the latest release |

The script is safe to run again. It keeps the saved store, the keyring, the Tailscale login and the
installed app unless an option above says otherwise. Every run sets a new RustDesk password and
shows it once, so update the merchant record after any run. A run without a terminal, such as the
USB first boot, leaves the RustDesk password unchanged.

## One-time Tailscale setup

1. In the Tailscale admin console, add the tag and SSH rule to the tailnet policy:

   ```json
   "tagOwners": { "tag:pos": ["group:goopter-support"] },
   "ssh": [
     { "action": "accept", "src": ["group:goopter-support"], "dst": ["tag:pos"], "users": ["root", "goopter_pos"] }
   ]
   ```

2. For each batch of tills, create an auth key that is reusable, pre-approved, tagged `tag:pos` and
   expires in 7 days or less. Do not store it in this repo.

Support connects with `tailscale ssh root@<machine-name>`.

## Preparing a till

1. Install Ubuntu 26.04 LTS (Desktop or Server) and connect it to the Internet.
2. Run the command above in a terminal and paste the Tailscale auth key when asked.
3. Record the RustDesk ID and password from the end of the output in the merchant record.
4. Check that every line under "Validating" says `PASS`. `WARN` lines are allowed but read them.
5. `sudo reboot`. The till starts into Goopter Smart POS.

## Steps that stay manual

1. Creating the Tailscale auth key.
2. Recording the RustDesk ID and password.
3. Terminal activation. On the till, enter the store name if it was not given as `GOOPTER_STORE`,
   then the terminal code on the enrollment page.
4. Adding USB printers with `lpadmin` over Tailscale SSH. Network printers need no setup.
5. Wi-Fi, if the till has no Ethernet.

## Bootable USB (optional)

`autoinstall/user-data` installs Ubuntu Server minimal with no prompts, then on first boot downloads
and runs `install.sh` and reboots into the kiosk.

1. Replace `REPLACE_WITH_TAILSCALE_AUTH_KEY` with the batch key. Treat the USB drive as a secret
   until the key expires.
2. Write the Ubuntu 26.04 Server ISO to the USB drive and add `user-data` and an empty `meta-data`
   on a volume labelled `CIDATA`, or into the ISO's `/` with `autoinstall` on the kernel line.
3. Boot the till from the USB drive and confirm the autoinstall prompt. **This erases the till's
   largest disk.**
4. After the till restarts into the kiosk, set the RustDesk password over Tailscale SSH:

   ```sh
   sudo bash /usr/local/sbin/goopter-pos-install
   ```

`goopter_admin` is created with a locked password, so it cannot log in. It exists only because
autoinstall requires a user.

## Troubleshooting

| Symptom | Check |
|---|---|
| Installer stopped | `sudo less /var/log/goopter-pos-install.log`. The last `ERROR` line names the failed line. Fix the cause and run the command again |
| Black screen or login screen after reboot | `systemctl status lightdm`, `cat /etc/lightdm/lightdm.conf.d/50-goopter-pos.conf`, `/var/log/lightdm/lightdm.log` |
| App keeps restarting | `/home/goopter_pos/.local/state/goopter-pos-session.log` |
| App crashes at start with a sandbox error | `sudo aa-status | grep goopter`. Reload with `sudo apparmor_parser -r /etc/apparmor.d/goopter-smart-pos` |
| Terminal sign-in says the device is not secure | The keyring is locked or missing. `ls -l /home/goopter_pos/.local/share/keyrings/`. `login.keyring` must be the unencrypted file this script wrote |
| Wrong app version | The app updates itself. To force the latest: `sudo APP_REINSTALL=true bash /usr/local/sbin/goopter-pos-install`, or the curl command with `sudo APP_REINSTALL=true bash` |
| Till not in Tailscale | `tailscale status`. Rejoin with `sudo tailscale up --ssh --auth-key=<key>` |
| RustDesk offline | `systemctl status rustdesk`, `rustdesk --get-id` |
| Need to use the till directly | Support connects over Tailscale SSH. `sudo systemctl restart lightdm` restarts the kiosk session |

## Testing status

Tested in an Ubuntu 26.04 systemd container: install, rerun, app reinstall, store prefill, keyring
store and lookup without a prompt, Tailscale and RustDesk services, validation. Not yet tested on a
physical till: auto-login, the X session, the AppArmor profile, the Electron password store, RustDesk
screen sharing, and the USB autoinstall.
