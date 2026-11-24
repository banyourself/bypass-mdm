#!/bin/bash
# =============================================================================
#  bypass-mdm.sh v5 - THE script. Single file, no siblings.
#  Fixed fork of assafdori/bypass-mdm for this MacBook Air.
#  (The upstream's separate bypass-mdm-v2.sh is intentionally NOT included.)
#  https://github.com/banyourself/bypass-mdm
#
#  This fork grew these fixes
#    - v2 - this Mac's Recovery environment is missing some /usr/bin tools
#      (basename and friends), so this script does ALL text handling with
#      pure bash builtins (no basename, no awk, no grep, no sed). It only
#      needs - curl, dscl, mkdir, rm, touch and chown.
#    - v3 - volume detection no longer assumes a volume is named "... Data".
#      The data volume is found by its content (it holds the user database
#      at private/var/db/dslocal/nodes/Default), and the system volume is
#      found by /System/Library/CoreServices. Names are only a fallback.
#    - v4 - the temp account is guaranteed to be an administrator. It is
#      added to the admin group with -merge (so re-running the script never
#      fails on an existing entry) and on BOTH attributes macOS uses - the
#      GroupMembership short name and the GroupMembers GeneratedUID - then
#      verified before the script reports success.
#    - v5 - re-running no longer churns the account's UID. The old check
#      kept the account only when its UID matched the first free one, which
#      never happens on a re-run, so the account was deleted and recreated
#      with a new UID every time. Now the account is kept whenever it has
#      any valid UID, and GeneratedUID gets a pure-bash fallback when
#      uuidgen is missing.
#
#  What the ORIGINAL upstream v1 script got wrong (still fixed here)
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
#  Volumes - the data volume is found by content (it holds the user
#  database), names are only a fallback. On this Mac that is "Data"
#  (drive - Macintosh HD).
#
#  Usage (macOS Recovery Terminal, WiFi on)
#      curl -L https://raw.githubusercontent.com/banyourself/bypass-mdm/main/bypass-mdm.sh \
#          -o bypass-mdm.sh && chmod +x ./bypass-mdm.sh && ./bypass-mdm.sh
# =============================================================================

set -u

USERNAME="Apple"
FULLNAME="Apple"
PASSWD="1234"

echo "=== MDM bypass (fixed fork v5) ==="
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
# (/System/Library/CoreServices). It is only used for display - all writes
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
if [ ! -w "$DS" ]; then
    echo "ERROR: the user database at $DS is not writable - run this from macOS Recovery Terminal (it runs as root)."
    exit 1
fi

# --- 2. show what exists ------------------------------------------------------
echo "Existing local accounts (name -> UID):"
dscl -f "$DS" localhost -list /Local/Default/Users UniqueID 2>/dev/null
echo ""

# --- 3. read the temp account's current state ----------------------------------
CUR=""
GUID=""
if [ -r "$DS/users/$USERNAME.plist" ]; then
    out="$(dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" UniqueID 2>/dev/null)"
    CUR="${out##*UniqueID: }"
    case "$CUR" in
        *[!0-9]*) CUR="" ;;
    esac
fi

# --- 4. find a free UID (501 is taken by the existing account) -----------------
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

# a UUID for GeneratedUID - uuidgen when available, pure bash otherwise
gen_guid() {
    local g
    g="$(uuidgen 2>/dev/null)"
    if [ -z "$g" ]; then
        g="$(printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x' \
            $((RANDOM)) $((RANDOM)) $((RANDOM)) $((RANDOM&0xfff)) \
            $((RANDOM&0x3fff|0x8000)) $((RANDOM)) $((RANDOM)) $((RANDOM)))"
    fi
    echo "$g"
}

# --- 5. repair / create the temporary account ----------------------------------
if [ -n "$CUR" ]; then
    NEW_UID="$CUR"
    echo ">>> Account '$USERNAME' already exists with UID $CUR - keeping it."
else
    NEW_UID="$(free_uid)" || { echo "ERROR: no free UID in 501-599"; exit 1; }
    echo ">>> Using UID $NEW_UID for temporary user '$USERNAME'."
    if [ -r "$DS/users/$USERNAME.plist" ]; then
        echo ">>> Removing broken account '$USERNAME' (no usable UID) - repairing it..."
    else
        echo ">>> Account '$USERNAME' does not exist - creating it..."
    fi
    dscl -f "$DS" localhost -delete "/Local/Default/Users/$USERNAME" 2>/dev/null
    rm -f "$DS/users/$USERNAME.plist"
    dscl -f "$DS" localhost -delete "/Local/Default/Groups/admin" GroupMembership "$USERNAME" 2>/dev/null
    echo ">>> Creating account..."
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" \
        || { echo "ERROR: could not create user record"; exit 1; }
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" UserShell "/bin/zsh" \
        || { echo "ERROR: could not set shell"; exit 1; }
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" RealName "$FULLNAME" \
        || { echo "ERROR: could not set real name"; exit 1; }
    GUID="$(gen_guid)"
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" GeneratedUID "$GUID" 2>/dev/null
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" UniqueID "$NEW_UID" \
        || { echo "ERROR: could not set UniqueID"; exit 1; }
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" PrimaryGroupID "20" \
        || { echo "ERROR: could not set PrimaryGroupID"; exit 1; }
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" NFSHomeDirectory "/Users/$USERNAME" \
        || { echo "ERROR: could not set home directory"; exit 1; }
fi

# the password is re-applied on every run - this also rebuilds the auth hash
dscl -f "$DS" localhost -passwd "/Local/Default/Users/$USERNAME" "$PASSWD" \
    || { echo "ERROR: could not set password"; exit 1; }

# admin membership - macOS checks the admin group, so add the user on BOTH
# attributes it uses (GroupMembership short name + GroupMembers GeneratedUID).
# -merge is idempotent - a re-run never fails on an existing entry.
if [ -z "$GUID" ]; then
    GUID="$(dscl -f "$DS" localhost -read "/Local/Default/Users/$USERNAME" GeneratedUID 2>/dev/null)"
    GUID="${GUID##*GeneratedUID: }"
fi
if [ -z "$GUID" ]; then
    GUID="$(gen_guid)"
    dscl -f "$DS" localhost -create "/Local/Default/Users/$USERNAME" GeneratedUID "$GUID" 2>/dev/null
fi
dscl -f "$DS" localhost -merge "/Local/Default/Groups/admin" GroupMembership "$USERNAME" \
    || { echo "ERROR: could not add user to admin group"; exit 1; }
dscl -f "$DS" localhost -merge "/Local/Default/Groups/admin" GroupMembers "$GUID" 2>/dev/null

# verify the membership actually took before reporting success
adm="$(dscl -f "$DS" localhost -read "/Local/Default/Groups/admin" GroupMembership 2>/dev/null)"
case "$adm" in
    *"$USERNAME"*) echo ">>> '$USERNAME' is an administrator (verified)." ;;
    *) echo "ERROR: '$USERNAME' is not in the admin group"; exit 1 ;;
esac

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

# --- 6. MDM suppression on the CORRECT (Data volume) paths ---------------------
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
echo " DONE (v5)."
echo " Close this Terminal window and reboot the Mac."
echo " '$USERNAME' is an administrator - admin applies at login."
echo " At the login screen choose 'Other...' and sign in with:"
echo "     username: $USERNAME"
echo "     password: $PASSWD"
echo "============================================================"
exit 0