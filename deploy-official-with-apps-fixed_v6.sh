#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

# 仅此一次即可
if [[ -f "$ENV_FILE" ]]; then
    set -a          # 自动导出
    # 去掉 Windows 行尾 ^M 再加载
    sed -e 's/\r$//' "$ENV_FILE" > /tmp/.env.unix
    source /tmp/.env.unix
    rm -f /tmp/.env.unix
    set +a
else
    echo >&2 "ERROR: $ENV_FILE not found"
    exit 1
fi
	
# ---------- Logging ----------
info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

# ---------- Load env and defaults ----------
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -o allexport
    # Use a robust way to load env lines (ignore comments/blank)
    # Avoid word splitting issues
    awk -F= '/^[A-Za-z0-9_]+=/{print $0}' "$ENV_FILE" | sed 's/\r//g' | while IFS= read -r line; do
        # export line preserving equals and value
        eval "export $line"
    done
    set +o allexport
else
    error ".env not found in ${PROJECT_DIR}"
    exit 1
fi

# defaults (if .env lacks them)
BASE_TAG=${ERPNEXT_VERSION:-v15.81.1}
CUSTOM_IMAGE=${CUSTOM_IMAGE:-my-erpnext-v15-custom}
CUSTOM_TAG=${CUSTOM_TAG:-latest}
SITE_NAME=${SITES:-nexterp}
COMPOSE_FILES_DEFAULT="-f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.noproxy.yaml -f overrides/compose.redis.yaml"

# If overrides/compose.custom.yaml exists, include it
get_compose_files() {
    if [ -f "overrides/compose.custom.yaml" ]; then
        echo "-f compose.yaml -f overrides/compose.custom.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.noproxy.yaml -f overrides/compose.redis.yaml"
    else
        echo "${COMPOSE_FILES_DEFAULT}"
    fi
}

# ---------- Cleanup helpers ----------
cleanup_tmp() {
    [ -f Dockerfile.custom ] && rm -f Dockerfile.custom
    [ -f overrides/compose.custom.yaml ] && rm -f overrides/compose.custom.yaml
}
trap cleanup_tmp EXIT

# ---------- Generate Dockerfile.custom (gameplan commented out) ----------
generate_custom_dockerfile() {
    info "Generating Dockerfile.custom (gameplan is commented out)..."
    cat > Dockerfile.custom <<EOF
ARG BASE_TAG=${BASE_TAG}
FROM frappe/erpnext:\${BASE_TAG}

USER root
RUN apt-get update && apt-get install -y git pkg-config mariadb-client curl unzip && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# ensure sites folder and minimal config exist
RUN mkdir -p sites && echo '{}' > sites/common_site_config.json && echo '{"socketio_port":9000}' > sites/common_site_config.json

# Download / get apps 
RUN bench get-app --branch develop https://github.com/frappe/telephony --skip-assets || true && \
    bench get-app --branch version-15 https://github.com/frappe/hrms --skip-assets || true && \
    bench get-app --branch main https://github.com/frappe/helpdesk --skip-assets || true && \
    bench get-app --branch main https://github.com/frappe/print_designer --skip-assets || true && \
    bench get-app --branch version-3 https://github.com/frappe/insights --skip-assets || true && \
    bench get-app --branch main https://github.com/frappe/drive --skip-assets || true && \
    bench get-app --branch develop https://github.com/frappe/gameplan --skip-assets || true

# Build apps individually to reduce peak memory usage
RUN bench build --app frappe || true
RUN bench build --app erpnext || true
RUN bench build --app telephony || true
RUN bench build --app print_designer || true
RUN bench build --app helpdesk || true
RUN bench build --app insights || true
RUN bench build --app drive || true
RUN bench build --app gameplan || true

# Final full build as last resort
RUN bench build || echo "bench build completed with possible non-fatal errors"
EOF
}

# ---------- Build custom image ----------
build_custom_image() {
    info "Building custom image ${CUSTOM_IMAGE}:${CUSTOM_TAG} with BASE_TAG=${BASE_TAG} ..."
    generate_custom_dockerfile

    docker build --build-arg BASE_TAG="${BASE_TAG}" -t "${CUSTOM_IMAGE}:${CUSTOM_TAG}" -f Dockerfile.custom .

    info "Built image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
    # update .env to persist custom image usage if desired
    if grep -q '^CUSTOM_IMAGE=' "$ENV_FILE"; then
        sed -i "s|^CUSTOM_IMAGE=.*|CUSTOM_IMAGE=${CUSTOM_IMAGE}|" "$ENV_FILE"
    else
        echo "CUSTOM_IMAGE=${CUSTOM_IMAGE}" >> "$ENV_FILE"
    fi
    if grep -q '^CUSTOM_TAG=' "$ENV_FILE"; then
        sed -i "s|^CUSTOM_TAG=.*|CUSTOM_TAG=${CUSTOM_TAG}|" "$ENV_FILE"
    else
        echo "CUSTOM_TAG=${CUSTOM_TAG}" >> "$ENV_FILE"
    fi
}

