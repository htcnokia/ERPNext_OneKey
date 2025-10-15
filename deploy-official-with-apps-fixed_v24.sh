#!/bin/bash
: "${ERPNEXT_VERSION:=v15.83.0}"
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

deploy_log="${PROJECT_DIR}/deploy.log"
: "${deploy_log:=${PROJECT_DIR}/deploy.log}"
GITHUB_TOKEN=ghp_gbF5169xeMV7p8Uezby62ov2Wk77Mh2kch09Ps

# clean .log
find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.log" -exec rm -f {} \;

# ---------- Logging ----------
info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

# ---------- Utility: load .env safely ----------
load_env_file() {
    local env_file="$1"
    if [ ! -f "$env_file" ]; then
        error ".env file not found: ${env_file}"
        exit 1
    fi
    set -o allexport
    # Only accept simple KEY=VALUE lines; strip CRs
    # Use awk to avoid exporting comments or malformed lines
    eval "$(awk '/^[A-Za-z_][A-Za-z0-9_]*=/{gsub(/\r$/,"",$0); print "export "$0}' "$env_file")"
    set +o allexport
    info "Environment variables loaded from ${env_file}"
}

# Load .env immediately so exported vars are available to functions
load_env_file "$ENV_FILE"

# defaults (if .env lacks them) - unified to latest stable
BASE_TAG="${ERPNEXT_VERSION}"
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

# ---------- Check if build is complete ----------
# Check that built image contains required app directories
is_build_complete() {
    local required_apps=(telephony hrms helpdesk print_designer insights drive)
    # image must exist
    if ! docker image inspect "${CUSTOM_IMAGE}:${CUSTOM_TAG}" >/dev/null 2>&1; then
        return 1
    fi
    for app in "${required_apps[@]}"; do
        if ! docker run --rm "${CUSTOM_IMAGE}:${CUSTOM_TAG}" test -d "/home/frappe/frappe-bench/apps/${app}" 2>/dev/null; then
            warn "Missing app directory in image: ${app}"
            return 1
        fi
    done
    return 0
}

