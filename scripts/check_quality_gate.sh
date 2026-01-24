#!/bin/bash

# Check if required environment variables are set
if [ -z "${METRICS_PATH}" ]; then
  echo "Error: METRICS_PATH environment variable is not set."
  exit 1
fi



echo "Checking Sonar Metrics at ${METRICS_PATH}"

# Check if metrics file exists
if [ ! -f "${METRICS_PATH}" ]; then
  echo "Error: Metrics file not found at ${METRICS_PATH}"
  exit 1
fi

FAILURES=0

if [ -n "${QUALITY_GATE_PATH}" ] && [ -f "${QUALITY_GATE_PATH}" ]; then
  echo "Using Quality Gate defined in ${QUALITY_GATE_PATH}"

  # Read keys from quality gate file
  KEYS=$(jq -r 'keys[]' "${QUALITY_GATE_PATH}")

  for KEY in $KEYS; do
    THRESHOLD=$(jq -r ".[\"${KEY}\"]" "${QUALITY_GATE_PATH}")

    # Extract value from metrics file
    # Assuming metric names in QG match 'metric' field in sonar-metrics.json
    ACTUAL=$(jq -r --arg KEY "$KEY" '(.component.measures[] | select(.metric == $KEY) | .value) // "0"' "${METRICS_PATH}")

    # Handle case where metric is not found in actual metrics (default to 0, or handle error?)
    # For now, default to 0 is safe for "bad" metrics.

    echo "Checking ${KEY}: Actual=${ACTUAL}, Max Allowed=${THRESHOLD}"

    # internal logic: if Actual > Threshold -> Fail
    # Use awk for floating point comparison if needed, or simple integer if all integer
    # Using awk for safety
    if (( $(echo "$ACTUAL > $THRESHOLD" | bc -l) )); then
      echo "  [FAIL] ${KEY} exceeded threshold!"
      FAILURES=$((FAILURES+1))
    else
      echo "  [PASS] ${KEY} within limits."
    fi
  done

else
  echo "No Quality Gate file provided or found. Defaulting to strict vulnerability check (0 allowed)."
  VULN=$(jq -r '.component.measures[] | select(.metric == "vulnerabilities").value // "0"' "${METRICS_PATH}")
  echo "# of vulnerabilities = ${VULN}"

  if [ "${VULN}" != "0" ]; then
    echo "  [FAIL] Vulnerabilities found!"
    FAILURES=$((FAILURES+1))
  else
    echo "  [PASS] No vulnerabilities found."
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "Quality Gate Failed with ${FAILURES} violation(s). Exiting..."
  exit 1
else
  echo "Quality Gate Passed!"
fi
