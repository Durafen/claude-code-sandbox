#!/bin/bash

# Read Claude Code JSON input
input=$(cat)

# Extract information
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
model_name=$(echo "$input" | jq -r '.model.display_name')

# Map model names to GLM display names
case "$model_name" in
    *Opus*) model_name="GLM-4.7" ;;
    *Sonnet*) model_name="GLM-4.7" ;;
    *Haiku*) model_name="GLM-4.5" ;;
esac

session_id=$(echo "$input" | jq -r '.session_id')
transcript_path=$(echo "$input" | jq -r '.transcript_path')

# Transcript path extracted successfully

# Function to calculate context window usage percentage from recent messages only
get_context_percentage() {
    local transcript_file="$1"
    local session_id="$2"
    
    # Check if transcript file exists and is readable
    if [[ ! -f "$transcript_file" || ! -r "$transcript_file" ]]; then
        echo "0"
        return
    fi
    
    # Get the most recent message with usage data - this represents current context
    # Use jq to extract tokens directly from the last message with usage data
    local input_tokens=$(jq -r 'select(.message.usage) | .message.usage.input_tokens // 0' "$transcript_file" 2>/dev/null | tail -1)
    local cache_read_tokens=$(jq -r 'select(.message.usage) | .message.usage.cache_read_input_tokens // 0' "$transcript_file" 2>/dev/null | tail -1)
    local cache_creation_tokens=$(jq -r 'select(.message.usage) | .message.usage.cache_creation_input_tokens // 0' "$transcript_file" 2>/dev/null | tail -1)
    local output_tokens=$(jq -r 'select(.message.usage) | .message.usage.output_tokens // 0' "$transcript_file" 2>/dev/null | tail -1)
    
    # If no usage data found, return 0
    if [[ -z "$input_tokens" || "$input_tokens" == "null" ]]; then
        # echo "DEBUG: NO_USAGE_DATA input_tokens=$input_tokens cache_read_tokens=$cache_read_tokens cache_creation_tokens=$cache_creation_tokens output_tokens=$output_tokens" >> /tmp/statusline_debug.log
        echo "0"
        return
    fi
    
    # Validate numbers
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$cache_read_tokens" =~ ^[0-9]+$ ]] || cache_read_tokens=0
    [[ "$cache_creation_tokens" =~ ^[0-9]+$ ]] || cache_creation_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
    
    # Total current context tokens (use cache_creation + cache_read for context calculation)
    local recent_tokens=$((input_tokens + cache_read_tokens + cache_creation_tokens + output_tokens))
    
    # Token calculation completed
    
    # Calculate percentage against Claude Code's auto-compact threshold (154k)
    # This matches Claude's "Context left until auto-compact" percentage  
    local max_tokens=154254
    local percentage=$((recent_tokens * 100 / max_tokens))
    
    # Cap at 100%
    if [[ $percentage -gt 100 ]]; then
        percentage=100
    fi
    
    # DEBUG: Log detailed token breakdown and calculation
    # echo "DEBUG: CALCULATION session_id=$session_id input_tokens=$input_tokens cache_read_tokens=$cache_read_tokens cache_creation_tokens=$cache_creation_tokens output_tokens=$output_tokens total_tokens=$recent_tokens max_tokens=$max_tokens final_percentage=$percentage" >> /tmp/statusline_debug.log
    
    echo "$percentage"
}

# Function to get color code based on percentage
get_percentage_color() {
    local percentage="$1"
    
    if [[ $percentage -le 80 ]]; then
        echo ""  # Default terminal color (no coloring)
    elif [[ $percentage -le 90 ]]; then
        echo "\033[38;5;184m"  # Yellow (256-color 184)
    else
        echo "\033[38;5;124m"  # Red (256-color 124)
    fi
}

