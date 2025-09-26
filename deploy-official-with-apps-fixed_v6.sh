#!/bin/bash

# Official Frappe Docker Deployment Script (with Custom Image Build Support)
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

# 修复：正确加载环境变量文件
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

export CUSTOM_IMAGE=my-erpnext-v15-custom
export CUSTOM_TAG=latest
export BASE_TAG=${ERPNEXT_VERSION}
export SITE_NAME=${SITES}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_files() {
    log_info "Checking required files..."
    if [ ! -f "$ENV_FILE" ]; then
        log_error "Environment file not found: $ENV_FILE"
        log_info "Creating from example.env..."
        cp example.env .env
        log_warning "Please edit .env file with your configuration before deploying"
        exit 1
    fi
    if [ ! -f "compose.yaml" ]; then
        log_error "compose.yaml not found in current directory"
        exit 1
    fi
    log_info "Required files check passed ✅"
}

# ---- Custom Image Builder ----
generate_custom_dockerfile() {
    log_info "Generating Dockerfile.custom..."
    
    # 修复：添加 ARG 声明和创建必要的配置文件
    cat > Dockerfile.custom <<EOF
ARG BASE_TAG=${BASE_TAG}
FROM frappe/erpnext:\${BASE_TAG}

USER root
#安装编译依赖
RUN apt-get update && apt-get install -y git \
    pkg-config \
    mariadb-client \
    && rm -rf /var/lib/apt/lists/*
USER frappe
WORKDIR /home/frappe/frappe-bench

# 创建必要的配置文件目录和文件
RUN mkdir -p sites && \\
    echo '{}' > sites/common_site_config.json && \\
    echo '{"socketio_port": 9000}' > sites/common_site_config.json

# 安装应用并构建资源
RUN bench get-app --branch develop https://github.com/frappe/telephony --skip-assets && \\
    bench get-app --branch version-15 https://github.com/frappe/hrms --skip-assets && \\
    bench get-app --branch main https://github.com/frappe/helpdesk --skip-assets && \\
    bench get-app --branch main https://github.com/frappe/print_designer --skip-assets && \\
    bench get-app --branch version-3 https://github.com/frappe/insights --skip-assets && \\
    bench get-app --branch main https://github.com/frappe/drive --skip-assets
	
# 分别构建每个应用以避免内存问题
RUN bench build --app frappe || true
RUN bench build --app erpnext || true  

RUN bench build --app telephony || true
RUN bench build --app print_designer || true
RUN bench build --app helpdesk || true
RUN bench build --app insights || true
RUN bench build --app drive || true

# RUN bench --site "$SITE_NAME" install-app telephony || log_warning "$app may already be installed or failed to install"
# RUN bench --site "$SITE_NAME" install-app print_designer || log_warning "$app may already be installed or failed to install"
# RUN bench --site "$SITE_NAME" install-app helpdesk || log_warning "$app may already be installed or failed to install"
# RUN bench --site "$SITE_NAME" install-app insights || log_warning "$app may already be installed or failed to install"
# RUN bench --site "$SITE_NAME" install-app drive || log_warning "$app may already be installed or failed to install"
# RUN bench --site "$SITE_NAME" migrate


# 最后进行完整构建（如果前面的单独构建失败）
RUN bench build || echo "Some apps may have build issues, but continuing..."

EOF
}

build_custom_image() {
    generate_custom_dockerfile
    log_info "Building custom image..."

    # 使用构建参数传递基础镜像标签
    docker build --build-arg BASE_TAG=${BASE_TAG} -t ${CUSTOM_IMAGE}:${CUSTOM_TAG} -f Dockerfile.custom .
    
    if [ $? -eq 0 ]; then
        log_info "Custom image built successfully: $CUSTOM_IMAGE:$CUSTOM_TAG ✅"
        
        # 更新 .env 文件以使用自定义镜像
        if [ -f "$ENV_FILE" ]; then
            # 备份原始文件
            cp "$ENV_FILE" "$ENV_FILE.backup"
            
            # 更新或添加自定义镜像配置
            if grep -q "CUSTOM_IMAGE" "$ENV_FILE"; then
                sed -i "s/CUSTOM_IMAGE=.*/CUSTOM_IMAGE=${CUSTOM_IMAGE}/" "$ENV_FILE"
            else
                echo "CUSTOM_IMAGE=${CUSTOM_IMAGE}" >> "$ENV_FILE"
            fi
            
            if grep -q "CUSTOM_TAG" "$ENV_FILE"; then
                sed -i "s/CUSTOM_TAG=.*/CUSTOM_TAG=${CUSTOM_TAG}/" "$ENV_FILE"
            else
                echo "CUSTOM_TAG=${CUSTOM_TAG}" >> "$ENV_FILE"
            fi
            
            log_info "Updated .env file with custom image configuration"
        fi
    else
        log_error "Custom image build failed!"
        exit 1
    fi
}

