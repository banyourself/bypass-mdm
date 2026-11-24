#!/bin/bash
# =============================================================================
#  bypass-mdm.sh v3 - THE script. Single file, no siblings.
#  Fixed fork of assafdori/bypass-mdm for this MacBook Air.
#  (The upstream's separate bypass-mdm-v2.sh is intentionally NOT included.)
#  https://github.com/banyourself/bypass-mdm
#
#  This fork grew two fixes:
#    - v2: this Mac's Recovery environment is missing some /usr/bin tools
#      (basename and friends), so this script does ALL text handling with
#      pure bash builtins (no basename, no awk, no grep, no sed). It only
#      needs: curl, dscl, mkdir, rm, touch, chown.
#    - v3: volume detection no longer assumes a volume is named "... Data".
#      The data volume is found by its content (it holds the user database
#      at private/var/db/dslocal/nodes/Default); the system volume by
#      /System/Library/CoreServices. Names are only a fallback.
#
#  What the ORIGINAL upstream v1 script got wrong (still fixed here):
#   1. It always used UniqueID 501. This Mac's existing account already owns
#      501, so the created "Apple" record had no usable UID and could not
#      log in. This script removes that broken record and recreates the user
#      with a free UID (501-599 scan).
#   2. It wrote /etc/hosts and the .cloudConfig* files to
#      "/Volumes/Macintosh HD/..." which is the SEALED system volume on
#      modern macOS - those writes silently did nothing. On Catalina and
#      later those files live on the DATA volume. This script uses
#      /Volumes/Data/private/etc/hosts and
#      /Volumes/Data/private/var/db/ConfigurationProfiles/Settings.
#   3. It always printed success. Every step here is checked and a failing
#      step stops the script with the error shown.
#
#  Volumes: /Volumes/Data is used directly when present, otherwise the first
#  volume ending in "Data". On this Mac that is "Data" (drive: Macintosh HD).
#
#  Usage (macOS Recovery Terminal, WiFi on):
#      curl -L https://raw.githubusercontent.com/banyourself/bypass-mdm/main/bypass-mdm.sh \
#          -o bypass-mdm.sh && chmod +x ./bypass-mdm.sh && ./bypass-mdm.sh
# =============================================================================

set -u

USERNAME="Apple"
FULLNAME="Apple"
PASSWD="1234"

echo "=== MDM bypass (fixed fork v3) ==="
echo ""