# ---------- Auto detect latest compatible app versions from GitHub ----------
auto_detect_app_versions() {
    local GITHUB_TOKEN_VALUE="${GITHUB_TOKEN:-}"
    local token_header=()
    local using_token=false
    local UA_HEADER=(-H "User-Agent: frappe-deploy-script")

    if [ -n "${GITHUB_TOKEN_VALUE:-}" ]; then
        token_header=(-H "Authorization: token ${GITHUB_TOKEN_VALUE}")
        using_token=true
        info "Using GitHub token for API requests (pre-checking token health)..."
        local rl_code
        rl_code=$(curl -s -o /dev/null -w "%{http_code}" "${token_header[@]}" "${UA_HEADER[@]}" "https://api.github.com/rate_limit" || true)
        if [ "$rl_code" != "200" ]; then
            warn "GitHub token test failed (HTTP ${rl_code}). Falling back to anonymous mode."
            using_token=false
            token_header=()
        fi
    else
        warn "No GITHUB_TOKEN found, using anonymous mode."
    fi

    github_api_request() {
        local url="$1"
        local response
        if [ "$using_token" = true ]; then
            response=$(curl -s "${token_header[@]}" "${UA_HEADER[@]}" "$url" || true)
        else
            response=$(curl -s "${UA_HEADER[@]}" "$url" || true)
        fi
        echo "$response"
    }

    safe_jq_names() {
        # 安全 jq 提取 tags 名称列表，即使空或无效也不会退出脚本
        jq -r 'try (.[].name) // empty' 2>/dev/null || echo ""
    }

    get_repo_tags() {
        local repo="$1"
        local body
        body=$(github_api_request "https://api.github.com/repos/${repo}/tags?per_page=100")
        local count
        count=$(echo "$body" | jq 'length' 2>/dev/null || echo 0)
        info "Fetched ${count} tags for ${repo}"
        echo "$body" | safe_jq_names
    }

    get_repo_branches() {
        local repo="$1"
        local body
        body=$(github_api_request "https://api.github.com/repos/${repo}/branches?per_page=100")
        local count
        count=$(echo "$body" | jq 'length' 2>/dev/null || echo 0)
        info "Fetched ${count} branches for ${repo}"
        echo "$body" | safe_jq_names
    }

    get_highest_tag_for_major() {
        local repo="$1"
        local major="$2"
        get_repo_tags "$repo" | grep -E "^v?${major}\." | sort -V | tail -n1 || true
    }

    get_highest_tag_overall() {
        local repo="$1"
        get_repo_tags "$repo" | grep -E '^v?[0-9]' | sort -V | tail -n1 || true
    }

    get_highest_major() {
        local repo="$1"
        get_repo_tags "$repo" | grep -E '^v?[0-9]+' | sed -E 's/^v?([0-9]+).*/\1/' | sort -n | tail -n1 || true
    }

    # ---------- 检测主版本 ----------
    local frappe_major erpnext_major major_ver
    frappe_major="$(get_highest_major "frappe/frappe")"
    erpnext_major="$(get_highest_major "frappe/erpnext")"

    if [ -z "${frappe_major:-}" ] || [ -z "${erpnext_major:-}" ]; then
        warn "Failed to detect frappe/erpnext major versions from GitHub — falling back to Docker Hub."
        local docker_raw docker_latest docker_major
        docker_raw="$(curl -s "https://registry.hub.docker.com/v2/repositories/frappe/erpnext/tags?page_size=100" || true)"
        docker_latest="$(echo "$docker_raw" | jq -r '.results[]?.name' 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)"
        if [ -n "${docker_latest:-}" ]; then
            docker_major="$(echo "$docker_latest" | sed -E 's/^v([0-9]+)\..*/\1/' || true)"
            info "Using Docker Hub ERPNext tag ${docker_latest} (major v${docker_major})"
            frappe_major="${docker_major}"
            erpnext_major="${docker_major}"
        else
            warn "No valid Docker Hub tag found. Defaulting to v15."
            frappe_major=15
            erpnext_major=15
        fi
    fi

    major_ver=$(( frappe_major > erpnext_major ? frappe_major : erpnext_major ))
    info "🔍 Detected latest major version: v${major_ver}"

    # ---------- 各 App ----------
    FRAPPE_BRANCH="$(get_highest_tag_for_major "frappe/frappe" "$major_ver")"
    ERPNEXT_BRANCH="$(get_highest_tag_for_major "frappe/erpnext" "$major_ver")"

    local hrms_branches target_branch prev_branch
    hrms_branches="$(get_repo_branches "frappe/hrms")"
    target_branch="version-${major_ver}"
    prev_branch="version-$((major_ver - 1))"

    if echo "${hrms_branches:-}" | grep -q "^${target_branch}$"; then
        HRMS_BRANCH="${target_branch}"
    elif echo "${hrms_branches:-}" | grep -q "^${prev_branch}$"; then
        HRMS_BRANCH="${prev_branch}"
    else
        HRMS_BRANCH="$(get_highest_tag_overall "frappe/hrms")"
    fi

    TELEPHONY_BRANCH="develop"
    HELP_DESK_BRANCH="$(get_highest_tag_overall "frappe/helpdesk")"
    PRINT_DESIGNER_BRANCH="$(get_highest_tag_overall "frappe/print_designer")"
    INSIGHTS_BRANCH="$(get_highest_tag_overall "frappe/insights")"
    DRIVE_BRANCH="$(get_highest_tag_overall "frappe/drive")"

    # fallback 默认值（保证生产稳定）
    if [ -z "${FRAPPE_BRANCH:-}" ]; then FRAPPE_BRANCH="v${major_ver}.x-latest"; fi
    if [ -z "${ERPNEXT_BRANCH:-}" ]; then ERPNEXT_BRANCH="v${major_ver}.x-latest"; fi
    if [ -z "${HRMS_BRANCH:-}" ]; then HRMS_BRANCH="develop"; fi
    if [ -z "${HELP_DESK_BRANCH:-}" ]; then HELP_DESK_BRANCH="develop"; fi
    if [ -z "${PRINT_DESIGNER_BRANCH:-}" ]; then PRINT_DESIGNER_BRANCH="develop"; fi
    if [ -z "${INSIGHTS_BRANCH:-}" ]; then INSIGHTS_BRANCH="develop"; fi
    if [ -z "${DRIVE_BRANCH:-}" ]; then DRIVE_BRANCH="develop"; fi

    CUSTOM_IMAGE="my-erpnext-v${major_ver}-custom"

    export FRAPPE_BRANCH ERPNEXT_BRANCH HRMS_BRANCH TELEPHONY_BRANCH HELP_DESK_BRANCH \
           PRINT_DESIGNER_BRANCH INSIGHTS_BRANCH DRIVE_BRANCH CUSTOM_IMAGE

    info "✅ Auto-selected versions (aligned with v${major_ver}):"
    echo "  FRAPPE_BRANCH=${FRAPPE_BRANCH}"
    echo "  ERPNEXT_BRANCH=${ERPNEXT_BRANCH}"
    echo "  HRMS_BRANCH=${HRMS_BRANCH}"
    echo "  TELEPHONY_BRANCH=${TELEPHONY_BRANCH}"
    echo "  HELP_DESK_BRANCH=${HELP_DESK_BRANCH}"
    echo "  PRINT_DESIGNER_BRANCH=${PRINT_DESIGNER_BRANCH}"
    echo "  INSIGHTS_BRANCH=${INSIGHTS_BRANCH}"
    echo "  DRIVE_BRANCH=${DRIVE_BRANCH}"
    echo "  CUSTOM_IMAGE=${CUSTOM_IMAGE}"
}


