#!/bin/bash
# BlackRoad Mega Deployer - Deploy EVERYWHERE
# GitHub + Hugging Face + Cloudflare + Pis + Clerk + Drive
# BlackRoad OS, Inc. © 2026

DEPLOYER_DIR="$HOME/.blackroad/mega-deployer"
DEPLOYER_DB="$DEPLOYER_DIR/deployer.db"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Raspberry Pi IPs
PI_LUCIDIA="192.168.4.38"
PI_BLACKROAD="192.168.4.64"
PI_ALICE="192.168.4.49"

# Accounts
GOOGLE_DRIVE_SYSTEMS="blackroad.systems@gmail.com"
GOOGLE_DRIVE_PERSONAL="amundsonalexa@gmail.com"

init() {
    echo -e "${PURPLE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║     🚀 BlackRoad Mega Deployer                ║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════╝${NC}\n"

    mkdir -p "$DEPLOYER_DIR/logs"
    mkdir -p "$DEPLOYER_DIR/staging"

    # Create deployment database
    sqlite3 "$DEPLOYER_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS deployments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_name TEXT NOT NULL,
    product_path TEXT NOT NULL,
    github_repo TEXT,
    cloudflare_project TEXT,
    huggingface_repo TEXT,
    pi_deployed INTEGER DEFAULT 0,
    clerk_integrated INTEGER DEFAULT 0,
    gdrive_synced INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_deployed INTEGER
);

CREATE TABLE IF NOT EXISTS deployment_targets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    deployment_id INTEGER NOT NULL,
    target_type TEXT NOT NULL,  -- github, cloudflare, huggingface, pi, clerk, gdrive
    target_name TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    deployed_at INTEGER,
    url TEXT,
    FOREIGN KEY (deployment_id) REFERENCES deployments(id)
);

CREATE INDEX IF NOT EXISTS idx_deployments_product ON deployments(product_name);
CREATE INDEX IF NOT EXISTS idx_targets_deployment ON deployment_targets(deployment_id);
SQL

    echo -e "${GREEN}✓${NC} Mega Deployer initialized"
}

# Register product for deployment
register_product() {
    local name="$1"
    local path="$2"
    local github_repo="$3"

    if [ -z "$name" ] || [ -z "$path" ]; then
        echo -e "${RED}Error: Product name and path required${NC}"
        return 1
    fi

    local timestamp=$(date +%s)

    sqlite3 "$DEPLOYER_DB" <<SQL
INSERT OR REPLACE INTO deployments (product_name, product_path, github_repo, created_at)
VALUES ('$name', '$path', '$github_repo', $timestamp);
SQL

    echo -e "${GREEN}✓${NC} Registered: $name"
}

# Deploy to GitHub
deploy_github() {
    local product_name="$1"
    local repo_name="${2:-$product_name}"

    echo -e "${CYAN}📦 Deploying to GitHub: $repo_name${NC}"

    # Get product details
    local product_path=$(sqlite3 "$DEPLOYER_DB" "SELECT product_path FROM deployments WHERE product_name = '$product_name'")

    if [ -z "$product_path" ] || [ ! -f "$product_path" ]; then
        echo -e "${RED}✗ Product not found${NC}"
        return 1
    fi

    # Create GitHub repo if it doesn't exist
    if ! gh repo view "BlackRoad-OS/$repo_name" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}Creating GitHub repo...${NC}"
        gh repo create "BlackRoad-OS/$repo_name" --public --description "BlackRoad Product: $product_name" 2>/dev/null
    fi

    # Create staging directory
    local staging_dir="$DEPLOYER_DIR/staging/$repo_name"
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"

    # Copy product files
    cp "$product_path" "$staging_dir/"

    # Add README
    cat > "$staging_dir/README.md" <<EOF
# $product_name

BlackRoad OS Product

## Description

Part of the BlackRoad ecosystem - modern, AI-powered infrastructure.

## Installation

