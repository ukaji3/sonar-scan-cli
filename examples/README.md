# Example project

Sample Python code with intentional issues for testing `sonar-scan.sh`.

```bash
../sonar-scan.sh ./examples
```

`app.py` contains deliberate bugs, code smells, and security issues (hardcoded credentials, mutable defaults, bare except, etc.) to verify that SonarQube detects them correctly.