# Function to calculate session duration from transcript timestamps
get_session_duration() {
    local transcript_file="$1"
    
    # Check if transcript file exists and is readable
    if [[ ! -f "$transcript_file" || ! -r "$transcript_file" ]]; then
        echo "0"
        return
    fi
    
    # Extract first and last timestamps from the transcript
    # Look for "timestamp" fields in the JSON structure
    local first_timestamp=$(grep -o '"timestamp":"[^"]*"' "$transcript_file" | head -1 | cut -d'"' -f4)
    local last_timestamp=$(grep -o '"timestamp":"[^"]*"' "$transcript_file" | tail -1 | cut -d'"' -f4)
    
    # If no timestamps found, return 0
    if [[ -z "$first_timestamp" || -z "$last_timestamp" ]]; then
        echo "0"
        return
    fi
    
    # Convert ISO timestamps to epoch seconds (works on both macOS and Linux)
    local first_epoch
    local last_epoch
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS date command
        first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${first_timestamp:0:19}" "+%s" 2>/dev/null)
        last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_timestamp:0:19}" "+%s" 2>/dev/null)
    else
        # Linux date command
        first_epoch=$(date -d "$first_timestamp" "+%s" 2>/dev/null)
        last_epoch=$(date -d "$last_timestamp" "+%s" 2>/dev/null)
    fi
    
    # Validate epoch times
    if [[ ! "$first_epoch" =~ ^[0-9]+$ ]] || [[ ! "$last_epoch" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi
    
    # Calculate duration in minutes
    local duration_seconds=$((last_epoch - first_epoch))
    local duration_minutes=$((duration_seconds / 60))
    
    # Ensure non-negative duration
    if [[ $duration_minutes -lt 0 ]]; then
        duration_minutes=0
    fi
    
    echo "$duration_minutes"
}

# Get directory name
dir_name=$(basename "$current_dir")

# Change to directory for git operations
cd "$current_dir" 2>/dev/null || cd "$HOME"

# Build statusline components
components=""

# Directory name in cyan
components+="\033[36m${dir_name}\033[0m"

# Git info if in repository
if git rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --always 2>/dev/null)
    
    # Add pipe separator before git section
    components+=" \033[38;5;105m|\033[0m \033[38;5;219m${branch}\033[0m"
    
    # Check for dirty state (uncommitted changes + untracked files)
    is_dirty=false
    
    # Check for uncommitted changes (staged + unstaged)
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        is_dirty=true
    fi
    
    # Check for untracked files
    if [[ -n $(git ls-files --others --exclude-standard 2>/dev/null) ]]; then
        is_dirty=true
    fi
    
    
    # Show uncommitted changes stats if dirty
    stats_parts=""
    
    # Get tracked file changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        tracked_stats=$(git diff HEAD --numstat 2>/dev/null | awk 'BEGIN{added=0; deleted=0} {if($1!="" && $1!="-") added+=$1; if($2!="" && $2!="-") deleted+=$2} END {if(NR>0) printf "+%d -%d", added, deleted}')
        if [[ -n "$tracked_stats" ]]; then
            stats_parts="$tracked_stats"
        fi
    fi
    
    # Get untracked file count
    untracked_count=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$untracked_count" -gt 0 ]]; then
        if [[ -n "$stats_parts" ]]; then
            stats_parts="$stats_parts ◦$untracked_count"
        else
            stats_parts="◦$untracked_count"
        fi
    fi
    
    # Add stats if any exist
    if [[ -n "$stats_parts" ]]; then
        components+=" \033[38;5;111m${stats_parts}\033[0m"
    fi
    
    # Get ahead/behind counts relative to upstream
    if git rev-parse --abbrev-ref @{upstream} >/dev/null 2>&1; then
        # Get left-right counts: left=behind, right=ahead
        counts=$(git rev-list --count --left-right @{upstream}...HEAD 2>/dev/null)
        if [[ -n "$counts" ]]; then
            behind=$(echo "$counts" | cut -f1)
            ahead=$(echo "$counts" | cut -f2)
            
            if [[ "$ahead" -gt 0 ]] && [[ "$behind" -gt 0 ]]; then
                components+=" \033[38;5;111m↑${ahead} ↓${behind}\033[0m"
            elif [[ "$ahead" -gt 0 ]]; then
                components+=" \033[38;5;111m↑${ahead}\033[0m"
            elif [[ "$behind" -gt 0 ]]; then
                components+=" \033[38;5;111m↓${behind}\033[0m"
            fi
        fi
    fi
fi

# Add pipe separator before model name
components+=" \033[38;5;105m|\033[0m"

# Model name in gray
components+=" \033[90m${model_name}\033[0m"

