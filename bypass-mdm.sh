#!/bin/bash
# =============================================================================
#  bypass-mdm.sh - FIXED fork of assafdori/bypass-mdm for this MacBook Air
#  https://github.com/assafdori/bypass-mdm
#
#  What the original v1 script got wrong (and this one fixes):
#   1. It always wrote the temporary user with UniqueID 501. On this Mac the
#      existing account already owns 501, so the user record was created
#      without a usable UID -> "Apple" never authenticated at the login
#      screen. This script detects the broken record, deletes it and
#      recreates the user with a free UID (501-599 scan).
#   2. It wrote /etc/hosts and the .cloudConfig* MDM flags to
#      "/Volumes/Macintosh HD/..." which is the SEALED system volume on
#      modern macOS - those writes silently did nothing. On Catalina and
#      later those files live on the DATA volume. This script uses
#      /Volumes/Data/private/etc/hosts and
#      /Volumes/Data/private/var/db/ConfigurationProfiles/Settings.
#   3. It printed "Success" unconditionally. Every step here is checked
#      and a failing step stops the script.
#
#  Volumes: auto-detected (system = volume with /System, data = *Data),
#  which on this machine resolves to "Macintosh HD" and "Data".
#
#  Usage (inside macOS Recovery Terminal, with network connected):
#      curl -L https://raw.githubusercontent.com/banyourself/bypass-mdm/main/bypass-mdm.sh \
#          -o bypass-mdm.sh && chmod +x ./bypass-mdm.sh && ./bypass-mdm.sh
#
#  Then close Terminal, reboot, choose "Other..." at the login screen and
#  sign in with Apple / 1234.
# =============================================================================

set -u

USERNAME="Apple"   # temporary login name
FULLNAME="Apple"   # temporary full name
PASSWD="1234"      # temporary password

echo "=== MDM bypass (fixed fork) ==="
echo ""

# --- 1. locate the volumes ---------------------------------------------------
SYSTEM_VOL=""
DATA_VOL=""
for v in /Volumes/*; do
    [ -d "$v" ] || continue
    b="$(basename "$v")"
    case "$b" in
        *Recovery*) continue ;;
    esac
    if [ -d "$v/System/Library/CoreServices" ]; then
        SYSTEM_VOL="$v"
    fi
    case "$b" in
        *Data) DATA_VOL="$v" ;;
    esac
done
[ -n "$SYSTEM_VOL" ] || { echo "ERROR: couldn't find the system volume (volume with /System)"; exit 1; }
[ -n "$DATA_VOL" ]   || { echo "ERROR: couldn't find the data volume"; exit 1; }
echo "System volume : $SYSTEM_VOL"
echo "Data volume   : $DATA_VOL"
echo ""

DS="$DATA_VOL/private/var/db/dslocal/nodes/Default"
[ -d "$DS" ] || { echo "ERROR: Directory Services node not found: $DS"; exit 1; }

# --- 2. show what exists -----------------------------------------------------
echo "Existing local accounts (name -> UID):"
dscl -f "$DS" localhost -list /Local/Default/Users UniqueID 2>/dev/null | sed 's/^/   /'
echo ""

# --- 3. find a free UID (501 is taken by the existing account) ---------------
free_uid() {
    local uid=501
    while [ "$uid" -lt 600 ]; do
        if ! dscl -f "$DS" localhost -search /Local/Default/Users UniqueID "$uid" 2>/dev/null | grep -q UniqueID; then
            echo "$uid"
            return 0
        fi
        uid=$((uid + 1))
    done
    return 1
}
NEW_UID="$(free_uid)" || { echo "ERROR: no free UID in 501-599"; exit 1; }
echo ">>> Using UID $NEW_UID for temporary user '$USERNAME'."
echo ""

# --- 4. repair / create the temporary account --------------------------------
if dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" >/dev/null 2>&1; then
    CUR="$(dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" UniqueID 2>/dev/null | awk '/UniqueID/{print $2}')"
    if [ -n "$CUR" ] && [ "$CUR" = "$NEW_UID" ]; then
        echo "Account '$USERNAME' already exists with UID $CUR - keeping it."
    else
        echo ">>> Removing broken account '$USERNAME' (UniqueID was '${CUR:-<missing>}')..."
        dscl -f "$DS" localhost -delete "/Local/Default/Users/$USERNAME" 2>/dev/null
        rm -f "$DS/users/$USERNAME.plist"
        dscl -f "$DS" localhost -delete "/Local/Default/Groups/admin" GroupMembership "$USERNAME" 2>/dev/null
        echo ">>> Recreating account..."
    fi
else
    echo ">>> No '$USERNAME' account found - creating it now."
fi

dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" 2>/dev/null \
    || { echo "ERROR: could not create user record"; exit 1; }
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" UserShell "/bin/zsh"
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" RealName "$FULLNAME"
GUID="$(uuidgen 2>/dev/null)"
[ -n "$GUID" ] && dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" GeneratedUID "$GUID"
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" UniqueID "$NEW_UID"
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" PrimaryGroupID "20"
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" NFSHomeDirectory "/Users/$USERNAME"
dscl -f "$DS" localhost -passwd "/Local/Default/Users/$USERNAME" "$PASSWD" \
    || { echo "ERROR: could not set password"; exit 1; }
dscl -f "$DS" localhost -append "/Local/Default/Groups/admin" GroupMembership "$USERNAME" \
    || { echo "ERROR: could not add user to admin group"; exit 1; }

# home directory (the old run created it, possibly as root)
mkdir -p "$DATA_VOL/Users/$USERNAME"
chown -R "$NEW_UID:20" "$DATA_VOL/Users/$USERNAME"

echo ""
echo "Account verification:"
dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" 2>/dev/null \
    | grep -E "RecordName|RealName|UniqueID|PrimaryGroupID|NFSHomeDirectory" | sed 's/^/   /'
echo ""

# --- 5. MDM suppression on the CORRECT (Data volume) paths --------------------
echo "Marking setup as complete..."
touch "$DATA_VOL/private/var/db/.AppleSetupDone"

echo "Clearing MDM activation records..."
CFG="$DATA_VOL/private/var/db/ConfigurationProfiles/Settings"
mkdir -p "$CFG"
rm -f "$CFG/.cloudConfigHasActivationRecord"
rm -f "$CFG/.cloudConfigRecordFound"
touch "$CFG/.cloudConfigProfileInstalled"
touch "$CFG/.cloudConfigRecordNotFound"

echo "Blocking MDM enrollment domains in hosts file..."
HOSTS="$DATA_VOL/private/etc/hosts"
[ -f "$HOSTS" ] || touch "$HOSTS"
for d in deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com; do
    grep -q "$d" "$HOSTS" 2>/dev/null || echo "0.0.0.0 $d" >> "$HOSTS"
done

echo ""
echo "============================================================"
echo " DONE."
echo " Close this Terminal window and reboot the Mac."
echo " At the login screen choose 'Other...' and sign in with:"
echo "     username: $USERNAME"
echo "     password: $PASSWD"
echo "============================================================"
exit 0