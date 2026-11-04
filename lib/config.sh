# shellcheck shell=bash
# Loads ios-ota-server settings. Order: environment variables, then --config <file> (OTA_CONFIG),
# then ~/.config/ios-ota/ota.conf. Nothing host- or account-specific lives in the repository.

OTA_KNOWN_KEYS=(OTA_BASE_URL OTA_RSYNC_DEST OTA_RSYNC_BIN OTA_RSYNC_PASSWORD_FILE OTA_SSH_KEY OTA_SSH_PORT
    OTA_KEEP_VERSIONS OTA_TEAM_ID OTA_EXPORT_METHOD OTA_PROFILE_DAYS)

ota_die() {
    echo "ota: $*" >&2
    exit 1
}

# Reads KEY=VALUE lines without executing the file. Keeps values already set in the environment.
ota_load_config() {
    local file="${OTA_CONFIG:-$HOME/.config/ios-ota/ota.conf}"
    if [[ -f "$file" ]]; then
        local line key value
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]] || ota_die "bad line in $file: $line"
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            value="${value/#\~/$HOME}"
            [[ " ${OTA_KNOWN_KEYS[*]} " == *" $key "* ]] || ota_die "unknown setting $key in $file"
            if [[ -z "${!key:-}" ]]; then
                printf -v "$key" '%s' "$value"
                export "${key?}"
            fi
        done < "$file"
    elif [[ -n "${OTA_CONFIG:-}" ]]; then
        ota_die "config file $OTA_CONFIG not found"
    fi
    : "${OTA_RSYNC_BIN:=rsync}"
    : "${OTA_SSH_PORT:=22}"
    : "${OTA_KEEP_VERSIONS:=10}"
    : "${OTA_EXPORT_METHOD:=debugging}"
    : "${OTA_PROFILE_DAYS:=7}"
    export OTA_RSYNC_BIN OTA_SSH_PORT OTA_KEEP_VERSIONS OTA_EXPORT_METHOD OTA_PROFILE_DAYS
}

ota_require() {
    local key missing=()
    for key in "$@"; do
        [[ -n "${!key:-}" ]] || missing+=("$key")
    done
    if ((${#missing[@]})); then
        ota_die "missing setting(s): ${missing[*]}. Set them in the environment or in ota.conf (see ota.conf.example)."
    fi
}

# rsync options for the configured destination: SSH (user@host:/path) or the rsync daemon (rsync://...).
ota_rsync() {
    # shellcheck disable=SC2054 # the commas belong to the --chmod value
    local args=(-rlt --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r)
    if [[ "$OTA_RSYNC_DEST" == rsync://* ]]; then
        [[ -n "${OTA_RSYNC_PASSWORD_FILE:-}" ]] && args+=(--password-file="$OTA_RSYNC_PASSWORD_FILE")
    elif [[ "$OTA_RSYNC_DEST" == *:* ]]; then
        local ssh_cmd="ssh -p $OTA_SSH_PORT -o BatchMode=yes"
        [[ -n "${OTA_SSH_KEY:-}" ]] && ssh_cmd+=" -i $OTA_SSH_KEY -o IdentitiesOnly=yes"
        args+=(-e "$ssh_cmd")
    fi
    "$OTA_RSYNC_BIN" "${args[@]}" "$@"
}