deploy() {
    check_files
    if [ -f .env ]; then
        export $(grep -v '^#' .env | xargs)
    fi
	
    if [ "${BUILD_CUSTOM_IMAGE}" = "true" ]; then
        build_custom_image
    fi
    
    log_info "Deploying with official compose.yaml + overrides..."
    
    # 根据是否使用自定义镜像选择不同的 compose 配置
    if [ -n "${CUSTOM_IMAGE}" ] && docker images "${CUSTOM_IMAGE}:${CUSTOM_TAG}" &> /dev/null; then
        log_info "Using custom image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
        # 创建 overrides 目录下的自定义镜像配置文件
        mkdir -p overrides
        cat > overrides/compose.custom.yaml <<EOF
version: "3"
services:
  backend:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  frontend:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  queue-default:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  queue-long:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  queue-short:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  scheduler:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  websocket:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
  configurator:
    image: ${CUSTOM_IMAGE}:${CUSTOM_TAG}
    pull_policy: never
EOF
        COMPOSE_FILES="-f compose.yaml -f overrides/compose.custom.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.noproxy.yaml -f overrides/compose.redis.yaml"
    else
        COMPOSE_FILES="-f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.noproxy.yaml -f overrides/compose.redis.yaml"
    fi
    
    docker compose $COMPOSE_FILES --env-file .env up -d
    
    log_info "Services started! Waiting for initialization..."
    sleep 15
    
    source .env
    SITE_NAME=${FRAPPE_SITE_NAME_HEADER:-localhost}
    
    # 等待服务完全启动
    log_info "Waiting for backend service to be ready..."
    for i in {1..30}; do
        if docker compose $COMPOSE_FILES exec -T backend bench --version &> /dev/null; then
            log_info "Backend service is ready!"
            break
        fi
        log_info "Waiting for backend service... ($i/30)"
        sleep 10
    done
    
    # 检查站点是否存在
    if ! docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" list-apps &> /dev/null; then
        log_info "Creating new site: $SITE_NAME"
        docker compose $COMPOSE_FILES exec -T backend bench new-site "$SITE_NAME" \
            --admin-password admin \
            --mariadb-root-username root \
            --mariadb-root-password "${MYSQL_ROOT_PASSWORD:-admin}" \
            --install-app erpnext \
            --set-default
        
        # 如果使用自定义镜像，安装额外的应用
        if [ -n "${CUSTOM_IMAGE}" ] && docker images "${CUSTOM_IMAGE}:${CUSTOM_TAG}" &> /dev/null; then
            log_info "Installing additional apps on site..."
            docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" install-app telephony || log_warning "Failed to install telephony"
            docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" install-app hrms || log_warning "Failed to install hrms"
            docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" install-app helpdesk || log_warning "Failed to install helpdesk"
            docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" install-app print_designer || log_warning "Failed to install print_designer"
            docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" install-app insights || log_warning "Failed to install insights"
            docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" install-app drive || log_warning "Failed to install drive"			
        fi
    else
        log_info "Site $SITE_NAME already exists"
    fi
    
    log_info "Deployment completed successfully! 🎉"
    log_info "Access your ERPNext at: http://localhost:8080"
    log_info "Default credentials: Administrator / admin"
}

# 获取 Docker Compose 文件列表的辅助函数
get_compose_files() {
    if [ -f .env ]; then
        export $(grep -v '^#' .env | xargs)
    fi

    if [ -f "overrides/compose.custom.yaml" ]; then
        echo "-f compose.yaml -f overrides/compose.custom.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.noproxy.yaml -f overrides/compose.redis.yaml"
    else
        echo "-f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.noproxy.yaml -f overrides/compose.redis.yaml"
    fi
}

# 清理临时文件
cleanup() {
    if [ -f "overrides/compose.custom.yaml" ]; then
        rm -f overrides/compose.custom.yaml
    fi
    if [ -f "Dockerfile.custom" ]; then
        rm -f Dockerfile.custom
    fi
}

