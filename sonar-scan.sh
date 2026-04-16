#!/usr/bin/env bash
set -euo pipefail

# sonar-scan.sh - Ephemeral SonarQube scan CLI (Docker or local ZIP)

VERSION="2.0.0"
SONAR_HOME="${HOME}/.sonar-scan"
SQ_VERSION="26.4.0.121862"
SCANNER_VERSION="8.0.1.6346"
SQ_ZIP_URL="https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SQ_VERSION}.zip"
SCANNER_BASE_URL="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli"

SONAR_PORT=9000
PROJECT_KEY=""
REPORT_PATH=""
SOURCE_DIR=""
OUTPUT_MODE="json"
SEVERITY_THRESHOLD=""
EXCLUSIONS=""
SOURCES=""
RUN_MODE=""  # docker | local | auto

usage() {
  cat <<'EOF'
Usage: sonar-scan.sh [OPTIONS] <source-dir>

Ephemeral SonarQube scan: starts a temporary SonarQube instance, scans the
target directory, outputs structured JSON to stdout, and stops the instance.
No persistent daemon is required.

Run mode (auto-detected by default):
  Docker available       → uses Docker containers (no Java needed)
  Docker unavailable     → downloads ZIP packages to ~/.sonar-scan/ (needs Java 17+)
  Override with -m docker|local

Prerequisites:
  Docker mode:  Docker CLI in PATH
  Local mode:   Java 17 or 21, curl, unzip
  Both modes:   python3 (for JSON formatting)

Supported languages (SonarQube Community Edition):
  Java, JavaScript, TypeScript, Python, C#, Go, Kotlin, Ruby, Scala,
  PHP, HTML, CSS, XML, Flex

Options:
  -m <mode>       Run mode: docker, local, auto (default: auto)
  -k <key>        Project key (default: directory name)
  -s <paths>      Source directories relative to project root (comma-separated)
                  e.g. -s src/main,lib  (overrides sonar-project.properties)
  -e <patterns>   Exclusion glob patterns (comma-separated)
                  e.g. -e "**/test/**,**/vendor/**"  (overrides properties)
  -o <path>       Save report JSON to file
  -p <port>       SonarQube port (default: 9000)
  -f <format>     Output format: json (default), human, silent
  -t <severity>   Fail (exit 2) if issues at or above severity exist
                  Values: BLOCKER, CRITICAL, MAJOR, MINOR, INFO
  -v              Show version
  -h              Show this help

Project configuration:
  If <source-dir>/sonar-project.properties exists, it is automatically used.
  CLI options (-k, -s, -e) override values from the properties file.
  When no properties file is found, the entire directory is scanned.

  Example sonar-project.properties:
    sonar.projectKey=my-app
    sonar.sources=src
    sonar.exclusions=**/test/**,**/docs/**
    sonar.sourceEncoding=UTF-8

Local mode storage (~/.sonar-scan/):
  On first local-mode run, SonarQube (~920MB) and sonar-scanner-cli (~60MB)
  are downloaded once and shared across all projects.

Exit codes:
  0  Scan completed successfully (no threshold violation if -t used)
  1  Runtime error (Docker/Java not found, timeout, etc.)
  2  Issues found at or above severity threshold (-t)

Stdout JSON schema (default -f json):
  Success:
    {
      "status": "success",
      "project_key": "string",
      "run_mode": "docker|local",
      "elapsed_seconds": 45,
      "total_issues": 3,
      "severity_counts": {"BLOCKER": 1, "CRITICAL": 1, "MAJOR": 1},
      "issues": [
        {
          "rule": "python:S1481",
          "severity": "MINOR|MAJOR|CRITICAL|BLOCKER|INFO",
          "component": "path/to/file.py",
          "line": 42,
          "message": "Remove the unused local variable \"x\"."
        }
      ]
    }
  Error:
    {
      "status": "error",
      "error_code": "timeout|missing_prerequisite|invalid_args|runtime_error|analysis_failed",
      "error": "description of what went wrong"
    }

Performance:
  - First run (download): ~5-10 min (Docker pull or ZIP download)
  - Subsequent runs: ~40-90 sec (startup + scan)
  - Progress logs are written to stderr (suppressed in json mode)

Examples:
  # Basic scan (auto-detects Docker or local)
  sonar-scan.sh ./src

  # Force local ZIP mode
  sonar-scan.sh -m local ./src

  # Scan specific subdirectories, exclude test files
  sonar-scan.sh -s src/main,lib -e "**/test/**" ./my-project

  # Fail CI if CRITICAL or BLOCKER issues exist
  sonar-scan.sh -t CRITICAL -f silent ./src && echo "PASS" || echo "FAIL"

  # Save report and print human-readable summary
  sonar-scan.sh -k my-app -f human -o report.json ./src
EOF
  exit 0
}

log() { [[ "$OUTPUT_MODE" != "json" ]] && echo "$*" >&2 || true; }

error_json() {
  local msg="$1" code="${2:-runtime_error}"
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    printf '{"status":"error","error_code":"%s","error":"%s"}\n' "$code" "$msg"
  else
    echo "ERROR: $msg" >&2
  fi
  exit 1
}

# --- Detect OS/arch for scanner-cli download ---
detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64)  echo "linux-x64" ;;
        aarch64) echo "linux-aarch64" ;;
        *)       echo "linux-x64" ;;
      esac ;;
    Darwin)
      case "$arch" in
        arm64)   echo "macosx-aarch64" ;;
        *)       echo "macosx-x64" ;;
      esac ;;
    *) error_json "unsupported OS: $os" ;;
  esac
}

# --- Download and extract if not present ---
ensure_local_install() {
  mkdir -p "$SONAR_HOME"

  # SonarQube
  local sq_dir="$SONAR_HOME/sonarqube-${SQ_VERSION}"
  if [[ ! -d "$sq_dir" ]]; then
    log "==> Downloading SonarQube Community Build ${SQ_VERSION}..."
    curl -fSL "$SQ_ZIP_URL" -o "$SONAR_HOME/sonarqube.zip" || error_json "failed to download SonarQube"
    log "==> Extracting..."
    unzip -qo "$SONAR_HOME/sonarqube.zip" -d "$SONAR_HOME" || error_json "failed to extract SonarQube"
    rm -f "$SONAR_HOME/sonarqube.zip"
    # Remove bundled JREs (~280MB) - system Java is used instead
    rm -rf "$sq_dir/jres"
  fi

  # sonar-scanner-cli (JRE-embedded, platform-specific)
  local platform scanner_zip_name
  platform="$(detect_platform)"
  local scanner_extracted="$SONAR_HOME/sonar-scanner-${SCANNER_VERSION}-${platform}"
  if [[ ! -d "$scanner_extracted" ]]; then
    scanner_zip_name="sonar-scanner-cli-${SCANNER_VERSION}-${platform}.zip"
    log "==> Downloading sonar-scanner-cli ${SCANNER_VERSION} (${platform})..."
    curl -fSL "${SCANNER_BASE_URL}/${scanner_zip_name}" -o "$SONAR_HOME/scanner.zip" || error_json "failed to download sonar-scanner-cli"
    log "==> Extracting..."
    unzip -qo "$SONAR_HOME/scanner.zip" -d "$SONAR_HOME" || error_json "failed to extract sonar-scanner-cli"
    rm -f "$SONAR_HOME/scanner.zip"
  fi
}

# Create an isolated instance work directory for parallel execution
INSTANCE_DIR=""
setup_instance_dir() {
  INSTANCE_DIR="$SONAR_HOME/instances/$$"
  rm -rf "$INSTANCE_DIR"
  mkdir -p "$INSTANCE_DIR/data" "$INSTANCE_DIR/temp" "$INSTANCE_DIR/logs"
}

# ============================================================
# Docker mode
# ============================================================
CONTAINER_NAME="sonarqube-tmp-$$"
DOCKER_NETWORK="sonar-net-$$"

cleanup_docker() {
  log "==> Removing Docker resources..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
}

run_docker() {
  trap cleanup_docker EXIT

  # Create isolated network (works on macOS/Linux/Windows)
  docker network create "$DOCKER_NETWORK" >/dev/null 2>&1 || error_json "failed to create Docker network"

  log "==> [docker] Starting SonarQube (port: $SONAR_PORT)..."
  docker run -d --name "$CONTAINER_NAME" \
    --network "$DOCKER_NETWORK" \
    -p "$SONAR_PORT:9000" \
    -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
    sonarqube:community >/dev/null 2>&1 || error_json "failed to start SonarQube container"

  wait_for_sonarqube

  local token
  token="$(generate_token)"

  log "==> [docker] Scanning..."
  local -a scanner_args=(
    -Dsonar.projectKey="$PROJECT_KEY"
    -Dsonar.host.url="http://${CONTAINER_NAME}:9000"
    -Dsonar.token="$token"
  )
  if [[ -f "$SOURCE_DIR/sonar-project.properties" ]]; then
    log "==> Using sonar-project.properties"
    scanner_args+=(-Dproject.settings=/usr/src/sonar-project.properties)
  else
    scanner_args+=(-Dsonar.sources=/usr/src)
  fi
  [[ -n "$SOURCES" ]] && scanner_args+=(-Dsonar.sources="$SOURCES")
  [[ -n "$EXCLUSIONS" ]] && scanner_args+=(-Dsonar.exclusions="$EXCLUSIONS")

  docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$SOURCE_DIR:/usr/src" \
    -w /usr/src \
    sonarsource/sonar-scanner-cli \
    "${scanner_args[@]}" >/dev/null 2>&1 || error_json "sonar-scanner failed"

  wait_for_analysis "$token"
  fetch_and_output "$token"
}

# ============================================================
# Local ZIP mode
# ============================================================
SQ_PID=""

cleanup_local() {
  log "==> Stopping local SonarQube..."
  # Kill processes belonging to this instance only (matched by instance dir path)
  local pids
  pids=$(pgrep -f "$INSTANCE_DIR" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill 2>/dev/null || true
    sleep 2
    # Force kill if still alive
    pids=$(pgrep -f "$INSTANCE_DIR" 2>/dev/null || true)
    [[ -n "$pids" ]] && echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
  # Remove instance work directory
  rm -rf "$INSTANCE_DIR"
}

run_local() {
  ensure_local_install
  setup_instance_dir
  trap cleanup_local EXIT

  local sq_dir="$SONAR_HOME/sonarqube-${SQ_VERSION}"

  # Auto-assign port if default is busy or for parallel safety
  if [[ "$SONAR_PORT" -eq 9000 ]]; then
    SONAR_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
    log "==> Auto-assigned port: $SONAR_PORT"
  fi

  # Allocate dynamic ports for ES and H2 to avoid conflicts
  local es_port h2_port
  es_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  h2_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")

  log "==> [local] Starting SonarQube (port: $SONAR_PORT, instance: $$)..."
  # Launch from SonarQube home; override runtime paths via system properties
  (cd "$sq_dir" && exec java -Xms8m -Xmx32m \
    --add-exports=java.base/jdk.internal.ref=ALL-UNNAMED \
    --add-opens=java.base/java.lang=ALL-UNNAMED \
    --add-opens=java.base/java.nio=ALL-UNNAMED \
    --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
    --add-opens=java.management/sun.management=ALL-UNNAMED \
    --add-opens=jdk.management/com.sun.management.internal=ALL-UNNAMED \
    -Dsonar.web.port="$SONAR_PORT" \
    -Dsonar.path.data="$INSTANCE_DIR/data" \
    -Dsonar.path.temp="$INSTANCE_DIR/temp" \
    -Dsonar.path.logs="$INSTANCE_DIR/logs" \
    -Dsonar.search.port="$es_port" \
    -Dsonar.embeddedDatabase.port="$h2_port" \
    -jar lib/sonar-application-${SQ_VERSION}.jar \
  ) >/dev/null 2>&1 &
  SQ_PID=$!

  wait_for_sonarqube

  local token
  token="$(generate_token)"

  local platform scanner_bin
  platform="$(detect_platform)"
  scanner_bin="$SONAR_HOME/sonar-scanner-${SCANNER_VERSION}-${platform}/bin/sonar-scanner"
  chmod +x "$scanner_bin"

  log "==> [local] Scanning..."
  local -a scanner_args=(
    -Dsonar.projectKey="$PROJECT_KEY"
    -Dsonar.host.url="http://localhost:$SONAR_PORT"
    -Dsonar.token="$token"
    -Dsonar.projectBaseDir="$SOURCE_DIR"
    -Dsonar.working.directory="$INSTANCE_DIR/scannerwork"
  )
  if [[ -f "$SOURCE_DIR/sonar-project.properties" ]]; then
    log "==> Using sonar-project.properties"
  else
    scanner_args+=(-Dsonar.sources="$SOURCE_DIR")
  fi
  [[ -n "$SOURCES" ]] && scanner_args+=(-Dsonar.sources="$SOURCES")
  [[ -n "$EXCLUSIONS" ]] && scanner_args+=(-Dsonar.exclusions="$EXCLUSIONS")

  "$scanner_bin" "${scanner_args[@]}" >/dev/null 2>&1 || error_json "sonar-scanner failed"

  wait_for_analysis "$token"
  fetch_and_output "$token"
}

# ============================================================
# Shared functions
# ============================================================
wait_for_sonarqube() {
  local timeout=180 elapsed=0
  while ! curl -sf "http://localhost:$SONAR_PORT/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
    [[ "$elapsed" -ge "$timeout" ]] && error_json "SonarQube startup timed out (${timeout}s)" "timeout"
    [[ "$OUTPUT_MODE" != "json" ]] && printf "." >&2 || true
    sleep 3
    elapsed=$((elapsed + 3))
  done
  log " Ready (${elapsed}s)"
}

generate_token() {
  local token
  token=$(curl -sf -u admin:admin \
    -X POST "http://localhost:$SONAR_PORT/api/user_tokens/generate" \
    -d "name=scan-token-$$" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
  [[ -z "$token" ]] && error_json "failed to generate API token"
  echo "$token"
}

wait_for_analysis() {
  local token="$1" status=""
  log "==> Waiting for analysis..."
  for _ in $(seq 1 30); do
    status=$(curl -sf -u "$token:" \
      "http://localhost:$SONAR_PORT/api/ce/component?component=$PROJECT_KEY" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('current',{}).get('status',''))" 2>/dev/null || echo "")
    [[ "$status" == "SUCCESS" ]] && return 0
    [[ "$status" == "FAILED" ]] && error_json "SonarQube analysis task failed" "analysis_failed"
    sleep 2
  done
  error_json "analysis task did not complete" "timeout"
}

fetch_and_output() {
  local token="$1"
  local raw result

  raw=$(curl -sf -u "$token:" \
    "http://localhost:$SONAR_PORT/api/issues/search?projectKeys=$PROJECT_KEY&ps=500") \
    || error_json "failed to fetch issues"

  local elapsed_sec=$(( $(date +%s) - SCAN_START ))

  result=$(echo "$raw" | python3 -c "
import json, sys
raw = json.load(sys.stdin)
issues = [
    {
        'rule': i['rule'],
        'severity': i['severity'],
        'component': i['component'].split(':',1)[-1],
        'line': i.get('line', 0),
        'message': i['message']
    }
    for i in raw.get('issues', [])
]
severity_counts = {}
for i in issues:
    s = i['severity']
    severity_counts[s] = severity_counts.get(s, 0) + 1
print(json.dumps({
    'status': 'success',
    'project_key': '$PROJECT_KEY',
    'run_mode': '$RUN_MODE',
    'elapsed_seconds': $elapsed_sec,
    'total_issues': raw.get('total', 0),
    'severity_counts': severity_counts,
    'issues': issues
}, ensure_ascii=False))
")

  [[ -n "$REPORT_PATH" ]] && echo "$result" > "$REPORT_PATH" && log "==> Report saved: $REPORT_PATH"

  case "$OUTPUT_MODE" in
    json) echo "$result" ;;
    human)
      echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"Project: {d['project_key']} (mode: {d['run_mode']}, {d['elapsed_seconds']}s)\")
print(f\"Total issues: {d['total_issues']}\")
sc = d.get('severity_counts', {})
if sc:
    print('Severity: ' + ', '.join(f'{k}={v}' for k,v in sorted(sc.items())))
print('---')
for i in d['issues']:
    print(f\"[{i['severity']}] {i['component']}:{i['line']} - {i['message']} ({i['rule']})\")
" ;;
    silent) ;;
  esac

  # Threshold check
  if [[ -n "$SEVERITY_THRESHOLD" ]]; then
    local fail_count
    fail_count=$(echo "$result" | python3 -c "
import json, sys
levels = {'BLOCKER':5,'CRITICAL':4,'MAJOR':3,'MINOR':2,'INFO':1}
threshold = levels.get('$SEVERITY_THRESHOLD', 0)
d = json.load(sys.stdin)
print(sum(1 for i in d['issues'] if levels.get(i['severity'],0) >= threshold))
")
    if [[ "$fail_count" -gt 0 ]]; then
      log "==> Threshold violated: $fail_count issue(s) at $SEVERITY_THRESHOLD or above"
      exit 2
    fi
  fi
}

# ============================================================
# Main
# ============================================================
while getopts "m:k:o:p:f:t:e:s:vh" opt; do
  case $opt in
    m) RUN_MODE="$OPTARG" ;;
    k) PROJECT_KEY="$OPTARG" ;;
    o) REPORT_PATH="$OPTARG" ;;
    p) SONAR_PORT="$OPTARG" ;;
    f) OUTPUT_MODE="$OPTARG" ;;
    t) SEVERITY_THRESHOLD="$OPTARG" ;;
    e) EXCLUSIONS="$OPTARG" ;;
    s) SOURCES="$OPTARG" ;;
    v) echo "sonar-scan $VERSION"; exit 0 ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[[ $# -lt 1 ]] && error_json "source directory required. Run with -h for help." "invalid_args"
SOURCE_DIR="$(cd "$1" && pwd)" || error_json "directory not found: $1" "invalid_args"
PROJECT_KEY="${PROJECT_KEY:-$(basename "$SOURCE_DIR")}"

# Auto-detect run mode
if [[ -z "$RUN_MODE" || "$RUN_MODE" == "auto" ]]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    RUN_MODE="docker"
  elif java -version >/dev/null 2>&1; then
    RUN_MODE="local"
  else
    error_json "neither Docker nor Java found. Install Docker or Java 17+." "missing_prerequisite"
  fi
fi

log "==> Run mode: $RUN_MODE"
SCAN_START=$(date +%s)

case "$RUN_MODE" in
  docker) run_docker ;;
  local)  run_local ;;
  *)      error_json "invalid mode: $RUN_MODE (use docker, local, or auto)" ;;
esac
