#!/bin/bash
#
# Create or remove a local Mac App license-entitlement marker for Jamf Pro.
#
# Revised: 2026.10.07
# Version: 2.4.1
#
# This script is intended for Self Service policies. It does not contact Jamf
# Pro and does not accept API credentials. A per-app Extension Attribute reads
# the marker during inventory collection, and a Smart Group scopes the matching
# device-assigned Mac App.
#
# Jamf Pro Script Parameters:
#   $4  Action: add or remove
#   $5  Filename-safe application key, for example: logic_pro. This must match
#       APP_KEY in the corresponding Mac App license-marker Extension Attribute.
#   $6  Optional DRY_RUN: true or false (default: false)
#   $7  Optional app path to monitor after an add entitlement, for example:
#       /Applications/Logic Pro.app. Leave blank to skip installation monitoring.
#   $8  Optional overall processing limit in seconds (default: 1800; maximum:
#       3600). This includes Recon, EA collection, and app-path monitoring.
#   $9  Optional DEBUG: true or false (default: false). When true, writes a
#       root-only diagnostic log to /var/log/jamf-mac-app-license-entitlement.log.
#
# Jamf Pro policy setup:
#   1. Upload this script as a Jamf Pro script and configure it to run as root.
#   2. Create one Self Service policy to add and one to remove an entitlement.
#   3. Copy the Mac App license-marker EA for this app, set its APP_KEY to
#      parameter 5, then make a Smart Group whose EA criterion is exactly Yes.
#   4. Scope the corresponding device-assigned Mac App only to that Smart
#      Group, with Install Automatically selected.
#   5. Set parameters 4-9 for each add or remove policy and scope those
#      policies only to the intended users and computers.
#
# Marker layout:
#   APP_KEY=logic_pro creates this root-owned entitlement marker:
#   /Library/Management/mac_app_group_membership/logic_pro_license.request
#
# User feedback:
#   For add policies, provide parameters 7 and optionally 8 to notify the
#   logged-in user immediately when the request starts, every five minutes
#   while Jamf processes an add entitlement, and when the app path appears. The
#   monitor confirms that the app bundle exists; it does not prove managed-
#   distribution status or version.
#
# Copyright (c) 2026 University of Utah, Marriott Library IT.
# All Rights Reserved.
#
# Permission to use, copy, modify, and distribute this software and
# its documentation for any purpose and without fee is hereby granted,
# provided that the above copyright notice appears in all copies and
# that both that copyright notice and this permission notice appear
# in supporting documentation, and that the name of The University
# of Utah not be used in advertising or publicity pertaining to
# distribution of the software without specific, written prior
# permission. This software is supplied as is without expressed or
# implied warranties of any kind.

set -u
set -o pipefail
umask 077

SCRIPT_VERSION="2.4.1"

# Values populated from Jamf Pro policy parameters 4-9
ACTION="${4:-}"
APP_KEY="${5:-}"
DRY_RUN="${6:-false}"
APPLICATION_PATH="${7:-}"
INSTALL_MONITOR_SECONDS="${8:-1800}"
DEBUG="${9:-false}"

# Internal paths and runtime constants. REQUEST_FILE is an entitlement marker,
# not a request for a server-side membership worker.
REQUEST_DIRECTORY="/Library/Management/mac_app_group_membership"
REQUEST_FILE="${REQUEST_DIRECTORY}/${APP_KEY}_license.request"
LOCK_DIRECTORY="/var/run/mac-app-license-${APP_KEY}.lock"
INSTALL_POLL_INTERVAL_SECONDS=15
NOTIFICATION_INTERVAL_SECONDS=300
MAX_INSTALL_MONITOR_SECONDS=3600
DEBUG_LOG_FILE="/var/log/jamf-mac-app-license-entitlement.log"
DEBUG_LOG_MAX_BYTES=$((1024 * 1024))

# Runtime state; do not configure
temporaryRequest=""
applicationWasPresentBeforeRequest=false
notificationPID=""
requestStartedEpoch=""
markerChangedAt=""
reconCompletedEpoch=""
reconCompletedAt=""
totalProcessingTimeLogged=false

log() {
    local line

    line="$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    printf '%s\n' "$line"
    [[ "$DEBUG" == "true" ]] && printf '%s\n' "$line" >> "$DEBUG_LOG_FILE" 2>/dev/null || true
}

debug() {
    [[ "$DEBUG" == "true" ]] || return 0
    log "DEBUG" "$1"
}

