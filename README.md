# sonar-scan

Ephemeral SonarQube scan CLI — starts a temporary SonarQube instance, scans your code, outputs structured JSON, and cleans up automatically. No persistent daemon required.

## Features

- **Auto-detect runtime**: Docker or local ZIP mode, chosen automatically
- **Zero config**: just point at a directory and scan
- **AI-agent friendly**: structured JSON output to stdout, machine-readable help
- **Multi-OS**: Linux and macOS (Docker mode also supports Windows via Docker Desktop)
- **Threshold gate**: fail with exit code 2 if issues exceed a severity threshold
- **sonar-project.properties**: auto-detected if present in the project

## Supported Languages

Java, JavaScript, TypeScript, Python, C#, Go, Kotlin, Ruby, Scala, PHP, HTML, CSS, XML, Flex (SonarQube Community Edition)

## Prerequisites

| Mode | Requirements |
|---|---|
| Docker (default) | Docker CLI |
| Local ZIP | Java 17+, curl, unzip |
| Both | python3 |

## Install

```bash
# Clone and make executable
git clone <repo-url> && cd sonar-scan
chmod +x sonar-scan.sh

# Optional: add to PATH
ln -s "$(pwd)/sonar-scan.sh" ~/.local/bin/sonar-scan
```

## Quick Start

```bash
# Scan a project (auto-detects Docker or local)
./sonar-scan.sh ./my-project

# Force local mode (no Docker needed)
./sonar-scan.sh -m local ./my-project

# Human-readable output
./sonar-scan.sh -f human ./my-project

# Fail if CRITICAL+ issues found
./sonar-scan.sh -t CRITICAL -f silent ./my-project && echo "PASS" || echo "FAIL"

# Save report to file
./sonar-scan.sh -o report.json ./my-project
```

## Options

```
-m <mode>       Run mode: docker, local, auto (default: auto)
-k <key>        Project key (default: directory name)
-s <paths>      Source directories (comma-separated, relative to project root)
-e <patterns>   Exclusion globs (comma-separated)
-o <path>       Save report JSON to file
-p <port>       SonarQube port (default: 9000)
-f <format>     Output: json (default), human, silent
-t <severity>   Fail (exit 2) if issues >= severity (BLOCKER|CRITICAL|MAJOR|MINOR|INFO)
-v              Version
-h              Help
```

## Output JSON Schema

```json
{
  "status": "success",
  "project_key": "my-app",
  "run_mode": "docker",
  "total_issues": 3,
  "issues": [
    {
      "rule": "python:S1481",
      "severity": "MINOR",
      "component": "src/app.py",
      "line": 42,
      "message": "Remove the unused local variable \"x\"."
    }
  ]
}
```

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Scan completed, no threshold violation |
| 1 | Runtime error |
| 2 | Issues found at or above severity threshold (`-t`) |

## How It Works

1. Starts a temporary SonarQube Community Edition instance (Docker container or local ZIP)
2. Generates an API token
3. Runs sonar-scanner against the target directory
4. Waits for analysis to complete
5. Fetches issues via SonarQube API, outputs structured JSON
6. Stops and removes the instance (Docker) or process (local)

Local mode stores binaries in `~/.sonar-scan/` (shared across all projects).

## License

[MIT](LICENSE)

## Examples

The `examples/` directory contains a sample Python project with intentional issues for testing:

```bash
./sonar-scan.sh ./examples
```