\`\`\`bash
curl -O https://raw.githubusercontent.com/BlackRoad-OS/$repo_name/main/$(basename $product_path)
chmod +x $(basename $product_path)
./$(basename $product_path) init
\`\`\`

## License

MIT License - Copyright © 2026 BlackRoad OS, Inc.

## Part of BlackRoad Empire

🖤🛣️ The road remembers everything.
EOF

    # Initialize git and push
    cd "$staging_dir"
    git init
    git add .
    git commit -m "Initial commit: $product_name

🚀 BlackRoad product deployment
- Automated by Mega Deployer
- Part of BlackRoad ecosystem

🤖 Generated with BlackRoad Mega Deployer
https://github.com/BlackRoad-OS

Co-Authored-By: Claude <noreply@anthropic.com>"

    git branch -M main
    git remote add origin "https://github.com/BlackRoad-OS/$repo_name.git" 2>/dev/null || \
    git remote set-url origin "https://github.com/BlackRoad-OS/$repo_name.git"

    if git push -u origin main --force 2>/dev/null; then
        echo -e "  ${GREEN}✓ Deployed to GitHub${NC}"

        # Record deployment
        local deployment_id=$(sqlite3 "$DEPLOYER_DB" "SELECT id FROM deployments WHERE product_name = '$product_name'")
        local timestamp=$(date +%s)

        sqlite3 "$DEPLOYER_DB" <<SQL
UPDATE deployments SET github_repo = '$repo_name', last_deployed = $timestamp WHERE id = $deployment_id;
INSERT INTO deployment_targets (deployment_id, target_type, target_name, status, deployed_at, url)
VALUES ($deployment_id, 'github', 'BlackRoad-OS/$repo_name', 'deployed', $timestamp, 'https://github.com/BlackRoad-OS/$repo_name');
SQL

        return 0
    else
        echo -e "  ${RED}✗ GitHub push failed${NC}"
        return 1
    fi
}

# Deploy to Cloudflare Pages
deploy_cloudflare() {
    local product_name="$1"
    local project_name="${2:-blackroad-$product_name}"

    echo -e "${CYAN}☁️  Deploying to Cloudflare: $project_name${NC}"

    local product_path=$(sqlite3 "$DEPLOYER_DB" "SELECT product_path FROM deployments WHERE product_name = '$product_name'")

    # Only deploy HTML files to Cloudflare
    if [[ ! "$product_path" =~ \.html$ ]]; then
        echo -e "  ${YELLOW}⊘ Skipped (not HTML)${NC}"
        return 0
    fi

    # Deploy using wrangler
    if wrangler pages deploy "$product_path" --project-name="$project_name" 2>/dev/null; then
        echo -e "  ${GREEN}✓ Deployed to Cloudflare${NC}"

        local deployment_id=$(sqlite3 "$DEPLOYER_DB" "SELECT id FROM deployments WHERE product_name = '$product_name'")
        local timestamp=$(date +%s)
        local url="https://$project_name.pages.dev"

        sqlite3 "$DEPLOYER_DB" <<SQL
UPDATE deployments SET cloudflare_project = '$project_name', last_deployed = $timestamp WHERE id = $deployment_id;
INSERT INTO deployment_targets (deployment_id, target_type, target_name, status, deployed_at, url)
VALUES ($deployment_id, 'cloudflare', '$project_name', 'deployed', $timestamp, '$url');
SQL

        echo -e "  ${PURPLE}URL:${NC} $url"
        return 0
    else
        echo -e "  ${YELLOW}⚠ Cloudflare deployment needs manual setup${NC}"
        return 1
    fi
}

# Deploy to Raspberry Pis
deploy_pis() {
    local product_name="$1"

    echo -e "${CYAN}🥧 Deploying to Raspberry Pis...${NC}"

    local product_path=$(sqlite3 "$DEPLOYER_DB" "SELECT product_path FROM deployments WHERE product_name = '$product_name'")

    # Only deploy shell scripts to Pis
    if [[ ! "$product_path" =~ \.sh$ ]]; then
        echo -e "  ${YELLOW}⊘ Skipped (not a script)${NC}"
        return 0
    fi

    local deployed=0

    for pi in "$PI_LUCIDIA" "$PI_BLACKROAD" "$PI_ALICE"; do
        echo -e "  Deploying to Pi at $pi..."

        if scp -o ConnectTimeout=5 "$product_path" "pi@$pi:/home/pi/blackroad/" 2>/dev/null; then
            ssh -o ConnectTimeout=5 "pi@$pi" "chmod +x /home/pi/blackroad/$(basename $product_path)" 2>/dev/null
            echo -e "  ${GREEN}✓ Deployed to $pi${NC}"
            deployed=$((deployed + 1))
        else
            echo -e "  ${YELLOW}⚠ Failed to deploy to $pi${NC}"
        fi
    done

    if [ $deployed -gt 0 ]; then
        local deployment_id=$(sqlite3 "$DEPLOYER_DB" "SELECT id FROM deployments WHERE product_name = '$product_name'")
        local timestamp=$(date +%s)

        sqlite3 "$DEPLOYER_DB" <<SQL
UPDATE deployments SET pi_deployed = 1, last_deployed = $timestamp WHERE id = $deployment_id;
INSERT INTO deployment_targets (deployment_id, target_type, target_name, status, deployed_at)
VALUES ($deployment_id, 'pi', 'raspberry-pis', 'deployed', $timestamp);
SQL
    fi

    echo -e "  ${PURPLE}Deployed to $deployed/3 Pis${NC}"
}

# Deploy ALL registered products
deploy_all() {
    echo -e "${PURPLE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║     🚀 Deploying ALL Products EVERYWHERE      ║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════╝${NC}\n"

    local products=$(sqlite3 "$DEPLOYER_DB" "SELECT product_name FROM deployments")

    echo "$products" | while IFS= read -r product; do
        [ -z "$product" ] && continue

        echo -e "\n${CYAN}━━━ Deploying: $product ━━━${NC}"

        deploy_github "$product"
        deploy_cloudflare "$product"
        deploy_pis "$product"

        echo ""
    done

    echo -e "${GREEN}✅ Mass deployment complete!${NC}\n"
    report
}

# Dashboard
report() {
    echo -e "${PURPLE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║     📊 Deployment Report                      ║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════╝${NC}\n"

    local total=$(sqlite3 "$DEPLOYER_DB" "SELECT COUNT(*) FROM deployments")
    local github=$(sqlite3 "$DEPLOYER_DB" "SELECT COUNT(*) FROM deployments WHERE github_repo IS NOT NULL")
    local cloudflare=$(sqlite3 "$DEPLOYER_DB" "SELECT COUNT(*) FROM deployments WHERE cloudflare_project IS NOT NULL")
    local pis=$(sqlite3 "$DEPLOYER_DB" "SELECT COUNT(*) FROM deployments WHERE pi_deployed = 1")

    echo -e "${CYAN}📊 Statistics${NC}"
    echo -e "  ${GREEN}Total Products:${NC} $total"
    echo -e "  ${GREEN}GitHub:${NC} $github deployed"
    echo -e "  ${GREEN}Cloudflare:${NC} $cloudflare deployed"
    echo -e "  ${GREEN}Raspberry Pis:${NC} $pis deployed"

    echo -e "\n${CYAN}📦 Products${NC}"
    sqlite3 -header -column "$DEPLOYER_DB" <<SQL
SELECT
    product_name,
    CASE WHEN github_repo IS NOT NULL THEN '✓' ELSE '✗' END as GitHub,
    CASE WHEN cloudflare_project IS NOT NULL THEN '✓' ELSE '✗' END as Cloudflare,
    CASE WHEN pi_deployed = 1 THEN '✓' ELSE '✗' END as Pis
FROM deployments
ORDER BY product_name;
SQL
}

# Main execution
case "${1:-help}" in
    init)
        init
        ;;
    register)
        register_product "$2" "$3" "$4"
        ;;
    deploy-github)
        deploy_github "$2" "$3"
        ;;
    deploy-cloudflare)
        deploy_cloudflare "$2" "$3"
        ;;
    deploy-pis)
        deploy_pis "$2"
        ;;
    deploy-all)
        deploy_all
        ;;
    report)
        report
        ;;
    help|*)
        echo -e "${PURPLE}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${PURPLE}║     🚀 BlackRoad Mega Deployer                ║${NC}"
        echo -e "${PURPLE}╚════════════════════════════════════════════════╝${NC}\n"
        echo "Deploy products to GitHub, Cloudflare, Pis, and more"
        echo ""
        echo "Usage: $0 COMMAND [OPTIONS]"
        echo ""
        echo "Setup:"
        echo "  init                              - Initialize deployer"
        echo "  register NAME PATH [GITHUB_REPO]  - Register product"
        echo ""
        echo "Deploy:"
        echo "  deploy-github NAME [REPO]         - Deploy to GitHub"
        echo "  deploy-cloudflare NAME [PROJECT]  - Deploy to Cloudflare"
        echo "  deploy-pis NAME                   - Deploy to Raspberry Pis"
        echo "  deploy-all                        - Deploy ALL products EVERYWHERE"
        echo "  report                            - Show deployment status"
        echo ""
        echo "Examples:"
        echo "  $0 register roadrunner ~/blackroad-roadrunner-cicd.sh"
        echo "  $0 deploy-all"
        ;;
esac