initialize_debug_log() {
    local logSize

    [[ "$DEBUG" == "true" ]] || return 0
    [[ ! -L "$DEBUG_LOG_FILE" ]] || return 1

    if [[ -e "$DEBUG_LOG_FILE" ]]; then
        [[ -f "$DEBUG_LOG_FILE" ]] || return 1
        logSize=$(/usr/bin/stat -f '%z' "$DEBUG_LOG_FILE" 2>/dev/null) || return 1
        if (( logSize >= DEBUG_LOG_MAX_BYTES )); then
            /bin/mv -f "$DEBUG_LOG_FILE" "${DEBUG_LOG_FILE}.1" || return 1
        fi
    fi

    /usr/bin/touch "$DEBUG_LOG_FILE" || return 1
    /usr/sbin/chown root:wheel "$DEBUG_LOG_FILE" || return 1
    /bin/chmod 600 "$DEBUG_LOG_FILE" || return 1
}

fail() {
    log "ERROR" "$1" >&2
    exit 1
}

log_jamf_pro_app_delivery_follow_up() {
    log "INFO" "Jamf Pro app-delivery follow-up for app key ${APP_KEY}: review this computer's Mac App Store Apps status and History/Management History for the app-install command or error."
    log "INFO" "Also confirm that the matching marker EA Smart Group is the Mac App's sole inclusion scope, the app is set to Install Automatically, and a VPP assignment is available."
}

stop_periodic_status_notifier() {
    [[ "$notificationPID" =~ ^[0-9]+$ ]] || return 0
    /bin/kill -0 "$notificationPID" 2>/dev/null && /bin/kill "$notificationPID" 2>/dev/null || true
    wait "$notificationPID" 2>/dev/null || true
    notificationPID=""
}

cleanup() {
    log_total_processing_time
    stop_periodic_status_notifier
    [[ -n "$temporaryRequest" && -f "$temporaryRequest" ]] && /bin/rm -f "$temporaryRequest"
    [[ -d "$LOCK_DIRECTORY" ]] && /bin/rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
}

log_total_processing_time() {
    local elapsed minutes seconds

    [[ "$totalProcessingTimeLogged" == "false" && "$requestStartedEpoch" =~ ^[0-9]+$ ]] || return 0
    elapsed=$(($(/bin/date +%s) - requestStartedEpoch))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))
    log "INFO" "Final total entitlement processing time: ${elapsed}s (${minutes}m ${seconds}s)."
    totalProcessingTimeLogged=true
}

format_duration() {
    local elapsed="$1"

    printf '%dm %ds' "$((elapsed / 60))" "$((elapsed % 60))"
}

log_recon_timing() {
    local elapsed

    reconCompletedEpoch=$(/bin/date +%s) || return 1
    reconCompletedAt=$(/bin/date '+%Y-%m-%d %H:%M:%S') || return 1
    elapsed=$((reconCompletedEpoch - requestStartedEpoch))
    log "INFO" "Recon completed at ${reconCompletedAt} after ${elapsed}s ($(format_duration "$elapsed"))."
}

log_application_timing() {
    local appDetectedEpoch="$1" postReconElapsed appDetectedAt

    appDetectedAt=$(/bin/date -r "$appDetectedEpoch" '+%Y-%m-%d %H:%M:%S') || return 1
    if [[ "$reconCompletedEpoch" =~ ^[0-9]+$ ]]; then
        postReconElapsed=$((appDetectedEpoch - reconCompletedEpoch))
        log "INFO" "Entitlement timing summary:"
        log "INFO" "  Marker changed: ${markerChangedAt}"
        log "INFO" "  Recon completed: ${reconCompletedAt} ($(format_duration "$((reconCompletedEpoch - requestStartedEpoch))"))"
        log "INFO" "  App detected: ${appDetectedAt}"
        log "INFO" "  Post-Recon delivery: ${postReconElapsed}s ($(format_duration "$postReconElapsed"))"
    else
        log "INFO" "Entitlement timing summary: marker changed at ${markerChangedAt}; app detected at ${appDetectedAt}."
    fi
}

release_request_lock() {
    [[ -d "$LOCK_DIRECTORY" && ! -L "$LOCK_DIRECTORY" ]] || return 0
    /bin/rmdir "$LOCK_DIRECTORY" 2>/dev/null
}

