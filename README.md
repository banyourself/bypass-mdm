# Bypass MDM - fixed fork (for a broken Recovery setup)

A fixed, reworked fork of [assafdori/bypass-mdm](https://github.com/assafdori/bypass-mdm)
by [Assaf Dori](https://assafdori.com). The original is an excellent tool. This
fork exists because the original v1 script failed on one specific MacBook Air in
known ways, and v2 failed earlier there for an unknown reason.

You are almost certainly fine using the upstream repo. Use this fork only if you
hit the same three problems it fixes.

## What the original v1 got wrong, and what this fork fixes

1. **A broken temporary account.** The original always created the temp user
   with UniqueID 501. If the Mac already has an account on 501 (this Mac's
   `admin` does), the user record is created *without* a usable UID - the login
   screen shakes and rejects the password, even though the record exists.
   This fork deletes the broken record and recreates the user with the first
   free UID (501-599 scan). It picks 502 here.
2. **Silently ineffective MDM suppression.** The original wrote `/etc/hosts`
   and the `.cloudConfig*` flags into `/Volumes/Macintosh HD/...`, which is the
   *sealed* system volume on Catalina and later - those writes did nothing.
   This fork writes them where they actually live, on the Data volume -
   `/Volumes/Data/private/etc/hosts` and
   `/Volumes/Data/private/var/db/ConfigurationProfiles/Settings/`.
3. **Fake success.** The original printed "MDM enrollment has been bypassed!"
   unconditionally. Every step here is checked. A failed step stops the script
   and shows the error.

Plus one environment fix - this Mac's Recovery environment is missing `/usr/bin/basename`
(and friends), so the fork's first attempt died at volume detection. Everything
in this version is pure bash builtins - it only needs `curl`, `dscl`, `mkdir`,
`rm`, `touch`, and `chown`.

## Usage

Boot into Recovery (Apple Silicon - press and hold the power button until
"Loading startup options" shows, Intel - hold Cmd+R). Connect to WiFi, open
Terminal from the Utilities menu, and run this command

```bash
curl -L https://raw.githubusercontent.com/banyourself/bypass-mdm/main/bypass-mdm.sh -o bypass-mdm.sh && chmod +x ./bypass-mdm.sh && ./bypass-mdm.sh
```

The script finds the volumes by their content, not by assuming names (the data
volume is the one holding the user database - on this Mac that is system
"Macintosh HD" and data "Data"). It repairs or creates the temporary admin
account, blocks the enrollment domains, and clears the activation records.

Then follow these steps

1. Close Terminal and reboot.
2. At the login screen choose **Other...** and sign in as `Apple` / `1234`.
3. In System Settings, go to Users and Groups and create your real admin account.
4. Log out, sign into your real account, then delete the temporary `Apple`
   account with the minus button.

## What this does and does not do

This suppresses MDM *enrollment on this Mac* - it removes the local activation
records and blocks the enrollment endpoints, so the setup assistant skips the
Remote Management step. It does **not** remove the Mac from Apple Business
Manager - the serial number stays there and enrollment can return after a full
erase and reinstall. That limitation is inherent to the method, not a bug.

Use it on hardware you own or are authorized to manage. The original author and
this fork both disclaim liability - see the LICENSE.

## Files

- `bypass-mdm.sh` - the only script. Self-contained and single-purpose - it
  finds the volumes (by content markers, not by assuming names), repairs or
  creates the temporary admin account, and suppresses MDM enrollment.
- `README.md` - this file.

There is deliberately no second script. The upstream repository ships a
separate `bypass-mdm-v2.sh`, but it never worked on this Mac, and a second file
only made it easier to run the wrong one, so it is not included here.

## Credits

- Original project - [assafdori/bypass-mdm](https://github.com/assafdori/bypass-mdm)
  by Assaf Dori - all the underlying technique and the bulk of the code come
  from there. This fork only repairs the failure modes above.
- Fork maintainer - banyourself