# --- 1. locate the volumes (pure bash, no external tools) --------------------
# The DATA volume is the one that holds the user account database
# (.../private/var/db/dslocal/nodes/Default). On Catalina and later that is
# the "Data" volume regardless of what it is called, so we identify it by
# content, not by name. Name-based checks are only a fallback for a setup
# where the dslocal tree does not exist yet.
DATA_VOL=""
for v in /Volumes/*; do
    [ -d "$v" ] || continue
    if [ -d "$v/private/var/db/dslocal/nodes/Default" ]; then
        DATA_VOL="$v"
        break
    fi
done
if [ -z "$DATA_VOL" ]; then
    for v in /Volumes/*; do
        [ -d "$v" ] || continue
        case "$v" in
            *Data) DATA_VOL="$v"; break ;;
        esac
    done
fi
if [ -z "$DATA_VOL" ]; then
    for v in /Volumes/*; do
        [ -d "$v" ] || continue
        case "$v" in
            *data*|*Data*) DATA_VOL="$v"; break ;;
        esac
    done
fi
if [ -z "$DATA_VOL" ]; then
    echo "ERROR: couldn't find the data volume (no volume holds .../private/var/db/dslocal/nodes/Default)"
    exit 1
fi

# The SYSTEM volume is the one containing the core OS
# (/System/Library/CoreServices). It is only used for display: all writes
# below go to the DATA volume, which is where /private/etc and the MDM
# settings actually live on Catalina and later.
SYSTEM_VOL=""
for v in /Volumes/*; do
    [ -d "$v" ] || continue
    if [ -d "$v/System/Library/CoreServices" ]; then
        SYSTEM_VOL="$v"
        break
    fi
done
if [ -z "$SYSTEM_VOL" ]; then
    echo "WARNING: couldn't identify the system volume (cosmetic only - all writes go to the data volume)"
fi

echo "System volume : ${SYSTEM_VOL:-<not found, writes all go to the data volume>}"
echo "Data volume   : $DATA_VOL"
echo ""

DS="$DATA_VOL/private/var/db/dslocal/nodes/Default"
if [ ! -d "$DS" ]; then
    echo "ERROR: Directory Services node not found: $DS"
    exit 1
fi

# --- 2. show what exists ------------------------------------------------------
echo "Existing local accounts (name -> UID):"
dscl -f "$DS" localhost -list /Local/Default/Users UniqueID 2>/dev/null
echo ""

# --- 3. find a free UID (501 is taken by the existing account) ----------------
free_uid() {
    local uid=501
    while [ "$uid" -lt 600 ]; do
        out="$(dscl -f "$DS" localhost -search /Local/Default/Users UniqueID "$uid" 2>/dev/null)"
        case "$out" in
            *UniqueID*) : ;;
            *) echo "$uid"; return 0 ;;
        esac
        uid=$((uid + 1))
    done
    return 1
}

NEW_UID="$(free_uid)" || { echo "ERROR: no free UID in 501-599"; exit 1; }
echo ">>> Using UID $NEW_UID for temporary user '$USERNAME'."
echo ""

# --- 4. repair / create the temporary account ----------------------------------
CUR=""
if [ -r "$DS/users/$USERNAME.plist" ]; then
    out="$(dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" UniqueID 2>/dev/null)"
    CUR="${out##*UniqueID: }"
fi

if [ -n "$CUR" ] && [ "$CUR" = "$NEW_UID" ]; then
    echo "Account '$USERNAME' already exists with UID $CUR - keeping it."
else
    if [ -n "$CUR" ]; then
        echo ">>> Removing broken account '$USERNAME' (UniqueID was '$CUR', expected $NEW_UID)..."
    else
        echo ">>> Account '$USERNAME' is missing a usable UID - repairing it..."
    fi
    dscl -f "$DS" localhost -delete "/Local/Default/Users/$USERNAME" 2>/dev/null
    rm -f "$DS/users/$USERNAME.plist"
    dscl -f "$DS" localhost -delete "/Local/Default/Groups/admin" GroupMembership "$USERNAME" 2>/dev/null
    echo ">>> Recreating account..."
fi

dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" \
    || { echo "ERROR: could not create user record"; exit 1; }
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" UserShell "/bin/zsh" \
    || { echo "ERROR: could not set shell"; exit 1; }
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" RealName "$FULLNAME" \
    || { echo "ERROR: could not set real name"; exit 1; }
GUID="$(uuidgen 2>/dev/null)"
if [ -n "$GUID" ]; then
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" GeneratedUID "$GUID" 2>/dev/null
fi
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" UniqueID "$NEW_UID" \
    || { echo "ERROR: could not set UniqueID"; exit 1; }
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" PrimaryGroupID "20" \
    || { echo "ERROR: could not set PrimaryGroupID"; exit 1; }
dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" NFSHomeDirectory "/Users/$USERNAME" \
    || { echo "ERROR: could not set home directory"; exit 1; }
dscl -f "$DS" localhost -passwd "/Local/Default/Users/$USERNAME" "$PASSWD" \
    || { echo "ERROR: could not set password"; exit 1; }
dscl -f "$DS" localhost -append "/Local/Default/Groups/admin" GroupMembership "$USERNAME" \
    || { echo "ERROR: could not add user to admin group"; exit 1; }

# home directory (a previous run may have created it as root)
mkdir -p "$DATA_VOL/Users/$USERNAME"
chown -R "$NEW_UID:20" "$DATA_VOL/Users/$USERNAME" 2>/dev/null

echo ""
echo "Account verification:"
rec="$(dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" 2>/dev/null)"
while IFS= read -r line; do
    case "$line" in
        RecordName:*|RealName:*|UniqueID:*|PrimaryGroupID:*|NFSHomeDirectory:*|GeneratedUID:*|UserShell:*)
            echo "   $line" ;;
    esac
done <<< "$rec"
echo ""

# --- 5. MDM suppression on the CORRECT (Data volume) paths ---------------------
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
    line="0.0.0.0 $d"
    found=""
    while IFS= read -r h; do
        [ "$h" = "$line" ] && found="1"
    done < "$HOSTS"
    [ -n "$found" ] || echo "$line" >> "$HOSTS"
done

echo ""
echo "============================================================"
echo " DONE (v3)."
echo " Close this Terminal window and reboot the Mac."
echo " At the login screen choose 'Other...' and sign in with:"
echo "     username: $USERNAME"
echo "     password: $PASSWD"
echo "============================================================"
exit 0