# ---------- Check app versions against .env ----------
check_app_versions() {
    info "Checking app versions against .env..."

    # Get latest versions from GitHub
    auto_detect_app_versions

    # Define expected versions from GitHub
    local github_versions=(
        "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
        "ERPNEXT_BRANCH=${ERPNEXT_BRANCH}"
        "HRMS_BRANCH=${HRMS_BRANCH}"
        "TELEPHONY_BRANCH=${TELEPHONY_BRANCH}"
        "HELP_DESK_BRANCH=${HELP_DESK_BRANCH}"
        "PRINT_DESIGNER_BRANCH=${PRINT_DESIGNER_BRANCH}"
        "INSIGHTS_BRANCH=${INSIGHTS_BRANCH}"
        "DRIVE_BRANCH=${DRIVE_BRANCH}"
        "CUSTOM_IMAGE=${CUSTOM_IMAGE}"
    )

    local env_versions=()
    local needs_update=false

    # Read current .env versions
    for version in "${github_versions[@]}"; do
        local key="${version%%=*}"
        local github_value="${version#*=}"
        local env_value=$(grep "^${key}=" "$ENV_FILE" | cut -d'=' -f2-)

        if [ -z "$env_value" ]; then
            info "Version for ${key} not found in .env, update required"
            needs_update=true
            break
        elif [ "$env_value" != "$github_value" ]; then
            info "Version mismatch for ${key}: .env=${env_value}, GitHub=${github_value}"
            needs_update=true
            break
        fi
    done

    if [ "$needs_update" = false ]; then
        info "All app versions match .env, no update required"
        return 1
    else
        info "Version mismatch detected, proceeding with build and deploy"
        return 0
    fi
}