validate_managed_directory() {
    local owner group mode

    if [[ ! -e "$REQUEST_DIRECTORY" ]]; then
        /bin/mkdir -p "$REQUEST_DIRECTORY" || return 1
        /usr/sbin/chown root:wheel "$REQUEST_DIRECTORY" || return 1
        /bin/chmod 755 "$REQUEST_DIRECTORY" || return 1
    fi

    [[ -d "$REQUEST_DIRECTORY" && ! -L "$REQUEST_DIRECTORY" ]] || return 1
    owner=$(/usr/bin/stat -f '%Su' "$REQUEST_DIRECTORY") || return 1
    group=$(/usr/bin/stat -f '%Sg' "$REQUEST_DIRECTORY") || return 1
    mode=$(/usr/bin/stat -f '%Lp' "$REQUEST_DIRECTORY") || return 1
    [[ "$owner" == "root" && "$group" == "wheel" && "$mode" == "755" ]]
}

jamf_binary() {
    if [[ -x "/usr/local/bin/jamf" ]]; then
        printf '%s\n' "/usr/local/bin/jamf"
        return 0
    fi

    if [[ -x "/usr/local/jamf/bin/jamf" ]]; then
        printf '%s\n' "/usr/local/jamf/bin/jamf"
        return 0
    fi

    return 1
}

console_user() {
    local user

    user=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)
    [[ -n "$user" && "$user" != "loginwindow" && "$user" != "root" ]] || return 1
    printf '%s\n' "$user"
}

display_gui_notification() {
    local title="$1" message="$2" manageAction user uid

    manageAction="/Library/Application Support/JAMF/bin/Management Action.app/Contents/MacOS/Management Action"
    if [[ -x "$manageAction" ]]; then
        "$manageAction" -message "$message" -title "$title" >/dev/null 2>&1 &
        return 0
    fi

    user=$(console_user) || return 0
    uid=$(/usr/bin/id -u "$user" 2>/dev/null) || return 0
    /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$user" /usr/bin/osascript \
        -e 'on run argv
display notification (item 2 of argv) with title (item 1 of argv)
end run' \
        "$title" "$message" >/dev/null 2>&1 || true
}