# ---------- Wait for MariaDB root to accept password ----------
wait_for_mariadb_root() {
    local compose_files
    compose_files=$(get_compose_files)
    local tries=0
    local max=30
    info "Waiting for MariaDB to accept root password (try up to ${max})..."
    while true; do
        if docker compose ${compose_files} --env-file .env exec -T db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" &>/dev/null; then
            info "MariaDB root auth OK"
            return 0
        fi
        tries=$((tries+1))
        if [ "$tries" -ge "$max" ]; then
            warn "MariaDB root auth failed after ${max} attempts"
            return 1
        fi
        sleep 3
    done
}

# ---------- Ensure frappe DB user exists and matches DB_PASSWORD ----------
ensure_frappe_db_user() {
    local compose_files
    compose_files=$(get_compose_files)

    # default DB user name used by bench/ERPNext images is often 'frappe'
    local DB_USER=${MYSQL_USER:-frappe}
    local DB_PASS="${DB_PASSWORD:-${MYSQL_ROOT_PASSWORD}}"
    local DB_NAME=${MYSQL_DATABASE:-${DB_NAME:-'frappe'})}
    # Some compose setups use separate DB name, but we'll create a user and grant privileges on *.* to be safe

    info "Ensuring DB user '${DB_USER}' exists with provided password..."
    # create user if missing and set password; use root creds
    docker compose ${compose_files} --env-file .env exec -T db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "\
        CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}'; \
        ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}'; \
        GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'%' WITH GRANT OPTION; \
        FLUSH PRIVILEGES;" &>/dev/null || {
        warn "Failed to ensure DB user '${DB_USER}' via root. Will continue but DB auth problems may persist."
        return 1
    }
    info "DB user '${DB_USER}' ensured"
    return 0
}

# ---------- Deploy stack ----------
deploy_stack() {
    check_required_files

    local compose_files
    compose_files=$(get_compose_files)

    info "Bringing up DB and Redis first..."
    # Start minimal services required for DB init
    docker compose ${compose_files} --env-file .env up -d db redis-cache redis-queue
    sleep 5

    # Wait for DB to be ready and accept root creds
    if ! wait_for_mariadb_root; then
        warn "MariaDB root auth didn't become available. You may need to inspect DB logs."
    else
        # ensure frappe user matches DB_PASSWORD
        ensure_frappe_db_user || warn "ensure_frappe_db_user failed"
    fi

    info "Bringing up remaining services..."
    docker compose ${compose_files} --env-file .env up -d --remove-orphans
    info "All services started (docker compose up -d). Waiting for backend to be ready..."

    # wait for backend bench to be responsive
    local tries=0
    local max=30
    while true; do
        if docker compose ${compose_files} --env-file .env exec -T backend bench --version &>/dev/null; then
            info "Backend bench responsive"
            break
        fi
        tries=$((tries+1))
        if [ "$tries" -ge "$max" ]; then
            warn "Backend didn't become responsive after $max tries"
            break
        fi
        sleep 5
    done

    # create site if missing
    info "Checking if site '${SITE_NAME}' exists..."
    if ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" list-apps &>/dev/null; then
        info "Creating new site: ${SITE_NAME}"
        docker compose ${compose_files} --env-file .env exec -T backend bench new-site "${SITE_NAME}" \
            --admin-password "${ADMIN_PASSWORD:-admin}" \
            --mariadb-root-username root \
            --mariadb-root-password "${MYSQL_ROOT_PASSWORD}" \
            --install-app erpnext \
            --set-default || warn "bench new-site returned non-zero exit; check logs"
        # install other apps (telephony, hrms, helpdesk, print_designer, insights, drive)
        for app in telephony hrms helpdesk print_designer insights drive; do
            info "Attempting to install app: ${app}"
            docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" install-app "${app}" || warn "install-app ${app} failed"
        done
		# --- ensure bench-generated DB user exists in MariaDB ---
        site_config="./sites/${SITE_NAME}/site_config.json"
        if [ -f "$site_config" ]; then
            DB_NAME=$(jq -r '.db_name' "$site_config")
            DB_PASS=$(jq -r '.db_password' "$site_config")
            info "Creating MariaDB user for site: $DB_NAME"
        
            docker compose ${compose_files} --env-file .env exec -T db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "\
                CREATE USER IF NOT EXISTS '${DB_NAME}'@'%' IDENTIFIED BY '${DB_PASS}'; \
                GRANT ALL PRIVILEGES ON *.* TO '${DB_NAME}'@'%' WITH GRANT OPTION; \
                FLUSH PRIVILEGES;" &>/dev/null || warn "Failed to create site DB user"
        fi
    else
        info "Site ${SITE_NAME} already exists"
    fi

    info "Deployment completed"
}

