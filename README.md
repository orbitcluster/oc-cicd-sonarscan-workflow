# CI/CD SonarLess Scanner Workflow

This workflow scans the source code for any vulnerabilities using SonarLess and fails the build if any vulnerabilities are found.

## Why SonarLess?

We use SonarLess to perform SonarQube-quality scans without the need for a dedicated SonarQube server. This approach:

- **Reduces Infrastructure Overhead**: No need to maintain and secure a SonarQube instance.
- **Simplifies CI/CD**: Scans run entirely within the runner, making the workflow self-contained.
- **Cost Effective**: Avoids licensing or hosting costs associated with a full server for simple use cases.
- **Immediate Feedback**: Provides vulnerability feedback directly in the build logs.

## Usage

```yaml
name: Security Scan
on:
  push:
    branches:
      - main
  pull_request:

jobs:
  sonar-scan:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Run SonarLess Scan
        uses: orbitcluster/oc-cicd-sonarscan-workflow@main
        with:
          sonar-source-path: "src"
```

## Inputs

- `fetch-depth`: Number of commits to fetch. 0 indicates all history for all branches and tags.
- `sonar-source-path`: Path to the source code.

## Quality Gate

This workflow enforces a standard quality gate defined in the repository. The build will fail if any of the following thresholds are exceeded:

- **Vulnerabilities**: 0
- **Bugs**: 0
- **Sqale Index**: 0
- **Code Smells**: 20
- **Duplicates**: 20
- **Complexity**: 20
