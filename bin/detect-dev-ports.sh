#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# List of common development server ports to check
DEV_PORTS=(3000 3001 5000 5001 5173 5174 8000 8001 8080 9000 9001)
LISTENING_PORTS=()

# Determine the best tool for checking listening ports
PORT_INFO=""
PORT_FIELD=""

if command -v ss &> /dev/null; then
    # ss is preferred. -t: TCP, -l: listening, -n: numeric
    # Capture output of ss to avoid multiple calls
    PORT_INFO=$(ss -tln)
    PORT_FIELD=4 # The 4th field is usually the IP:Port for ss
elif command -v netstat &> /dev/null; then
    # Fallback to netstat. -t: TCP, -u: UDP (we only care about TCP here), -l: listening, -n: numeric
    # Filter for TCP lines only.
    PORT_INFO=$(netstat -tuln | grep '^tcp')
    PORT_FIELD=4 # The 4th field is usually the IP:Port for netstat
else
    echo "Error: Neither 'ss' nor 'netstat' command found. Cannot detect ports." >&2
    echo "[]" # Return empty JSON as per requirement for no ports open
    exit 1
fi

# Iterate through the defined ports and check if they are listening
for PORT in "${DEV_PORTS[@]}"; do
    # Use awk to extract the 4th field (IP:PORT) and grep to check if it ends with :PORT.
    # This handles cases like 0.0.0.0:PORT and :::PORT.
    # The 'grep -q': suppresses output and returns success (0) if a match is found.
    if echo "$PORT_INFO" | awk -v field="$PORT_FIELD" '{print $field}' | grep -q ":$PORT$"; then
        LISTENING_PORTS+=("$PORT")
    fi
done

# Format output as JSON array
if [ ${#LISTENING_PORTS[@]} -eq 0 ]; then
    echo "[]"
else
    if command -v jq &> /dev/null; then
        # Use jq to create a JSON array of strings.
        # jq -s '.' reads all lines from stdin and collects them into a single array.
        printf "%s\n" "${LISTENING_PORTS[@]}" | jq -s '.'
    else
        # Basic JSON formatting if jq is not available.
        JSON_OUTPUT="["
        for i in "${!LISTENING_PORTS[@]}"; do
            JSON_OUTPUT+="${LISTENING_PORTS[$i]}"
            if [ $i -lt $((${#LISTENING_PORTS[@]} - 1)) ]; then
                JSON_OUTPUT+", "
            fi
        done
        JSON_OUTPUT+="]"
        echo "$JSON_OUTPUT"
    fi
fi

exit 0