# Calculate context percentage and session duration  
context_percentage=$(get_context_percentage "$transcript_path" "$session_id")
percentage_color=$(get_percentage_color "$context_percentage")
session_duration=$(get_session_duration "$transcript_path")


# Function to get GLM usage stats from API with 60-second caching
get_glm_usage() {
    local cache_file="/tmp/glm_usage_cache.json"
    local cache_max_age=60  # seconds

    # Check if cache exists and is fresh
    if [[ -f "$cache_file" ]]; then
        local cache_time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_time=$(stat -f "%m" "$cache_file" 2>/dev/null)
        else
            cache_time=$(stat -c "%Y" "$cache_file" 2>/dev/null)
        fi
        local current_time=$(date +%s)
        local cache_age=$((current_time - cache_time))

        if [[ $cache_age -lt $cache_max_age ]]; then
            # Cache is fresh, use it
            cat "$cache_file"
            return
        fi
    fi

    # Get base domain and auth token from environment
    local base_domain="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
    local auth_token="${ANTHROPIC_AUTH_TOKEN:-}"

    # Extract domain from base URL (remove protocol and path)
    if [[ "$base_domain" =~ ^https?://([^/]+) ]]; then
        base_domain="${BASH_REMATCH[1]}"
    fi

    # If no auth token available, return empty
    if [[ -z "$auth_token" || "$auth_token" == "null" ]]; then
        echo "{}"
        return
    fi

    # Call GLM usage API
    local api_url="https://${base_domain}/api/monitor/usage/quota/limit"
    local response=$(curl -s "$api_url" \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "{}"
        return
    fi

    # Save to cache
    echo "$response" > "$cache_file"

    echo "$response"
}



# Get GLM usage data
glm_response=$(get_glm_usage)
mcp_current=$(echo "$glm_response" | jq -r '.data.limits[0].currentValue // empty' 2>/dev/null)
mcp_total=$(echo "$glm_response" | jq -r '.data.limits[0].usage // empty' 2>/dev/null)
glm_percentage=$(echo "$glm_response" | jq -r '.data.limits[1].percentage // empty' 2>/dev/null)
glm_reset_ms=$(echo "$glm_response" | jq -r '.data.limits[1].nextResetTime // empty' 2>/dev/null)

# Calculate GLM reset time remaining
glm_reset_time=""
if [[ -n "$glm_reset_ms" && "$glm_reset_ms" != "null" && "$glm_reset_ms" != "empty" ]]; then
    # Convert milliseconds to seconds
    glm_reset_epoch=$((glm_reset_ms / 1000))
    current_epoch=$(date +%s)
    seconds_remaining=$((glm_reset_epoch - current_epoch))

    if [[ $seconds_remaining -gt 0 ]]; then
        hours=$((seconds_remaining / 3600))
        mins=$(( (seconds_remaining % 3600) / 60 ))
        # Round up minutes if there are remaining seconds
        remaining_secs=$((seconds_remaining % 60))
        [[ $remaining_secs -gt 0 ]] && mins=$((mins + 1))
        [[ $mins -ge 60 ]] && { hours=$((hours + 1)); mins=0; }
        glm_reset_time="${hours}h ${mins}m"
    fi
fi


# Add GLM usage stats if available
if [[ -n "$mcp_current" && -n "$mcp_total" && "$mcp_current" != "null" && "$mcp_total" != "null" ]]; then
    # Calculate MCP expected usage based on days elapsed in current month
    # Get current day and total days in month
    current_day=$(date +%-d)
    current_month=$(date +%-m)
    current_year=$(date +%Y)

    # Calculate days in month (handle leap years for Feb)
    case $current_month in
        1|3|5|7|8|10|12) days_in_month=31 ;;
        4|6|9|11) days_in_month=30 ;;
        2)
            # Check for leap year
            if (( current_year % 4 == 0 && (current_year % 100 != 0 || current_year % 400 == 0) )); then
                days_in_month=29
            else
                days_in_month=28
            fi
            ;;
    esac

    # Calculate expected usage percentage
    expected_usage=$((current_day * 100 / days_in_month))

    # Calculate actual usage percentage
    actual_usage=$((mcp_current * 100 / mcp_total))

    # Calculate days remaining in month (needed for burn rate calculations)
    days_remaining=$((days_in_month - current_day))

    # Determine MCP color based on burn rate
    # Calculate if we're burning quota faster than time passing
    # time_left_pct: percentage of month remaining
    # quota_left_pct: percentage of quota remaining
    time_left_pct=$((100 * days_remaining / days_in_month))
    quota_left_pct=$((100 - (mcp_current * 100 / mcp_total)))

    # Calculate burn rate: how much quota used vs time used
    # Positive = burning faster than time (will run out early)
    # Negative = on track/under budget
    burn_overage=$((quota_left_pct - time_left_pct))

    # Color based on burn rate
    # Yellow: quota left < time left (burning faster than calendar)
    # Red: significantly over (>15% ahead of schedule)
    mcp_color=""
    if [[ $burn_overage -lt -15 ]]; then
        mcp_color="\033[38;5;124m"  # Red
    elif [[ $burn_overage -lt 0 ]]; then
        mcp_color="\033[38;5;184m"  # Yellow
    fi

    # Calculate MCP percentage
    mcp_percentage=$((mcp_current * 100 / mcp_total))

    # Build MCP display string
    if [[ -n "$mcp_color" ]]; then
        mcp_display="${mcp_color}MCP: ${mcp_percentage}%\033[0m \033[90m${days_remaining}d\033[0m"
    else
        mcp_display="MCP: ${mcp_percentage}% ${days_remaining}d"
    fi

    # Calculate GLM token burn rate (5h window)
    glm_color=""
    if [[ -n "$glm_percentage" && "$glm_percentage" != "null" && -n "$glm_reset_ms" && "$glm_reset_ms" != "null" ]]; then
        # Calculate time elapsed in 5-hour window (300 minutes)
        glm_reset_epoch=$((glm_reset_ms / 1000))
        current_epoch=$(date +%s)
        seconds_remaining=$((glm_reset_epoch - current_epoch))

        if [[ $seconds_remaining -gt 0 ]]; then
            # 5-hour window = 300 minutes total
            total_minutes=300
            minutes_remaining=$((seconds_remaining / 60))
            minutes_elapsed=$((total_minutes - minutes_remaining))
            [[ $minutes_elapsed -lt 0 ]] && minutes_elapsed=0
            [[ $minutes_elapsed -gt $total_minutes ]] && minutes_elapsed=$total_minutes

            # Calculate expected vs actual usage
            time_elapsed_pct=$((minutes_elapsed * 100 / total_minutes))
            quota_left_pct=$((100 - glm_percentage))
            time_left_pct=$((100 - time_elapsed_pct))

            # Burn overage: negative = burning faster than time
            burn_overage=$((quota_left_pct - time_left_pct))

            # Color based on burn rate
            if [[ $burn_overage -lt -15 ]]; then
                glm_color="\033[38;5;124m"  # Red
            elif [[ $burn_overage -lt 0 ]]; then
                glm_color="\033[38;5;184m"  # Yellow
            fi
        fi
    fi

    # Build GLM display string
    glm_display=""
    if [[ -n "$glm_percentage" && "$glm_percentage" != "null" ]]; then
        if [[ -n "$glm_reset_time" ]]; then
            if [[ -n "$glm_color" ]]; then
                glm_display="5h: ${glm_color}${glm_percentage}%\033[0m ${glm_reset_time}"
            else
                glm_display="5h: ${glm_percentage}% ${glm_reset_time}"
            fi
        else
            if [[ -n "$glm_color" ]]; then
                glm_display="5h: ${glm_color}${glm_percentage}%\033[0m"
            else
                glm_display="5h: ${glm_percentage}%"
            fi
        fi
    fi

    # Add to statusline
    if [[ -n "$glm_display" ]]; then
        components+=" \033[38;5;105m|\033[0m \033[90m${glm_display} | ${mcp_display}\033[0m"
    else
        components+=" \033[38;5;105m|\033[0m \033[90m${mcp_display}\033[0m"
    fi
fi

# DEBUG: Log what we're actually outputting
# echo "DEBUG: FINAL_OUTPUT context_percentage=$context_percentage percentage_color='$percentage_color' session_duration=$session_duration usage_5h=$usage_5h usage_weekly=$usage_weekly" >> /tmp/statusline_debug.log
# echo "DEBUG: FINAL_COMPONENTS='$components'" >> /tmp/statusline_debug.log

# Output final statusline
printf "%b" "$components"