# 捕获退出信号进行清理
trap cleanup EXIT

case "$1" in
    deploy) 
        deploy 
        ;;
    build-custom-image) 
        build_custom_image 
        ;;
    status) 
        COMPOSE_FILES=$(get_compose_files)
        docker compose $COMPOSE_FILES --env-file .env ps 
        ;;
    start) 
        COMPOSE_FILES=$(get_compose_files)
        docker compose $COMPOSE_FILES --env-file .env up -d 
        ;;
    stop) 
        COMPOSE_FILES=$(get_compose_files)
        docker compose $COMPOSE_FILES --env-file .env down 
        ;;
    restart) 
        COMPOSE_FILES=$(get_compose_files)
        docker compose $COMPOSE_FILES --env-file .env down && \
        docker compose $COMPOSE_FILES --env-file .env up -d 
        ;;
    logs)
        COMPOSE_FILES=$(get_compose_files)
        docker compose $COMPOSE_FILES --env-file .env logs -f "${2:-backend}"
        ;;
    force-cleanup)
        log_info "Performing force cleanup..."
        docker compose down -v 2>/dev/null || true
        docker system prune -f 2>/dev/null || true
        docker rm -f $(docker ps -aq) 2>/dev/null || true && docker volume rm $(docker volume ls -q) 2>/dev/null || true
        cleanup
        log_info "Force cleanup completed"
        ;;		
    cleanup)
        cleanup
        log_info "Cleaned up temporary files"
        ;;
    rebuild-and-deploy)
        log_info "Rebuilding enhanced custom image and redeploying..."
        log_info "Performing force cleanup..."
        docker compose down -v 2>/dev/null || true
        docker system prune -f 2>/dev/null || true
        docker rm -f $(docker ps -aq) 2>/dev/null || true && docker volume rm $(docker volume ls -q) 2>/dev/null || true
        cleanup
        build_custom_image
        deploy
        ;;
    fix-routing)
        log_info "Fixing app routing issues..."
        COMPOSE_FILES=$(get_compose_files)
        source .env
        SITE_NAME=${FRAPPE_SITE_NAME_HEADER:-localhost}
        
        # 清除所有缓存
        log_info "Clearing caches..."
        docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" clear-cache
        docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" clear-website-cache
        
        # 重新生成路由
        log_info "Regenerating routes..."
        docker compose $COMPOSE_FILES exec -T backend bench --site "$SITE_NAME" migrate || log_warning "Migration failed"
        
        # 重启相关服务
        log_info "Restarting services..."
        docker compose $COMPOSE_FILES restart backend frontend websocket
        
        log_info "Routing fix completed. Please refresh your browser and try again."
        ;;
    fix-configurator)
        log_info "Attempting to fix configurator issues..."
        COMPOSE_FILES=$(get_compose_files)
        
        # Stop and remove problematic containers
        docker compose $COMPOSE_FILES down || true
        
        # Remove any problematic app from the image if needed
        log_info "Creating temporary fix container..."
        docker run --rm -v frappe_docker_sites:/home/frappe/frappe-bench/sites \
               ${CUSTOM_IMAGE}:${CUSTOM_TAG} bash -c "
                   if [ -d 'apps/insights' ] && ! python -c 'import insights' 2>/dev/null; then
                       echo 'Removing problematic insights app...'
                       rm -rf apps/insights
                       echo 'Insights app removed successfully'
                   fi
               " || true
               
        # Restart services
        docker compose $COMPOSE_FILES --env-file .env up -d
        log_info "Fix attempt completed"
        ;;		
    *) 
        echo "Usage: $0 {deploy|build-custom-image|status|start|stop|restart|logs|cleanup}"
        echo "  deploy              - Deploy the complete stack"
        echo "  build-custom-image  - Build custom ERPNext image with additional apps"
        echo "  status             - Show container status"  
        echo "  start              - Start all services"
        echo "  stop               - Stop all services"
        echo "  restart            - Restart all services"
        echo "  logs [service]     - Show logs (default: backend)"
        echo "  cleanup            - Clean up temporary files"
        echo "  force-cleanup      - Force cleanup including volumes and containers"
        echo "  rebuild-and-deploy - Rebuild enhanced custom image and redeploy"	
        echo "  fix-routing        - Fix app routing issues (missing /app/ prefix)"
        echo "  fix-configurator   - Fix configurator startup issues"		
        ;;
esac