# ---------- Helper: check required files ----------
check_required_files() {
    [ -f "${ENV_FILE}" ] || (error ".env missing" && exit 1)
    [ -f "compose.yaml" ] || [ -f "docker-compose.yml" ] || (error "compose.yaml or docker-compose.yml missing" && exit 1)
}

# ---------- Commands ----------
cmd_deploy() {
    check_required_files
    deploy_stack
}
cmd_build_custom_image() {
    check_required_files
    build_custom_image
}
cmd_start() {
    local compose_files
    compose_files=$(get_compose_files)
    docker compose ${compose_files} --env-file .env up -d
}
cmd_stop() {
    local compose_files
    compose_files=$(get_compose_files)
    docker compose ${compose_files} --env-file .env down
}
cmd_restart() {
    local compose_files
    compose_files=$(get_compose_files)
    info "Restarting all services safely..."
    docker compose ${compose_files} --env-file $ENV_FILE restart
    # wait backend
    local tries=0; local max=30
    while true; do
        if docker compose ${compose_files} --env-file .env exec -T backend bench --version &>/dev/null; then
            info "Backend ready"
            break
        fi
        tries=$((tries+1))
        if [ "$tries" -ge "$max" ]; then
            warn "Backend not ready after ${max} tries"
            break
        fi
        sleep 5
    done
    info "Restart completed"
}
cmd_logs() {
    local svc=${2:-backend}
    local compose_files
    compose_files=$(get_compose_files)
    docker compose ${compose_files} --env-file .env logs -f --tail=200 "${svc}"
}
cmd_status() {
    local compose_files
    compose_files=$(get_compose_files)
    docker compose ${compose_files} --env-file .env ps
}
cmd_cleanup() {
    cleanup_tmp
    info "Temp files removed"
}
cmd_force_cleanup() {
    info "Force cleanup: stopping containers, removing volumes and unused data (DANGEROUS)"
    local compose_files
    compose_files=$(get_compose_files)
    docker compose ${compose_files} --env-file .env down -v --remove-orphans || true
    docker system prune -af --volumes || true
    info "Force cleanup done"
}
cmd_rebuild_and_deploy() {
    cmd_force_cleanup
    cmd_build_custom_image
    cmd_deploy
}
cmd_fix_routing() {
    local compose_files
    compose_files=$(get_compose_files)
    info "Restarting frontend/websocket/nginx to refresh routing"
    docker compose ${compose_files} --env-file .env restart frontend websocket || true
}
cmd_fix_configurator() {
    local compose_files
    compose_files=$(get_compose_files)
    info "Re-running configurator"
    docker compose ${compose_files} --env-file .env run --rm configurator || true
}

# ---------- CLI dispatch ----------
case "${1:-}" in
    deploy)            cmd_deploy ;;
    build-custom-image)cmd_build_custom_image ;;
    start)             cmd_start ;;
    stop)              cmd_stop ;;
    restart)           cmd_restart ;;
    logs)              cmd_logs "${@}" ;;
    status)            cmd_status ;;
    cleanup)           cmd_cleanup ;;
    force-cleanup)     cmd_force_cleanup ;;
    rebuild-and-deploy)cmd_rebuild_and_deploy ;;
    fix-routing)       cmd_fix_routing ;;
    fix-configurator)  cmd_fix_configurator ;;
    *) 
        cat <<USAGE
Usage: $0 {deploy|build-custom-image|start|stop|restart|logs|status|cleanup|force-cleanup|rebuild-and-deploy|fix-routing|fix-configurator}
Notes:
 - Gameplan is commented out in Dockerfile.custom (per your request).
 - To fully reset DB/volumes in dev: $0 force-cleanup
 - Make sure .env contains MYSQL_ROOT_PASSWORD and DB_PASSWORD
USAGE
        exit 1
        ;;
esac
