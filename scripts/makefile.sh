#!/bin/bash

export SONAR_INSTANCE_NAME=${SONAR_INSTANCE_NAME:-"sonar-server"}
export SONAR_INSTANCE_PORT=${SONAR_INSTANCE_PORT:-"9234"}
export SONAR_PROJECT_NAME="${SONAR_PROJECT_NAME:-$(basename "$(pwd)")}"
export SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-$(basename "$(pwd)")}"
export SONAR_GITROOT=${SONAR_GITROOT:-"$(pwd)"}
export SONAR_SOURCE_PATH=${SONAR_SOURCE_PATH:-"."}
export SONAR_METRICS_PATH=${SONAR_METRICS_PATH:-"./sonar-metrics.json"}
export SONAR_EXTENSION_DIR="${HOME}/.sonarless/extensions"
export SONAR_PASSWORD_FILE="${HOME}/.sonarless/.password"

# Generate a random password for SonarQube admin user (includes special character for SonarQube requirements)
# Password is persisted to file to ensure consistency across GitHub Actions steps
function get_or_create_password() {
    if [[ -f "${SONAR_PASSWORD_FILE}" ]]; then
        cat "${SONAR_PASSWORD_FILE}"
    else
        mkdir -p "$(dirname "${SONAR_PASSWORD_FILE}")"
        local password
        password="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 15)@"
        echo "${password}" > "${SONAR_PASSWORD_FILE}"
        chmod 600 "${SONAR_PASSWORD_FILE}"
        echo "${password}"
    fi
}
export SONAR_ADMIN_PASSWORD=${SONAR_ADMIN_PASSWORD:-$(get_or_create_password)}

export DOCKER_SONAR_CLI=${DOCKER_SONAR_CLI:-"sonarsource/sonar-scanner-cli:11.3"}
export DOCKER_SONAR_SERVER=${DOCKER_SONAR_SERVER:-"sonarqube:25.5.0.107428-community"}

export CLI_NAME="sonarless"

function uri_wait(){
    set +e
    URL=$1
    SLEEP_INT=${2:-60}
    for _ in $(seq 1 "${SLEEP_INT}"); do
        sleep 1
        printf .
        HTTP_CODE=$(curl -k -s -o /dev/null -I -w "%{http_code}" -H 'User-Agent: Mozilla/6.0' "${URL}")
        [[ "${HTTP_CODE}" == "200" ]] && EXIT_CODE=0 || EXIT_CODE=-1
        [[ "${EXIT_CODE}" -eq 0 ]] && echo && return
    done
    echo
    set -e
    return "${EXIT_CODE}"
}

function help() {
    echo ''
    echo '                                               _ '
    echo '               ___   ___   _ __    __ _  _ __ | |  ___  ___  ___ '
    echo '              / __| / _ \ | "_ \  / _` || "__|| | / _ \/ __|/ __| '
    echo '              \__ \| (_) || | | || (_| || |   | ||  __/\__ \\__ \ '
    echo '              |___/ \___/ |_| |_| \__,_||_|   |_| \___||___/|___/ '
    echo ''
    echo ''
    echo "${CLI_NAME} help        : this help menu"
    echo ''
    echo "${CLI_NAME} scan        : to scan all code in current directory. Sonarqube Service will be started"
    echo "${CLI_NAME} dotnet-scan : to scan .NET code. Requires DOTNET_BUILD_COMMAND env var set."
    echo "${CLI_NAME} results     : show scan results and download the metric json (sonar-metrics.json) in current directory"
    echo ''
    echo "${CLI_NAME} start       : start SonarQube Service docker instance with creds: admin/sonarless"
    echo "${CLI_NAME} stop        : stop SonarQube Service docker instance"
    echo ''
    echo "${CLI_NAME} uninstall   : uninstall all scriptlets and docker instances"
    echo "${CLI_NAME} docker-clean: remove all docker instances. Note any scan history will be lost as docker instance are deleted"
    echo ''
}

