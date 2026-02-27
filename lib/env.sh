#!/usr/bin/env bash
# =============================================================================
# lib/env.sh — Load and validate .env configuration
# Must be sourced AFTER lib/common.sh (needs fail/warn/ok).
# =============================================================================

readonly ENV_FILE="$PROJECT_ROOT/.env"
readonly ENV_EXAMPLE="$PROJECT_ROOT/.env.example"

# ---------- load ----------
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo ""
        fail "Configuration file not found: .env
  Create one from the template:
    cp .env.example .env
    \$EDITOR .env"
    fi

    # shellcheck source=/dev/null
    source "$ENV_FILE"

    # Optional variables with defaults
    ASTRO_PUBLIC_IP="${ASTRO_PUBLIC_IP:-}"
    ASTRO_LAUNCHER_PORT="${ASTRO_LAUNCHER_PORT:-5000}"
}

# ---------- validate ----------
# Verify all required variables are set and non-empty.
# Type-check numeric fields.
validate_env() {
    local missing=()
    local errors=()

    # Required string variables
    local required_vars=(
        VM_NAME VM_IP
        VNC_PASSWORD
        WIN_USERNAME WIN_PASSWORD
        IMAGES_DIR
    )
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    # Required numeric variables (must be positive integers)
    local numeric_vars=(VM_RAM VM_CPUS VM_DISK_SIZE VNC_PORT ASTRO_PORT ASTRO_LAUNCHER_PORT)
    for var in "${numeric_vars[@]}"; do
        local val="${!var:-}"
        if [[ -z "$val" ]]; then
            missing+=("$var")
        elif ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -le 0 ]]; then
            errors+=("$var must be a positive integer (got: '$val')")
        fi
    done

    # Port range checks
    local port_vars=(VNC_PORT ASTRO_PORT ASTRO_LAUNCHER_PORT)
    for var in "${port_vars[@]}"; do
        local val="${!var:-}"
        if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
            if [[ "$val" -lt 1 || "$val" -gt 65535 ]]; then
                errors+=("$var must be 1-65535 (got: $val)")
            fi
        fi
    done

    # Report
    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "Missing required .env variables: ${missing[*]}
  See .env.example for reference."
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            warn "$err"
        done
        fail "Fix the above .env errors before continuing."
    fi

    # Soft warnings
    if [[ "$WIN_PASSWORD" == "changeme" ]]; then
        warn "WIN_PASSWORD is still set to 'changeme' — change it before setup!"
    fi
    if [[ "$VNC_PASSWORD" == "changeme" ]]; then
        warn "VNC_PASSWORD is still set to 'changeme' — change it before setup!"
    fi

    ok "Configuration validated"
}

# ---------- convenience: load + validate ----------
init_env() {
    load_env
    validate_env
}
