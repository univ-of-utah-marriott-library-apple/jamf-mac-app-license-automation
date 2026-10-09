#!/bin/bash
#
# This Extension Attribute reports the presence of one local Mac App license
# entitlement marker. It makes no network calls and does not modify the Mac.
#
# Revised: 2026.10.07
# Version: 1.0.0
#
# Setup before uploading this Extension Attribute to Jamf Pro:
#
#   1. Copy this script once for each licensed Mac App.
#   2. Set APP_KEY to the filename-safe value used as parameter 5 in that
#      app's Self Service add and remove policies. For example: logic_pro.
#   3. Upload the copy as an Extension Attribute and create a License Smart
#      Group whose criterion is this EA with an Exact Match value of Yes.
#   4. Scope the matching device-assigned Mac App only to that Smart Group and
#      set the app to Install Automatically.
#
# Security behavior:
#   The EA returns Yes only for a root:wheel marker with mode 600 in a
#   root:wheel directory with mode 755. Missing markers return No. An unsafe
#   marker directory or invalid APP_KEY returns an error result for inventory
#   troubleshooting and never grants scope.
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
#
# Script Variables:
#   Extension Attributes do not receive Jamf Pro policy parameters.
#   Set APP_KEY before uploading each per-app copy. Examples:
#
#     Logic Pro:      APP_KEY="logic_pro"
#     Final Cut Pro:  APP_KEY="final_cut_pro"
#     Motion:         APP_KEY="motion"
#     Compressor:     APP_KEY="compressor"
#
#   The Self Service add/remove policies must use the identical parameter-5
#   value. APP_KEY="logic_pro" checks:
#   /Library/Management/mac_app_group_membership/logic_pro_license.request

APP_KEY="REPLACE_WITH_APP_KEY"
MARKER_DIRECTORY="/Library/Management/mac_app_group_membership"
MARKER_FILE="${MARKER_DIRECTORY}/${APP_KEY}_license.request"

if [[ ! "$APP_KEY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo '<result>error:invalid-app-key</result>'
    exit 0
fi

if [[ ! -d "$MARKER_DIRECTORY" || -L "$MARKER_DIRECTORY" ]]; then
    echo '<result>No</result>'
    exit 0
fi

directoryOwner=$(/usr/bin/stat -f '%Su:%Sg' "$MARKER_DIRECTORY" 2>/dev/null)
directoryMode=$(/usr/bin/stat -f '%Lp' "$MARKER_DIRECTORY" 2>/dev/null)
if [[ "$directoryOwner" != 'root:wheel' || "$directoryMode" != '755' ]]; then
    echo '<result>error:unsafe-marker-directory</result>'
    exit 0
fi

if [[ -f "$MARKER_FILE" && ! -L "$MARKER_FILE" ]]; then
    markerOwner=$(/usr/bin/stat -f '%Su:%Sg' "$MARKER_FILE" 2>/dev/null)
    markerMode=$(/usr/bin/stat -f '%Lp' "$MARKER_FILE" 2>/dev/null)
    if [[ "$markerOwner" == 'root:wheel' && "$markerMode" == '600' ]]; then
        echo '<result>Yes</result>'
        exit 0
    fi
fi

echo '<result>No</result>'