function start() {
    docker-deps-get
    sonar-ext-get

    if ! docker inspect "${SONAR_INSTANCE_NAME}" > /dev/null 2>&1; then
        docker run -d --name "${SONAR_INSTANCE_NAME}" -p "${SONAR_INSTANCE_PORT}:9000" --network "${CLI_NAME}"  \
            -v "${SONAR_EXTENSION_DIR}:/opt/sonarqube/extensions/plugins" \
            -v "${SONAR_EXTENSION_DIR}:/usr/local/bin" \
            "${DOCKER_SONAR_SERVER}" > /dev/null 2>&1
    else
        docker start "${SONAR_INSTANCE_NAME}" > /dev/null 2>&1
    fi

    # 1. Wait for services to be up
    printf "Booting SonarQube docker instance "
    uri_wait "http://localhost:${SONAR_INSTANCE_PORT}" 60
    printf 'Waiting for SonarQube service availability '
    for _ in $(seq 1 180); do
        sleep 1
        printf .
        status_value=$(curl -s "http://localhost:${SONAR_INSTANCE_PORT}/api/system/status" | jq -r '.status')

        # Check if the status value is "running"
        if [[ "$status_value" == "UP" ]]; then
            echo
            break
        fi
    done

    status_value=$(curl -s "http://localhost:${SONAR_INSTANCE_PORT}/api/system/status" | jq -r '.status')
    # Check if the status value is "running"
    if [[ "$status_value" == "UP" ]]; then
        echo "SonarQube is running"
    else
        docker logs -f "${SONAR_INSTANCE_NAME}"
        echo "SonarQube is NOT running, exiting"
        exit 1
    fi

    # 2. Reset admin password to sonarless123
    curl -s -X POST -u "admin:admin" \
        -d "login=admin&previousPassword=admin&password=${SONAR_ADMIN_PASSWORD}" \
        "http://localhost:${SONAR_INSTANCE_PORT}/api/users/change_password"
    echo "Local sonarqube URI: http://localhost:${SONAR_INSTANCE_PORT}"

    echo "SonarQube admin password has been set"

}

function stop() {
    docker stop "${SONAR_INSTANCE_NAME}" > /dev/null 2>&1 && echo "Local SonarQube has been stopped"
}


function scan_setup() {
    start

    # 1. Create default project and set default fav
    curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "http://localhost:${SONAR_INSTANCE_PORT}/api/projects/create?name=${SONAR_PROJECT_NAME}&project=${SONAR_PROJECT_NAME}" | jq
    curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "http://localhost:${SONAR_INSTANCE_PORT}/api/users/set_homepage?type=PROJECT&component=${SONAR_PROJECT_NAME}"

    echo "SONAR_GITROOT: ${SONAR_GITROOT}"
    echo "SONAR_SOURCE_PATH: ${SONAR_SOURCE_PATH}"

    # 2. Create token and scan using internal-ip becos of docker to docker communication
    SONAR_TOKEN=$(curl -s -X POST -u "admin:${SONAR_ADMIN_PASSWORD}" "http://localhost:${SONAR_INSTANCE_PORT}/api/user_tokens/generate?name=$(date +%s%N)" | jq -r .token)
    export SONAR_TOKEN
}