resolve_application_path() {
    local systemApplicationPath

    [[ -n "$APPLICATION_PATH" && ! -d "$APPLICATION_PATH" && "$APPLICATION_PATH" == /Applications/* ]] || return 0
    systemApplicationPath="/System${APPLICATION_PATH}"
    if [[ -d "$systemApplicationPath" ]]; then
        log "INFO" "Resolved application path ${APPLICATION_PATH} to ${systemApplicationPath}."
        APPLICATION_PATH="$systemApplicationPath"
    fi
}

monitor_application_installation() {
    local applicationName startEpoch now elapsed

    applicationName=$(/usr/bin/basename "${APPLICATION_PATH%.app}")
    startEpoch="$requestStartedEpoch"
    log "INFO" "Monitoring ${APPLICATION_PATH} until the ${INSTALL_MONITOR_SECONDS}s request deadline."
    display_gui_notification "${applicationName} Installation Processing" "Your entitlement request completed. Installation can take some time. You will receive a notification when it is complete."

    while true; do
        if [[ -d "$APPLICATION_PATH" ]]; then
            now=$(/bin/date +%s)
            elapsed=$((now - startEpoch))
            log "INFO" "Verified application installation at ${APPLICATION_PATH} after ${elapsed}s."
            log_application_timing "$now" || log "WARN" "Unable to record detailed application timing."
            display_gui_notification "${applicationName} Installed" "Installation is complete."
            return 0
        fi

        now=$(/bin/date +%s)
        elapsed=$((now - startEpoch))
        if (( elapsed >= INSTALL_MONITOR_SECONDS )); then
            log "WARN" "Application was not found at ${APPLICATION_PATH} after ${INSTALL_MONITOR_SECONDS}s."
            log_jamf_pro_app_delivery_follow_up
            display_gui_notification "${applicationName} Installation Pending" "Your request is still processing. Please check again later."
            return 0
        fi

        /bin/sleep "$INSTALL_POLL_INTERVAL_SECONDS"
    done
}

periodic_status_notifier() {
    local applicationName="$1" elapsed startEpoch

    # This function runs in a background subshell. Do not inherit the parent
    # cleanup trap, which owns the entitlement lock and temporary marker file.
    trap - EXIT HUP INT TERM
    startEpoch="$requestStartedEpoch"

    while /bin/sleep "$NOTIFICATION_INTERVAL_SECONDS"; do
        [[ -n "$APPLICATION_PATH" && -d "$APPLICATION_PATH" ]] && return 0
        elapsed=$(($(/bin/date +%s) - startEpoch))
        if (( elapsed >= INSTALL_MONITOR_SECONDS )); then
            display_gui_notification "${applicationName} Installation Pending" "Your request is still pending after $((elapsed / 60)) minutes. Please check again later."
            return 0
        fi
        display_gui_notification "${applicationName} Request Update" "Your request is still processing ($((elapsed / 60)) minutes elapsed). Please wait..."
    done
}

start_periodic_status_notifier() {
    local applicationName="$1"

    periodic_status_notifier "$applicationName" &
    notificationPID=$!
}

run_jamf_recon_with_deadline() {
    local jamfBin="$1" reconPID now

    "$jamfBin" recon &
    reconPID=$!

    while /bin/kill -0 "$reconPID" 2>/dev/null; do
        now=$(/bin/date +%s)
        if (( now - requestStartedEpoch >= INSTALL_MONITOR_SECONDS )); then
        log "WARN" "jamf recon exceeded the ${INSTALL_MONITOR_SECONDS}s entitlement deadline; stopping the recon process."
            /bin/kill -TERM "$reconPID" 2>/dev/null || true
            /bin/sleep 5
            /bin/kill -0 "$reconPID" 2>/dev/null && /bin/kill -KILL "$reconPID" 2>/dev/null || true
            wait "$reconPID" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 1
    done

    wait "$reconPID"
}

if [[ "$EUID" -ne 0 ]]; then
    fail "This script must run as root. Configure the Jamf Pro policy to run as root."
fi

case "$ACTION" in
    add|remove) ;;
    *) fail "Parameter 4 must be add or remove." ;;
esac

[[ "$APP_KEY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "Parameter 5 must be a non-sensitive application key containing letters, numbers, periods, underscores, or hyphens."
[[ "$DRY_RUN" == "true" || "$DRY_RUN" == "false" ]] || fail "Parameter 6 must be true or false."
[[ -z "$APPLICATION_PATH" || ( "$APPLICATION_PATH" == /* && "$APPLICATION_PATH" == *.app ) ]] || fail "Parameter 7 must be an absolute application path ending in .app, or be blank."
[[ "$INSTALL_MONITOR_SECONDS" =~ ^[0-9]+$ && "$INSTALL_MONITOR_SECONDS" -gt 0 && "$INSTALL_MONITOR_SECONDS" -le "$MAX_INSTALL_MONITOR_SECONDS" ]] || fail "Parameter 8 must be between 1 and ${MAX_INSTALL_MONITOR_SECONDS} seconds."
[[ "$DEBUG" == "true" || "$DEBUG" == "false" ]] || fail "Parameter 9 must be true or false."

if ! initialize_debug_log; then
    printf '%s [WARN] Debug logging could not be initialized at %s; continuing without a persistent debug log.\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$DEBUG_LOG_FILE"
    DEBUG="false"
fi

log "INFO" "Starting script version ${SCRIPT_VERSION}."
debug "Action=${ACTION}; appKey=${APP_KEY}; applicationPath=${APPLICATION_PATH:-none}; monitorSeconds=${INSTALL_MONITOR_SECONDS}."

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN" "Would ${ACTION} entitlement marker ${REQUEST_FILE}, then monitor ${APPLICATION_PATH:-no application path}."
    exit 0
fi

validate_managed_directory || fail "${REQUEST_DIRECTORY} must be a root:wheel directory with mode 755."

if [[ "$ACTION" == "add" && -n "$APPLICATION_PATH" ]]; then
    resolve_application_path
    if [[ -d "$APPLICATION_PATH" ]]; then
        applicationWasPresentBeforeRequest=true
        log "INFO" "Application was already present before the entitlement request: ${APPLICATION_PATH}."
    fi
fi

if ! /bin/mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
    fail "Another ${APP_KEY} entitlement request is being processed. Try again shortly."
fi
trap cleanup EXIT

if [[ "$ACTION" == "add" ]]; then
    createdAt=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') || fail "Unable to create an entitlement timestamp."
    temporaryRequest=$(/usr/bin/mktemp "${REQUEST_DIRECTORY}/.${APP_KEY}_license.XXXXXX") || fail "Unable to create a secure entitlement marker."
    cat > "$temporaryRequest" <<EOF
schema_version=2
app_key=${APP_KEY}
created_at=${createdAt}
EOF
    /usr/sbin/chown root:wheel "$temporaryRequest" || fail "Unable to set marker ownership."
    /bin/chmod 600 "$temporaryRequest" || fail "Unable to set marker permissions."
    /bin/mv -f "$temporaryRequest" "$REQUEST_FILE" || fail "Unable to publish entitlement marker."
    temporaryRequest=""
    log "INFO" "Created entitlement marker ${REQUEST_FILE}."
else
    if [[ -L "$REQUEST_FILE" ]]; then
        fail "Refusing to remove symbolic-link entitlement marker ${REQUEST_FILE}."
    fi
    if [[ -e "$REQUEST_FILE" ]]; then
        [[ -f "$REQUEST_FILE" ]] || fail "Entitlement marker ${REQUEST_FILE} is not a regular file."
        /bin/rm -f "$REQUEST_FILE" || fail "Unable to remove entitlement marker ${REQUEST_FILE}."
        log "INFO" "Removed entitlement marker ${REQUEST_FILE}."
    else
        log "INFO" "Entitlement marker ${REQUEST_FILE} was already absent."
    fi
fi

requestStartedEpoch=$(/bin/date +%s) || fail "Unable to start the request timer."
markerChangedAt=$(/bin/date '+%Y-%m-%d %H:%M:%S') || fail "Unable to record the entitlement marker timestamp."
if [[ "$ACTION" == "add" ]]; then
    if [[ -n "$APPLICATION_PATH" ]]; then
        applicationName=$(/usr/bin/basename "${APPLICATION_PATH%.app}")
    else
        applicationName="$APP_KEY"
    fi
    display_gui_notification "${applicationName} Request Started" "Your request was received. You will receive status updates every five minutes."
    [[ "$applicationWasPresentBeforeRequest" == "true" ]] || start_periodic_status_notifier "$applicationName"
fi
reconCompleted=false
jamfBin=$(jamf_binary 2>/dev/null || true)

if [[ -n "$jamfBin" ]]; then
    debug "Starting inventory update with ${jamfBin} recon."
    run_jamf_recon_with_deadline "$jamfBin" || {
        reconExit=$?
        if [[ "$reconExit" -eq 124 ]]; then
            log_jamf_pro_app_delivery_follow_up
            fail "Entitlement inventory update is still pending after ${INSTALL_MONITOR_SECONDS}s."
        fi
        fail "Entitlement marker was updated, but jamf recon failed. The Extension Attribute will report its current state at the next successful inventory update."
    }
    reconCompleted=true
    log_recon_timing || fail "Recon completed, but its timing could not be recorded."
    log "INFO" "The entitlement marker state is available to the matching Extension Attribute."
    release_request_lock || fail "The entitlement request completed, but the local request lock could not be released."
else
    log "WARN" "Entitlement marker was updated, but the Jamf binary was not found. It will be reported at the next inventory update."
    [[ "$ACTION" == "add" ]] && display_gui_notification "Mac App Request Queued" "Your ${APP_KEY} request is queued and will be processed at the next inventory update."
fi

if [[ "$ACTION" == "add" && -z "$APPLICATION_PATH" && "$reconCompleted" == "true" ]]; then
    stop_periodic_status_notifier
    display_gui_notification "Mac App Request Submitted" "Your ${APP_KEY} request was submitted. Installation can take some time."
fi

if [[ "$ACTION" == "add" && -n "$APPLICATION_PATH" && "$reconCompleted" == "true" ]]; then
    if [[ "$applicationWasPresentBeforeRequest" == "true" ]]; then
        applicationName=$(/usr/bin/basename "${APPLICATION_PATH%.app}")
        display_gui_notification "${applicationName} Already Present" "The app was already present before this entitlement request."
    else
        log "INFO" "The entitlement marker was reported. Jamf Pro Mac App delivery now occurs asynchronously."
        log_jamf_pro_app_delivery_follow_up
        if [[ -d "$APPLICATION_PATH" ]]; then
            applicationName=$(/usr/bin/basename "${APPLICATION_PATH%.app}")
            log_application_timing "$(/bin/date +%s)" || log "WARN" "Unable to record detailed application timing."
            display_gui_notification "${applicationName} Installed" "Installation is complete."
        else
            monitor_application_installation
        fi
    fi
fi