generate_custom_dockerfile() {
    info "Generating Dockerfile.custom..."
    local erpnext_ver="${ERPNEXT_VERSION:-${BASE_TAG}}"
    local github_erpnext_ver="${GITHUB_ERPNEXT_VERSION:-${erpnext_ver}}"

    # ---------- 获取 Docker Hub 最新大版本 ----------
    local docker_raw latest_tag
    docker_raw=$(curl -s "https://registry.hub.docker.com/v2/repositories/frappe/erpnext/tags?page_size=100")
    latest_tag=$(echo "$docker_raw" | jq -r '.results[]?.name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
    erpnext_ver="${latest_tag:-${BASE_TAG}}"
    echo "Docker Hub ERPNext latest version: $latest_tag"

    # ---------- 版本比较 ----------
    local erpnext_ver_num=$(echo "$erpnext_ver" | sed 's/^v//')
    local github_ver_num=$(echo "$github_erpnext_ver" | sed 's/^v//')
    local use_github=false
    if [ "$(printf '%s\n' "$github_ver_num" "$erpnext_ver_num" | sort -V | tail -n1)" = "$github_ver_num" ] && [ "$github_ver_num" != "$erpnext_ver_num" ]; then
        use_github=true
    fi

    # ---------- 检查 wheels ----------
    local wheels_copy=""
    if [ -d "$PROJECT_DIR/wheels" ]; then
        local wheel_files=("$PROJECT_DIR/wheels"/*.whl)
        if [ -e "${wheel_files[0]}" ]; then
            info "Found wheels files, will include them in Docker build..."
            wheels_copy="COPY wheels/*.whl /wheels/
RUN pip install --no-cache-dir /wheels/*.whl"
        fi
    fi

    # ---------- 设置基础镜像 ----------
    local from_line="FROM frappe/erpnext:${erpnext_ver}"
    local extra_clone=""
    if [ "$use_github" = true ]; then
        auto_detect_app_versions
        github_erpnext_ver=${ERPNEXT_BRANCH}
        erpnext_ver=${ERPNEXT_BRANCH}
        ERPNEXT_VERSION=${ERPNEXT_BRANCH}
        info "Using GitHub source for ERPNext: ${github_erpnext_ver}"
        extra_clone="RUN rm -rf apps/erpnext && git clone --depth 1 --branch ${github_erpnext_ver} https://github.com/frappe/erpnext /home/frappe/frappe-bench/apps/erpnext
RUN npm install --prefix apps/erpnext onscan.js
RUN npm install -g npm@latest && npm install esbuild@latest && npx update-browserslist-db@latest"
    else
        info "Using Docker Hub image for ERPNext: ${erpnext_ver}"
    fi

    # ---------- 生成 Dockerfile ----------
    cat > Dockerfile.custom <<EOF
ARG ERPNEXT_VERSION=${erpnext_ver}
$from_line

ENV NODE_OPTIONS="--max-old-space-size=8192"

USER root
RUN apt-get update && apt-get install -y git pkg-config default-libmysqlclient-dev build-essential mariadb-client curl unzip jq && rm -rf /var/lib/apt/lists/*
$wheels_copy
USER frappe
WORKDIR /home/frappe/frappe-bench

$extra_clone

RUN mkdir -p sites && echo '{"socketio_port": 9000}' > sites/common_site_config.json

# Download / get additional apps
for app in telephony hrms helpdesk print_designer insights drive; do
    branch_var="\${app^^}_BRANCH"
    repo_url="https://github.com/frappe/\$app"
    RUN bench get-app --branch \${!branch_var} \$repo_url --skip-assets
done

# Build apps
for app in frappe erpnext telephony print_designer helpdesk insights drive; do
    RUN bench build --app \$app
done
EOF
}


# ---------- Build custom image ----------
build_custom_image() {
    info "Building custom image ${CUSTOM_IMAGE}:${CUSTOM_TAG} with BASE_TAG=${BASE_TAG} ..."
    generate_custom_dockerfile

    local build_opts=(--build-arg ERPNEXT_VERSION="${BASE_TAG}" -t "${CUSTOM_IMAGE}:${CUSTOM_TAG}" -f Dockerfile.custom)
    # default: pull base to get latest security fixes
    build_opts=(--pull "${build_opts[@]}")

    docker build "${build_opts[@]}" .

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

    local DB_USER=${MYSQL_USER:-frappe}
    local DB_PASS="${DB_PASSWORD:-${MYSQL_ROOT_PASSWORD}}"
    local DB_NAME=${MYSQL_DATABASE:-${DB_NAME:-'frappe'}}

    info "Ensuring DB user '${DB_USER}' exists with provided password..."
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
# ---------- check mysql user ----------
check_mysql_user() {
    local compose_files
    compose_files=$(get_compose_files)
    local site_name="${SITE_NAME}"

    info "Checking MariaDB user for site '${site_name}'..."

    # 从 backend 容器读取 site_config.json
    local SITE_JSON
    if ! SITE_JSON=$(docker compose ${compose_files} --env-file .env exec -T backend cat "sites/${site_name}/site_config.json" 2>/dev/null); then
        warn "Failed to read site_config.json from backend container."
        return 1
    fi
    if [ -z "$SITE_JSON" ]; then
        warn "site_config.json not found or empty in backend container for site ${site_name}"
        return 1
    fi
	
    # 检查是否存在 SaaS 限制字段 user_type_doctype_limit，并清理
    if docker compose ${compose_files} --env-file .env exec -T backend grep -q '"user_type_doctype_limit"' "sites/${site_name}/site_config.json"; then
        info "Removing SaaS restriction field 'user_type_doctype_limit' from site_config.json..."

        docker compose ${compose_files} --env-file .env exec -T backend python3 - <<PYCODE
import json, pathlib
path = pathlib.Path("sites/${site_name}/site_config.json")
try:
    data = json.loads(path.read_text())
    if "user_type_doctype_limit" in data:
        data.pop("user_type_doctype_limit", None)
        path.write_text(json.dumps(data, indent=1))
        print("Cleaned site_config.json successfully.")
except Exception as e:
    print("⚠️ Failed to clean site_config.json:", e)
PYCODE
    fi
	
    # 提取数据库名和密码
    local DB_NAME DB_PASS DB_USER
    DB_NAME=$(echo "$SITE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('db_name',''))" 2>/dev/null || true)
    DB_PASS=$(echo "$SITE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('db_password',''))" 2>/dev/null || true)
    DB_USER=${DB_NAME:-frappe}

    if [ -z "$DB_NAME" ] || [ -z "$DB_PASS" ]; then
        warn "Could not parse db_name or db_password from site_config.json"
        return 1
    fi

    info "Verifying MariaDB user '${DB_USER}' connectivity..."

    if docker compose ${compose_files} --env-file .env exec -T db mariadb -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "SELECT 1;" &>/dev/null; then
        info "User '${DB_USER}' can connect and has access — nothing to do."
    else
        warn "User '${DB_USER}' cannot connect — attempting to create/update via root..."

        docker compose ${compose_files} --env-file .env exec -T db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "\
                DROP USER IF EXISTS '${DB_USER}'@'%';\
                CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';\
                GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'%' WITH GRANT OPTION;\
                FLUSH PRIVILEGES;" \
        && info "User '${DB_USER}' created/updated successfully." \
        || warn "Failed to create/update user '${DB_USER}' via root."
    fi

    info "Verifying updated grants for '${DB_USER}'..."
    docker compose ${compose_files} --env-file .env exec -T db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW GRANTS FOR '${DB_USER}'@'%';" || true
}

# ---------- Independent Site Health Verification Function ----------
# Usage: verify_site_health [SITE_NAME] [optional: --strict] [optional: --log-file]
# Returns 0 if healthy, 1 if issues found. For production monitoring.
verify_site_health() {
    local site_name="${1:-${SITE_NAME}}"
    local strict_mode=false
    local health_log="${PROJECT_DIR}/health_check.log"
    shift
    info "checking log file $health_log..."
    # Parse optional args
    while [[ $# -gt 0 && $1 == --* ]]; do
        case $1 in
            --strict)
                strict_mode=true
                shift ;;
            --log-file)
                health_log="$2"
                shift 2 ;;
            *)
                warn "Unknown arg: $1 - ignoring"
                shift ;;
        esac
    done

    local compose_files
    compose_files=$(get_compose_files)

    echo "[$(date)] Health check started for site '${site_name}'" >> "$health_log"
    local health_ok=true

    # 1. Verify apps installation
    info "Verifying app installation for site '${site_name}'..."
    local installed_apps
    installed_apps=$(docker compose ${compose_files} --env-file .env exec -T backend bench --site "${site_name}" list-apps 2>/dev/null || echo "")
    local expected_apps="erpnext telephony hrms helpdesk print_designer insights drive"
    local missing_apps=""
    for app in $expected_apps; do
        if ! echo "$installed_apps" | grep -q "^$app[[:space:]]"; then
            missing_apps="$missing_apps $app"
        fi
    done
    if [ -n "$missing_apps" ]; then
        health_ok=false
        error "Missing apps: $missing_apps. Installed: $installed_apps"
        echo "Missing apps: $missing_apps" >> "$health_log"
        [ "$strict_mode" = true ] && return 1
    else
        info "All apps verified successfully installed ✅"
    fi

    # 2. bench doctor for scheduler health
    info "Running bench doctor for scheduler health check..."
    local doctor_output
    doctor_output=$(docker compose ${compose_files} --env-file .env exec -T backend bench doctor 2>&1 || echo "Error running bench doctor")
    echo "$doctor_output" >> "$health_log"
    if echo "$doctor_output" | grep -q "Workers online: [0-9]\+" || echo "$doctor_output" | grep -q "No issues"; then
        info "Scheduler health OK ✅"
    else
        health_ok=false
        error "Scheduler issues detected: $doctor_output"
        [ "$strict_mode" = true ] && return 1
    fi

    # 3. Optional: Quick migrate check (schema sync)
    info "Running quick migrate check..."
    local migrate_output
    migrate_output=$(docker compose ${compose_files} --env-file .env exec -T backend bench --site "${site_name}" migrate 2>&1 || echo "Error running bench migrate")
    echo "$migrate_output" >> "$health_log"
    if echo "$migrate_output" | grep -q -E "Error|Traceback"; then
        health_ok=false
        warn "Migrate step failed - check manually: $migrate_output"
    else
        info "Schema up-to-date ✅"
    fi

    # 4. DB connectivity (reuse check_mysql_user)
    info "Verifying DB connectivity..."
    if check_mysql_user "${site_name}"; then
        info "DB connectivity OK ✅"
    else
        health_ok=false
        error "DB connectivity issues detected."
        [ "$strict_mode" = true ] && return 1
    fi

    if [ "$health_ok" = true ]; then
        info "Site '${site_name}' health check passed - Production Ready ✅"
        echo "[$(date)] Health check passed for site '${site_name}'" >> "$health_log"
        return 0
    else
        error "Site '${site_name}' health check failed - Review $health_log for details."
        echo "[$(date)] Health check failed for site '${site_name}'" >> "$health_log"
        return 1
    fi
}
# ---------- Deploy stack ----------

deploy_stack() {
    local deploy_log="${PROJECT_DIR}/deploy.log"
    echo "[$(date)] Starting deployment for site '${SITE_NAME}'" >> "$deploy_log"

    check_required_files

    local compose_files
    compose_files=$(get_compose_files)

    info "Bringing up DB and Redis first..."
    docker compose ${compose_files} --env-file .env up -d db redis-cache redis-queue >> "$deploy_log" 2>&1
    sleep 5

    if ! wait_for_mariadb_root; then
        error "MariaDB root auth failed - critical for production. Check logs: tail -f $deploy_log"
        exit 1
    else
        ensure_frappe_db_user || {
            error "DB user setup failed - aborting deployment."
            exit 1
        }
    fi

    info "Bringing up remaining services..."
    docker compose ${compose_files} --env-file .env up -d --remove-orphans >> "$deploy_log" 2>&1
    info "All services started (docker compose up -d). Waiting for backend to be ready..."

    local tries=0
    local max=30
    while true; do
        if docker compose ${compose_files} --env-file .env exec -T backend bench --version &>/dev/null; then
            info "Backend bench responsive"
            break
        fi
        tries=$((tries+1))
        if [ "$tries" -ge "$max" ]; then
            error "Backend not responsive after $max tries - critical failure."
            exit 1
        fi
        sleep 5
    done

    # Pre-backup if site exists
    if docker compose ${compose_files} --env-file .env exec -T backend test -f "sites/${SITE_NAME}/site_config.json" >/dev/null 2>&1; then
        info "Backing up existing site '${SITE_NAME}'..."
        docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" backup >> "$deploy_log" 2>&1 || warn "Backup failed - proceed with caution"
    fi

    info "Checking if site '${SITE_NAME}' exists..."
    if ! docker compose ${compose_files} --env-file .env exec -T backend test -f "sites/${SITE_NAME}/site_config.json" >/dev/null 2>&1 || \
       ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" list-apps &>/dev/null; then
        info "Creating new site: ${SITE_NAME}"
        if ! docker compose ${compose_files} --env-file .env exec -T backend bench new-site "${SITE_NAME}" \
            --admin-password "${ADMIN_PASSWORD:-admin}" \
            --mariadb-root-username root \
            --mariadb-root-password "${MYSQL_ROOT_PASSWORD}" \
            --install-app erpnext \
            --set-default >> "$deploy_log" 2>&1; then
            error "bench new-site failed - aborting."
            exit 1
        fi

        # Install apps with retry
        local install_success=true
        for app in frappe erpnext telephony hrms helpdesk print_designer insights drive; do
            info "Attempting to install app: ${app} (with retry if needed)"
            if ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" install-app "${app}" >> "$deploy_log" 2>&1; then
                info "Retry installing ${app}..."
                if ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" install-app "${app}" >> "$deploy_log" 2>&1; then
                    error "install-app ${app} failed after retry - critical for production."
                    install_success=false
                fi
            fi
        done

        if [ "$install_success" = false ]; then
            error "One or more apps failed to install - aborting deployment. Check $deploy_log"
            exit 1
        fi

        # Run migrate after all installs to sync schema
        info "Running bench migrate for site '${SITE_NAME}'..."
        if ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" migrate >> "$deploy_log" 2>&1; then
            error "bench migrate failed - schema sync critical."
            exit 1
        fi
    else
        info "Site ${SITE_NAME} already exists - performing update..."
        # Update existing site
        info "Running bench update for site '${SITE_NAME}'..."
        if ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" migrate >> "$deploy_log" 2>&1; then
            warn "bench update failed - manual intervention may be required. Check $deploy_log"
        else
            info "Site '${SITE_NAME}' updated successfully."
        fi
        # Rebuild assets
        info "Rebuilding assets for site '${SITE_NAME}'..."
        if ! docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" build --force >> "$deploy_log" 2>&1; then
            warn "Asset rebuild failed - check $deploy_log for details."
        fi
    fi

    check_mysql_user
    info "Stopping ..."
    docker compose ${compose_files} --env-file .env down
    info "Upping ..."
    docker compose ${compose_files} --env-file .env up -d

    # Final: Run full health verification
    info "Running production health verification..."
    if ! verify_site_health "${SITE_NAME}" --strict --log-file "$deploy_log"; then
        error "Health verification failed - deployment aborted. Check $deploy_log"
        exit 1
    fi

    # Final: Restart workers
    info "Restarting bench workers..."
    docker compose ${compose_files} --env-file .env exec -T backend bench restart >> "$deploy_log" 2>&1 || warn "Workers restart non-critical"

    check_mysql_user
    info "Deployment completed - Production Ready ✅"
    echo "[$(date)] Deployment successful for site '${SITE_NAME}'" >> "$deploy_log"
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
    info "Starting all services safely..."
    docker compose ${compose_files} --env-file .env up -d
    check_mysql_user
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
    check_mysql_user
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

cmd_redeploy() {
    local compose_files
    compose_files=$(get_compose_files)
    local deploy_log="${PROJECT_DIR}/deploy.log"

    # Check if backend container is running
    info "Checking if backend container is running..."
    local backend_status
    backend_status=$(docker compose ${compose_files} --env-file .env ps --services --filter "status=running" | grep backend || true)
    if [ -z "$backend_status" ]; then
        warn "Backend container is not running. Attempting to start services..."
        if ! docker compose ${compose_files} --env-file .env up -d >> "$deploy_log" 2>&1; then
            error "Failed to start services - check $deploy_log for details."
            echo "[$(date)] Failed to start services for redeploy" >> "$deploy_log"
            exit 1
        fi
        # Wait for backend to be ready
        local tries=0
        local max=30
        while true; do
            if docker compose ${compose_files} --env-file .env exec -T backend bench --version &>/dev/null; then
                info "Backend container is ready"
                break
            fi
            tries=$((tries+1))
            if [ "$tries" -ge "$max" ]; then
                error "Backend container not ready after $max tries - aborting redeploy."
                echo "[$(date)] Backend container not ready after $max tries" >> "$deploy_log"
                exit 1
            fi
            sleep 5
        done
    else
        info "Backend container is running ✅"
    fi
    echo "[$(date)] Backend container status check completed" >> "$deploy_log"

    # Confirm before dropping site (dangerous in production)
    read -p "DANGER: This will DROP site '${SITE_NAME}' and recreate it, LOSING ALL DATA. Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Redeploy cancelled by user."
        echo "[$(date)] Redeploy cancelled by user" >> "$deploy_log"
        return 1
    fi

    # Backup before drop
    info "Backing up site '${SITE_NAME}' before drop..."
    if docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" backup >> "$deploy_log" 2>&1; then
        info "Backup created in container: sites/${SITE_NAME}/private/backups/$(date +%Y%m%d_%H%M%S)-${SITE_NAME}.tar.xz"
        # Create host backups directory if it doesn't exist
        mkdir -p "${PROJECT_DIR}/backups"
        # Copy backup files to host ./backups
        local backup_dir="sites/${SITE_NAME}/private/backups"
        local latest_timestamp
        latest_timestamp=$(docker compose ${compose_files} --env-file .env exec -T backend ls -t "${backup_dir}" | grep -E "^[0-9]{8}_[0-9]{6}-${SITE_NAME}" | head -n 1 | cut -d'-' -f1)
        if [ -n "$latest_timestamp" ]; then
            docker compose ${compose_files} --env-file .env cp backend:/home/frappe/frappe-bench/${backup_dir}/${latest_timestamp}-${SITE_NAME}-database.sql.gz "${PROJECT_DIR}/backups/" || true
            docker compose ${compose_files} --env-file .env cp backend:/home/frappe/frappe-bench/${backup_dir}/${latest_timestamp}-${SITE_NAME}-site_config_backup.json "${PROJECT_DIR}/backups/" || true
            info "Backup files copied to host: ${PROJECT_DIR}/backups/ (${latest_timestamp}-${SITE_NAME}-*)"
            # 清除容器内的备份文件
            if docker compose ${compose_files} --env-file .env exec -T backend rm -rf "${backup_dir}/*" >> "$deploy_log" 2>&1; then
                info "Container backup files cleared successfully: ${backup_dir}/*"
            else
                warn "Failed to clear container backup files - check $deploy_log for details."
            fi			
        else
            warn "No backup files found in container - check $deploy_log"
            echo "[$(date)] No backup files found for site '${SITE_NAME}'" >> "$deploy_log"
        fi
    else
        warn "Backup failed - proceeding with caution."
        echo "[$(date)] Backup failed for site '${SITE_NAME}'" >> "$deploy_log"
    fi
	
    #停止并清理容器卷
	local compose_files
    compose_files=$(get_compose_files)
	info "Stopping ..."
    docker compose ${compose_files} --env-file .env down -v
	info "Upping ..."	
	docker compose ${compose_files} --env-file .env up -d --build
	
    info "Dropping existing site '${SITE_NAME}'..."
    if docker compose ${compose_files} --env-file .env exec -T backend bench drop-site "${SITE_NAME}" --root-password "${MYSQL_ROOT_PASSWORD}" >> "$deploy_log" 2>&1; then
        info "Site '${SITE_NAME}' dropped successfully."
        echo "[$(date)] Site '${SITE_NAME}' dropped successfully" >> "$deploy_log"
    else
        warn "Site drop failed or site not found - proceeding to create new."
        echo "[$(date)] Site drop failed or site not found for '${SITE_NAME}'" >> "$deploy_log"
    fi

    # Now recreate and deploy
    info "Re-creating and deploying site '${SITE_NAME}'..."
    cmd_deploy
}

cmd_restore_backup() {
    local compose_files
    compose_files=$(get_compose_files)
    local deploy_log="${PROJECT_DIR}/deploy.log"

    # Create backups directory if it doesn't exist
    mkdir -p "${PROJECT_DIR}/backups"

    # List available backups (.tar.xz files) in ./backups
    info "Listing available backups in ${PROJECT_DIR}/backups..."
    local backups
    backups=$(ls -t "${PROJECT_DIR}/backups" | grep "\.tar\.xz$" || true)
    if [ -z "$backups" ]; then
        error "No .tar.xz backup files found in ${PROJECT_DIR}/backups"
        exit 1
    fi

    # Display backups with index
    info "Available backups:"
    local index=1
    local backup_array=()
    while IFS= read -r backup; do
        echo "[$index] $backup"
        backup_array+=("$backup")
        ((index++))
    done <<< "$backups"

    # Prompt user to select a backup
    read -p "Enter the number of the backup to restore (1-${#backup_array[@]}): " -r selection
    if [[ ! $selection =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#backup_array[@]}" ]; then
        error "Invalid selection. Please choose a number between 1 and ${#backup_array[@]}"
        exit 1
    fi

    local selected_backup=${backup_array[$((selection-1))]}
    info "Restoring backup '${selected_backup}' to site '${SITE_NAME}'..."

    # Copy selected backup to container
    docker compose ${compose_files} --env-file .env cp "${PROJECT_DIR}/backups/${selected_backup}" backend:/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups/${selected_backup} || {
        error "Failed to copy backup to container - check $deploy_log"
        exit 1
    }

    # Restore the backup
    if docker compose ${compose_files} --env-file .env exec -T backend bench --site "${SITE_NAME}" restore "sites/${SITE_NAME}/private/backups/${selected_backup}" >> "$deploy_log" 2>&1; then
        info "Backup '${selected_backup}' restored successfully."
    else
        error "Restore failed - check $deploy_log for details."
        exit 1
    fi

    # Verify site health after restore
    info "Running health verification..."
    if ! verify_site_health "${SITE_NAME}" --strict --log-file "$deploy_log"; then
        error "Health verification failed after restore - check $deploy_log for details."
        exit 1
    fi

    info "Restore completed - site '${SITE_NAME}' is ready ✅"
    echo "[$(date)] Restore successful for site '${SITE_NAME}' using backup '${selected_backup}'" >> "$deploy_log"
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
cmd_check_mysql_user(){
    check_mysql_user
}

# Enhanced quick rebuild with cache heuristics and bench doctor verification
cmd_quick_rebuild() {
    local force=false
    local no_pull=false
    shift || true
    while [[ $# -gt 0 && $1 == --* ]]; do
        case $1 in
            --force)
                force=true; shift ;;
            --no-pull)
                no_pull=true; shift ;;
            *) break ;;
        esac
    done

    check_required_files

    local use_cache=true
    if docker image inspect "${CUSTOM_IMAGE}:${CUSTOM_TAG}" >/dev/null 2>&1; then
        if ! is_build_complete; then
            use_cache=false
            warn "Previous build incomplete (missing apps), forcing full rebuild"
        fi
    else
        use_cache=false
        info "No existing image found, full rebuild required"
    fi

    if [ "$force" = true ]; then
        use_cache=false
        info "Force flag set, full rebuild"
    fi

    info "Quick rebuild: use_cache=${use_cache}, no_pull=${no_pull}"

    generate_custom_dockerfile

    local build_opts=()
    [ "$use_cache" = false ] && build_opts+=(--no-cache)
    [ "$no_pull" = false ] && build_opts+=(--pull)
    # Add memory limit to avoid OOM (4GB for build)
    build_opts+=(--memory 4g)

    if ! docker build "${build_opts[@]}" --build-arg ERPNEXT_VERSION="${BASE_TAG}" -t "${CUSTOM_IMAGE}:${CUSTOM_TAG}" -f Dockerfile.custom .; then
        error "Custom image build failed. Check logs for bench get-app or bench build errors."
        exit 1
    fi

    info "Built image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}"

    # persist CUSTOM_IMAGE/CUSTOM_TAG in .env
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

    # Run bench doctor inside the image to validate completeness
    info "Running bench doctor inside the new image to validate build..."
    local cid
    cid=$(docker create "${CUSTOM_IMAGE}:${CUSTOM_TAG}" bash -lc "bench doctor > /tmp/doctor.log 2>&1; echo \$? > /tmp/_doctor_exit")
    docker start -a "$cid" >/dev/null || true
    docker cp "$cid":/tmp/doctor.log ./doctor_${CUSTOM_TAG}.log || true
    docker cp "$cid":/tmp/_doctor_exit ./_doctor_exit || true
    docker rm "$cid" >/dev/null || true
    local doctor_exit=1
    if [ -f ./_doctor_exit ]; then
        doctor_exit=$(cat ./_doctor_exit 2>/dev/null || echo 1)
        rm -f ./_doctor_exit
    fi

    if [ "$doctor_exit" -ne 0 ]; then
        warn "bench doctor detected issues (exit=${doctor_exit}). See ./doctor_${CUSTOM_TAG}.log"
        warn "Consider re-running quick-rebuild --force to do a no-cache rebuild, or inspect the doctor log."
        # optional: fail the overall operation or continue. We'll continue but notify user.
    else
        info "bench doctor passed ✅"
        rm -f ./doctor_${CUSTOM_TAG}.log || true
    fi

    local compose_files
    compose_files=$(get_compose_files)
    info "Bringing up services..."
    docker compose ${compose_files} --env-file .env up -d --remove-orphans
    check_mysql_user
    info "Quick rebuild and start completed"
}

# New: Standalone health check command
cmd_health_check() {
    local site_name="${2:-${SITE_NAME}}"
    local strict_mode=false
    local log_file="${3:-${PROJECT_DIR}/health_check.log}"

    if [[ "${1:-}" == "--strict" ]]; then
        strict_mode=true
        shift
    fi

    check_required_files
    if verify_site_health "$site_name" --strict="$strict_mode" --log-file "$log_file"; then
        info "Health check completed successfully."
        exit 0
    else
        error "Health check failed."
        exit 1
    fi
}

# ---------- Upgrade stack ----------
cmd_upgrade() {
    local deploy_log="${PROJECT_DIR}/deploy.log"
    echo "[$(date)] Starting upgrade process for site '${SITE_NAME}'" >> "$deploy_log"

    # Check required files
    check_required_files

    # Confirm before proceeding
    read -p "WARNING: This will rebuild the custom image and upgrade site '${SITE_NAME}'. Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Upgrade cancelled by user."
        echo "[$(date)] Upgrade cancelled by user" >> "$deploy_log"
        return 1
    fi

    # Step 1: Check app versions
    if ! check_app_versions; then
        info "No version updates required, skipping build and deploy."
        echo "[$(date)] No version updates required for site '${SITE_NAME}'" >> "$deploy_log"
        return 0
    fi

    # Step 2: Build custom image
    info "Building custom image for upgrade..."
    cmd_build_custom_image
    if [ $? -ne 0 ]; then
        error "Custom image build failed - aborting upgrade. Check $deploy_log"
        exit 1
    fi

    # Step 3: Deploy with update
    info "Deploying and upgrading site '${SITE_NAME}'..."
    cmd_deploy
    if [ $? -ne 0 ]; then
        error "Deployment/upgrade failed - check $deploy_log"
        exit 1
    fi

    info "Upgrade completed successfully - site '${SITE_NAME}' is updated ✅"
    echo "[$(date)] Upgrade successful for site '${SITE_NAME}'" >> "$deploy_log"
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
    redeploy)          cmd_redeploy ;;
    fix-routing)       cmd_fix_routing ;;
    fix-configurator)  cmd_fix_configurator ;;
    check_mysql_user)  cmd_check_mysql_user ;;
    quick-rebuild)     cmd_quick_rebuild "${@}" ;;
    health-check)      cmd_health_check "${@}" ;;
    restore-backup)    cmd_restore_backup "${@}" ;;
    verify_site_health) verify_site_health "$@" ;;
    upgrade)           cmd_upgrade ;;
	get_latest_version) auto_detect_app_versions ;;
    *) 
        cat <<USAGE
Usage: $0 {deploy|build-custom-image|start|stop|restart|
    restore-backup|logs|status|cleanup|force-cleanup|
    rebuild-and-deploy|redeploy|fix-routing|fix-configurator|
    check_mysql_user|quick-rebuild|health-check|upgrade|get_latest_version}

Notes:
 - Use --debug as first argument to print loaded env variables.
 - quick-rebuild [--force|--no-pull]: Enhanced rebuild with cache retention; forces no-cache if incomplete or --force; --no-pull skips base image pull.
 - health-check [--strict] [SITE_NAME] [LOG_FILE]: Run standalone site health check (apps, scheduler, assets, DB). Use --strict for production monitoring (exits 1 on failure).
 - After quick-rebuild, a bench doctor run is performed and the log is saved as ./doctor_<TAG>.log if issues are found.
 - upgrade: Rebuilds custom image and upgrades the site with data migration, only if app versions differ from .env.
 - To fully reset DB/volumes in dev: $0 force-cleanup
 - Make sure .env contains MYSQL_ROOT_PASSWORD and DB_PASSWORD
USAGE
        exit 1
        ;;
esac