function wait_for_quality_gate() {
    # Wait for scanning to be done
    if [[ "${SCAN_RET_CODE}" -eq "0" ]]; then
        printf '\nWaiting for analysis'
        for _ in $(seq 1 120); do
            sleep 1
            printf .
            status_value=$(curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" "http://localhost:${SONAR_INSTANCE_PORT}/api/qualitygates/project_status?projectKey=${SONAR_PROJECT_NAME}" | jq -r .projectStatus.status)
            # Checking if the status value is not "NONE"
            if [[ "$status_value" != "NONE" ]]; then
                echo
                echo "SonarQube scanning done"
                echo "Use webui http://localhost:${SONAR_INSTANCE_PORT} (admin/sonarless) or 'sonarless results' to get scan outputs"
                break
            fi
        done
    else
        printf '\nSonarQube scanning failed!'
        exit 1
    fi
}

function scan() {
    scan_setup

    docker run --rm --network "${CLI_NAME}" \
        -e SONAR_HOST_URL="http://${SONAR_INSTANCE_NAME}:9000"  \
        -e SONAR_TOKEN="${SONAR_TOKEN}" \
        -e SONAR_SCANNER_OPTS="-Dsonar.projectKey=${SONAR_PROJECT_NAME} -Dsonar.sources=${SONAR_SOURCE_PATH}" \
        -v "${SONAR_GITROOT}:/usr/src" \
        "${DOCKER_SONAR_CLI}";
    SCAN_RET_CODE="$?"

    wait_for_quality_gate
}

function dotnet-scan() {
    # Check if dotnet is installed
    if ! command -v dotnet &> /dev/null; then
        echo "Error: dotnet command not found. Please ensure .NET SDK is installed."
        exit 1
    fi

    # Install dotnet-sonarscanner if not present
    if ! dotnet tool list -g | grep -q "dotnet-sonarscanner"; then
        echo "Installing dotnet-sonarscanner..."
        dotnet tool install --global dotnet-sonarscanner
        export PATH="$PATH:$HOME/.dotnet/tools"
    else
        echo "dotnet-sonarscanner is already installed."
    fi

    scan_setup

    echo "Starting .NET SonarScanner begin step..."
    dotnet sonarscanner begin /k:"${SONAR_PROJECT_NAME}" \
        /d:sonar.host.url="http://localhost:${SONAR_INSTANCE_PORT}" \
        /d:sonar.token="${SONAR_TOKEN}" \
        /d:sonar.cs.opencover.reportsPaths="**/coverage.opencover.xml"

    echo "Running build command: ${DOTNET_BUILD_COMMAND}"
    # execute the build command
    eval "${DOTNET_BUILD_COMMAND}"
    BUILD_RET_CODE="$?"

    if [[ "${BUILD_RET_CODE}" -ne 0 ]]; then
        echo "Build failed! Aborting scan."
        exit 1
    fi

    echo "Starting .NET SonarScanner end step..."
    dotnet sonarscanner end /d:sonar.token="${SONAR_TOKEN}"
    SCAN_RET_CODE="$?"

    wait_for_quality_gate
}

function results() {
    # use this params to collect stats
    curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" "http://localhost:${SONAR_INSTANCE_PORT}/api/measures/component?component=${SONAR_PROJECT_NAME}&metricKeys=bugs,vulnerabilities,code_smells,quality_gate_details,violations,duplicated_lines_density,ncloc,coverage,reliability_rating,security_rating,security_review_rating,sqale_rating,security_hotspots,open_issues" \
        | jq -r > "${SONAR_GITROOT}/${SONAR_METRICS_PATH}"
    cat "${SONAR_GITROOT}/${SONAR_METRICS_PATH}"
    echo "Scan results written to  ${SONAR_GITROOT}/${SONAR_METRICS_PATH}"
}

function post-pr-comment() {
    # Check if we're in a PR context
    if [[ -z "${GITHUB_TOKEN}" ]]; then
        echo "GITHUB_TOKEN not set, skipping PR comment"
        return 0
    fi

    if [[ -z "${GITHUB_EVENT_NAME}" ]] || [[ "${GITHUB_EVENT_NAME}" != "pull_request" ]]; then
        echo "Not a pull request event, skipping PR comment"
        return 0
    fi

    if [[ -z "${PR_NUMBER}" ]]; then
        echo "PR_NUMBER not set, skipping PR comment"
        return 0
    fi

    if [[ -z "${GITHUB_REPOSITORY}" ]]; then
        echo "GITHUB_REPOSITORY not set, skipping PR comment"
        return 0
    fi

    echo "Fetching SonarQube issues for PR comment..."

    # Get the GitHub base URL for file links
    GITHUB_BASE_URL="https://github.com/${GITHUB_REPOSITORY}/blob/${GITHUB_SHA:-HEAD}"

    # Fetch all issues from SonarQube
    ISSUES_JSON=$(curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" \
        "http://localhost:${SONAR_INSTANCE_PORT}/api/issues/search?componentKeys=${SONAR_PROJECT_NAME}&resolved=false&ps=500")

    # Fetch metrics for summary
    METRICS_JSON=$(curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" \
        "http://localhost:${SONAR_INSTANCE_PORT}/api/measures/component?component=${SONAR_PROJECT_NAME}&metricKeys=bugs,vulnerabilities,code_smells,security_hotspots,coverage,duplicated_lines_density")

    # Extract counts
    BUGS=$(echo "${METRICS_JSON}" | jq -r '.component.measures[] | select(.metric=="bugs") | .value // "0"')
    VULNERABILITIES=$(echo "${METRICS_JSON}" | jq -r '.component.measures[] | select(.metric=="vulnerabilities") | .value // "0"')
    CODE_SMELLS=$(echo "${METRICS_JSON}" | jq -r '.component.measures[] | select(.metric=="code_smells") | .value // "0"')
    SECURITY_HOTSPOTS=$(echo "${METRICS_JSON}" | jq -r '.component.measures[] | select(.metric=="security_hotspots") | .value // "0"')
    COVERAGE=$(echo "${METRICS_JSON}" | jq -r '.component.measures[] | select(.metric=="coverage") | .value // "N/A"')
    DUPLICATION=$(echo "${METRICS_JSON}" | jq -r '.component.measures[] | select(.metric=="duplicated_lines_density") | .value // "N/A"')

    # Set defaults if empty
    BUGS=${BUGS:-0}
    VULNERABILITIES=${VULNERABILITIES:-0}
    CODE_SMELLS=${CODE_SMELLS:-0}
    SECURITY_HOTSPOTS=${SECURITY_HOTSPOTS:-0}
    COVERAGE=${COVERAGE:-N/A}
    DUPLICATION=${DUPLICATION:-N/A}

    # Get total issues count
    TOTAL_ISSUES=$(echo "${ISSUES_JSON}" | jq -r '.total // 0')

    # Fetch security hotspots
    HOTSPOTS_JSON=$(curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" \
        "http://localhost:${SONAR_INSTANCE_PORT}/api/hotspots/search?projectKey=${SONAR_PROJECT_NAME}&ps=100")
    HOTSPOTS_COUNT=$(echo "${HOTSPOTS_JSON}" | jq -r '.hotspots | length // 0')

    # Build the comment body with all metrics in a summary table
    COMMENT_BODY="## 🔍 SonarQube Analysis Results\n\n"
    COMMENT_BODY+="### 📊 Summary\n\n"
    COMMENT_BODY+="| Metric | Count |\n"
    COMMENT_BODY+="|--------|-------|\n"
    COMMENT_BODY+="| 🐛 Bugs | ${BUGS} |\n"
    COMMENT_BODY+="| 🔓 Vulnerabilities | ${VULNERABILITIES} |\n"
    COMMENT_BODY+="| 🔥 Security Hotspots | ${HOTSPOTS_COUNT} |\n"
    COMMENT_BODY+="| ⚠️ Code Smells | ${CODE_SMELLS} |\n"
    COMMENT_BODY+="| 📈 Coverage | ${COVERAGE}% |\n"
    COMMENT_BODY+="| 📋 Duplication | ${DUPLICATION}% |\n\n"

    # Build the detailed issues table if there are issues
    if [[ "${TOTAL_ISSUES}" -gt 0 ]] || [[ "${HOTSPOTS_COUNT}" -gt 0 ]]; then
        COMMENT_BODY+="### 📝 Issue Details\n\n"
        COMMENT_BODY+="| | Type | Severity | Message | Location |\n"
        COMMENT_BODY+="|--|------|----------|---------|----------|\n"

        # Add bugs to table
        BUGS_ROWS=$(echo "${ISSUES_JSON}" | jq -r --arg base_url "${GITHUB_BASE_URL}" '.issues[] | select(.type=="BUG") |
            ((.component | split(":")[1]) // .component) as $file |
            (.line // "N/A") as $line |
            if $line != "N/A" then
                "| 🐛 | Bug | \(.severity) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file):\($line)](\($base_url)/\($file)#L\($line)) |"
            else
                "| 🐛 | Bug | \(.severity) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file)](\($base_url)/\($file)) |"
            end' 2>/dev/null)
        if [[ -n "${BUGS_ROWS}" ]]; then
            COMMENT_BODY+="${BUGS_ROWS}\n"
        fi

        # Add vulnerabilities to table
        VULNS_ROWS=$(echo "${ISSUES_JSON}" | jq -r --arg base_url "${GITHUB_BASE_URL}" '.issues[] | select(.type=="VULNERABILITY") |
            ((.component | split(":")[1]) // .component) as $file |
            (.line // "N/A") as $line |
            if $line != "N/A" then
                "| 🔓 | Vulnerability | \(.severity) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file):\($line)](\($base_url)/\($file)#L\($line)) |"
            else
                "| 🔓 | Vulnerability | \(.severity) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file)](\($base_url)/\($file)) |"
            end' 2>/dev/null)
        if [[ -n "${VULNS_ROWS}" ]]; then
            COMMENT_BODY+="${VULNS_ROWS}\n"
        fi

        # Add security hotspots to table
        HOTSPOTS_ROWS=$(echo "${HOTSPOTS_JSON}" | jq -r --arg base_url "${GITHUB_BASE_URL}" '.hotspots[]? |
            ((.component | split(":")[1]) // .component) as $file |
            (.line // "N/A") as $line |
            if $line != "N/A" then
                "| 🔥 | Hotspot | \(.vulnerabilityProbability) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file):\($line)](\($base_url)/\($file)#L\($line)) |"
            else
                "| 🔥 | Hotspot | \(.vulnerabilityProbability) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file)](\($base_url)/\($file)) |"
            end' 2>/dev/null)
        if [[ -n "${HOTSPOTS_ROWS}" ]]; then
            COMMENT_BODY+="${HOTSPOTS_ROWS}\n"
        fi

        # Add code smells to table (limit to 20)
        SMELLS_ROWS=$(echo "${ISSUES_JSON}" | jq -r --arg base_url "${GITHUB_BASE_URL}" '.issues[] | select(.type=="CODE_SMELL") |
            ((.component | split(":")[1]) // .component) as $file |
            (.line // "N/A") as $line |
            if $line != "N/A" then
                "| ⚠️ | Code Smell | \(.severity) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file):\($line)](\($base_url)/\($file)#L\($line)) |"
            else
                "| ⚠️ | Code Smell | \(.severity) | \(.message | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) | [\($file)](\($base_url)/\($file)) |"
            end' 2>/dev/null | head -20)
        if [[ -n "${SMELLS_ROWS}" ]]; then
            COMMENT_BODY+="${SMELLS_ROWS}\n"
            SMELLS_COUNT=$(echo "${ISSUES_JSON}" | jq -r '[.issues[] | select(.type=="CODE_SMELL")] | length')
            if [[ "${SMELLS_COUNT}" -gt 20 ]]; then
                COMMENT_BODY+="\n*Showing 20 of ${SMELLS_COUNT} code smells*\n"
            fi
        fi

        COMMENT_BODY+="\n"
    else
        COMMENT_BODY+="### ✅ No issues found!\n\n"
    fi

    COMMENT_BODY+="---\n*Generated by SonarLess*"

    # Find and minimize previous SonarQube comments
    echo "Looking for previous SonarQube comments to minimize..."
    EXISTING_COMMENTS=$(curl -s \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments")

    # Find comments that contain our signature and minimize them
    SONAR_COMMENT_IDS=$(echo "${EXISTING_COMMENTS}" | jq -r '.[] | select(.body | contains("Generated by SonarLess")) | .node_id')

    for NODE_ID in ${SONAR_COMMENT_IDS}; do
        echo "Minimizing previous comment: ${NODE_ID}"
        # Use GraphQL API to minimize the comment
        curl -s -X POST \
            -H "Authorization: bearer ${GITHUB_TOKEN}" \
            -H "Content-Type: application/json" \
            "https://api.github.com/graphql" \
            -d "{\"query\": \"mutation { minimizeComment(input: {subjectId: \\\"${NODE_ID}\\\", classifier: OUTDATED}) { minimizedComment { isMinimized } } }\"}" > /dev/null 2>&1
    done

    # Escape the comment body for JSON
    ESCAPED_BODY=$(echo -e "${COMMENT_BODY}" | jq -Rs .)

    # Post comment to PR
    echo "Posting comment to PR #${PR_NUMBER}..."
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
        -d "{\"body\": ${ESCAPED_BODY}}")

    # Check if comment was posted successfully
    COMMENT_ID=$(echo "${RESPONSE}" | jq -r '.id // empty')
    if [[ -n "${COMMENT_ID}" ]]; then
        echo "Successfully posted PR comment (ID: ${COMMENT_ID})"
    else
        echo "Failed to post PR comment"
        echo "Response: ${RESPONSE}"
        return 1
    fi
}

function docker-deps-get() {
	( docker image inspect "${DOCKER_SONAR_SERVER}" > /dev/null 2>&1 || echo "Downloading SonarQube..."; docker pull "${DOCKER_SONAR_SERVER}" > /dev/null 2>&1 ) &
    ( docker image inspect "${DOCKER_SONAR_CLI}" > /dev/null 2>&1 || echo "Downloading Sonar CLI..."; docker pull "${DOCKER_SONAR_CLI}" > /dev/null 2>&1 ) &
    wait
    docker network inspect "${CLI_NAME}" > /dev/null 2>&1 || docker network create "${CLI_NAME}" > /dev/null 2>&1
}

function sonar-ext-get() {

    [ ! -d "${SONAR_EXTENSION_DIR}" ] && echo "Downloading SonarQube Extensions..."; mkdir -p "${SONAR_EXTENSION_DIR}"

    if [ ! -f "${SONAR_EXTENSION_DIR}/shellcheck" ]; then
        # src: https://github.com/koalaman/shellcheck/blob/master/Dockerfile.multi-arch
        arch="$(uname -m)"
        os="$(uname | sed 's/.*/\L&/')"
        tag="v0.10.0"

        if [ "${arch}" = 'armv7l' ]; then
            arch='armv6hf'
        fi

        if [ "${arch}" = 'arm64' ]; then
            arch='aarch64'
        fi

        url_base='https://github.com/koalaman/shellcheck/releases/download/'
        tar_file="${tag}/shellcheck-${tag}.${os}.${arch}.tar.xz"
        curl -s --fail --location --progress-bar "${url_base}${tar_file}" | tar xJf -

        mv "shellcheck-${tag}/shellcheck" "${SONAR_EXTENSION_DIR}/"
        rm -rf "shellcheck-${tag}"
    fi

    SONAR_SHELLCHECK="sonar-shellcheck-plugin-2.5.0.jar"
    SONAR_SHELLCHECK_URL="https://github.com/sbaudoin/sonar-shellcheck/releases/download/v2.5.0/${SONAR_SHELLCHECK}"
    if [ ! -f "${SONAR_EXTENSION_DIR}/${SONAR_SHELLCHECK}" ]; then
        curl -s --fail --location --progress-bar "${SONAR_SHELLCHECK_URL}" > "${SONAR_EXTENSION_DIR}/${SONAR_SHELLCHECK}"
    fi

}

function docker-clean() {
    docker rm -f "${SONAR_INSTANCE_NAME}"
    docker image rm -f "${DOCKER_SONAR_CLI}" "${DOCKER_SONAR_SERVER}"
    docker volume prune -f
    docker network rm -f "${CLI_NAME}"
}

function uninstall() {
    docker-clean
    rm -rf "${HOME}/.${CLI_NAME}"
}

$*
