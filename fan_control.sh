#!/bin/bash

# Systemd logging configuration
LOG_TAG="fan_control"
CONFIG_FILE="/etc/fan_control.conf"

# === DEFAULT VALUES (Overwritten if external config exists) ===
# Energy profile: "quiet", "balanced", "performance"
PROFILE="balanced"

# Define temperature thresholds in Celsius for smooth mapping
MIN_TEMP=30
MAX_TEMP=60
CRITICAL_TEMP=80  # Critical temperature for protection

# Define minimum and maximum PWM values
MIN_PWM=60
MAX_PWM=255
QUIET_MAX_PWM=165 # Default quiet limit if not in config

# Hysteresis to avoid oscillations
TEMP_HYSTERESIS=2

# Configuration for aggressive thermal protection
TEMP_RISE_THRESHOLD=3  # If rises more than 3°C in one reading, activate protection
EMERGENCY_PWM=255      # Emergency PWM

# Slew Rate Configuration (Speed change smoothing)
SLEW_RATE_LIMIT=15     # Maximum PWM change allowed per cycle

# Load external configuration if exists
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# === CLI ARGUMENT PARSING ===
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Dell Optiplex Intelligent Fan Control (DeltaFlow)"
    echo ""
    echo "Options:"
    echo "  --profile <mode>   Sets the profile (balanced, performance)"
    echo "  --log              Shows real-time log (tail -f)"
    echo "  --help             Shows this help"
    echo ""
    echo "Current Active Configuration:"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  Source:        $CONFIG_FILE (Loaded)"
    else
        echo "  Source:        Internal Defaults"
    fi
    echo "  Profile:       $PROFILE"
    echo "  Temp Range:    $MIN_TEMP°C - $MAX_TEMP°C (Crit: $CRITICAL_TEMP°C)"
    echo "  PWM Range:     $MIN_PWM - $MAX_PWM"
    echo "  Quiet Limit:   $QUIET_MAX_PWM (Balanced Profile)"
    echo "  Slew Rate:     $SLEW_RATE_LIMIT"
    echo "  Hysteresis:    $TEMP_HYSTERESIS°C"
}

# Process arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --log)
            echo "Showing logs for $LOG_TAG (Ctrl+C to exit)..."
            journalctl -t "$LOG_TAG" -f
            exit 0
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate selected profile
if [[ ! "$PROFILE" =~ ^(balanced|performance)$ ]]; then
    echo "Error: Invalid profile '$PROFILE'. Using 'balanced'."
    PROFILE="balanced"
fi

# Define paths to hardware files (resolved from globs at startup)
GET_CPU_TEMP_FILE=""
GET_FAN_RPM_FILE=""
SET_FAN_SPEED_FILE=""

# Resolve globs to concrete paths and assign to variables
resolve_paths() {
    # Enable nullglob so non-matching patterns expand to nothing
    shopt -s nullglob

    local temp_candidates=(/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)
    if (( ${#temp_candidates[@]} == 0 )); then
        log_message "ERROR: /temp1_input not found in coretemp hwmon (searching: /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)"
        exit 1
    fi
    GET_CPU_TEMP_FILE="${temp_candidates[0]}"

    # Check if dell_smm_hwmon is available and functional
    local pwm_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/pwm1)
    local fan_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/fan1_input)
    
    if (( ${#fan_candidates[@]} > 0 )); then
        GET_FAN_RPM_FILE="${fan_candidates[0]}"
        log_message "Using fan rpm file: $GET_FAN_RPM_FILE"
    fi
    
    if (( ${#pwm_candidates[@]} == 0 )) && (( ${#fan_candidates[@]} == 0 )); then
        log_message "WARN: dell_smm_hwmon does not expose fan files - attempting to reload module with force=1 restricted=0"
        
        # Show current module state
        if dmesg | tail -5 | grep -q "dell_smm_hwmon"; then
            log_message "INFO: Last module messages: $(dmesg | grep dell_smm_hwmon | tail -2 | tr '\n' ' ')"
        fi
        
        modprobe -r dell_smm_hwmon 2>/dev/null || true
        sleep 2
        modprobe dell_smm_hwmon force=1 restricted=0 2>/dev/null || true
        sleep 3
        
        # Check again after reload
        pwm_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/pwm1)
        fan_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/fan1_input)
        
        if (( ${#pwm_candidates[@]} == 0 )) && (( ${#fan_candidates[@]} == 0 )); then
            log_message "ERROR: EC/BIOS blocked fan control access. Available files:"
            if ls /sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/ 2>/dev/null | grep -v "device\|power\|subsystem\|uevent" | head -5; then
                log_message "INFO: Only temperature sensors available. To recover PWM control: full shutdown (not reboot)"
            fi
            SET_FAN_SPEED_FILE=""
        else
            SET_FAN_SPEED_FILE="${pwm_candidates[0]}"
            log_message "SUCCESS: PWM control recovered after module reload"
        fi
    elif (( ${#pwm_candidates[@]} > 0 )); then
        SET_FAN_SPEED_FILE="${pwm_candidates[0]}"
        log_message "SUCCESS: PWM control available from start"
    else
        log_message "WARN: dell_smm_hwmon partially functional - only readings available"
        SET_FAN_SPEED_FILE=""
    fi

    # Restore default behavior
    shopt -u nullglob

    log_message "Using temp file: $GET_CPU_TEMP_FILE"
    if [[ -n "$SET_FAN_SPEED_FILE" ]]; then
        log_message "Using pwm file: $SET_FAN_SPEED_FILE"
    else
        log_message "MONITORING ONLY MODE: No PWM control (EC/BIOS blocked access)"
    fi
}

# Variable to store previous PWM
previous_pwm=$MIN_PWM
previous_temp=0
previous_temp_diff=0  # To calculate acceleration (2nd derivative)

# Function for systemd compatible logging
log_message() {
    # Optimization: Use printf builtin for date instead of calling 'date' binary
    local now
    printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
    # Only use logger to avoid contaminating output of substituted commands
    logger -t "$LOG_TAG" "$now - $1"
}

# === CONTROL STRATEGIES (PROFILES) ===

# Balanced Strategy: Dual Slope (Quiet < 60°C, Aggressive > 60°C) + Load Compensation
strategy_balanced() {
    local temp=$1
    local temp_diff=$2
    local temp_accel=$3
    local cpu_load=$4
    local predicted_temp=$temp

    # 1. Feed-Forward: CPU Load (Pure anticipation)
    # cpu_load is passed as integer (e.g., 100 for 1.00 load)
    
    if (( cpu_load > 100 )); then
        local load_factor=$(( (cpu_load - 100) / 50 ))
        if (( load_factor > 10 )); then load_factor=10; fi
        predicted_temp=$((predicted_temp + load_factor))
        if (( load_factor > 0 )); then
            log_message "PERF-FEEDFORWARD: High CPU Load ($cpu_load), +${load_factor}°C compensation"
        fi
    fi
    
    # 2. Base Prediction (Velocity)
    if (( temp_diff > 0 )); then
        predicted_temp=$((predicted_temp + temp_diff))
    fi
    
    # 3. Acceleration Correction
    if (( temp_accel > 0 )); then
        local boost=$((temp_accel * 3))
        predicted_temp=$((predicted_temp + boost))
        log_message "PERF-BOOST: Thermal acceleration (+${temp_accel}), Predicted Temp: ${predicted_temp}°C"
    fi
    
    # Prediction limits
    if (( predicted_temp > MAX_TEMP )); then predicted_temp=$MAX_TEMP; fi
    if (( predicted_temp < MIN_TEMP )); then predicted_temp=$MIN_TEMP; fi
    
    # Linear Mapping on prediction
    local pwm=$(( (predicted_temp - MIN_TEMP) * (MAX_PWM - MIN_PWM) / (MAX_TEMP - MIN_TEMP) + MIN_PWM ))
    
    # Elevated minimum floor for performance
    local perf_min_pwm=$((MIN_PWM + 30))
    if (( pwm < perf_min_pwm )); then pwm=$perf_min_pwm; fi
    
    echo $pwm
}

# === CONTROL STRATEGIES (PROFILES) ===

# Balanced Strategy: Dual Slope (Quiet < 60°C, Aggressive > 60°C) + Load Compensation
strategy_balanced() {
    local temp=$1
    local temp_diff=$2
    local cpu_load=$3
    local current_rpm=$4
    local pwm

    # Configuration for "Quiet" phase
    # We use MAX_TEMP (default 60) as the boundary between Quiet and Performance
    local quiet_max_temp=$MAX_TEMP      
    local quiet_max_pwm=$QUIET_MAX_PWM  # Use variable from config/defaults
    
    # 1. Base Curve (Dual Slope)
    if (( temp < MIN_TEMP )); then
        pwm=$MIN_PWM
    elif (( temp < quiet_max_temp )); then
        # Slope 1: Gentle rise from MIN_TEMP to MAX_TEMP (reaching only quiet_max_pwm)
        # Formula: PWM = MIN + (T - Tmin) * (QMax - Min) / (Tmax - Tmin)
        local slope=$(( (quiet_max_pwm - MIN_PWM) * 100 / (quiet_max_temp - MIN_TEMP) ))
        local offset=$(( (temp - MIN_TEMP) * slope / 100 ))
        pwm=$(( MIN_PWM + offset ))
    elif (( temp < CRITICAL_TEMP )); then
        # Slope 2: Aggressive rise from MAX_TEMP to CRITICAL_TEMP
        # Formula: PWM = QMax + (T - Tmax) * (Max - QMax) / (Tcrit - Tmax)
        local slope=$(( (MAX_PWM - quiet_max_pwm) * 100 / (CRITICAL_TEMP - quiet_max_temp) ))
        local offset=$(( (temp - quiet_max_temp) * slope / 100 ))
        pwm=$(( quiet_max_pwm + offset ))
    else
        pwm=$MAX_PWM
    fi

    # 2. CPU Load Compensation (Feed-forward)
    # Only apply if we are not yet at critical levels, to prevent premature saturation
    if (( cpu_load > 150 )); then  # Load > 1.5
        local load_boost=$(( (cpu_load - 150) / 10 )) # +1 PWM per 0.1 load above 1.5
        if (( load_boost > 20 )); then load_boost=20; fi # Cap boost
        pwm=$(( pwm + load_boost ))
    fi

    # Clamp result
    if (( pwm > MAX_PWM )); then pwm=$MAX_PWM; fi
    if (( pwm < MIN_PWM )); then pwm=$MIN_PWM; fi

    echo $pwm
}

# Performance Strategy: Feed-Forward + Acceleration
strategy_performance() {
    local temp=$1
    local temp_diff=$2
    local temp_accel=$3
    local cpu_load=$4
    local predicted_temp=$temp

    # 1. Feed-Forward: CPU Load (Pure anticipation)
    # cpu_load is passed as integer (e.g., 100 for 1.00 load)
    
    if (( cpu_load > 100 )); then
        local load_factor=$(( (cpu_load - 100) / 50 ))
        if (( load_factor > 10 )); then load_factor=10; fi
        predicted_temp=$((predicted_temp + load_factor))
        if (( load_factor > 0 )); then
            log_message "PERF-FEEDFORWARD: High CPU Load ($cpu_load), +${load_factor}°C compensation"
        fi
    fi
    
    # 2. Base Prediction (Velocity)
    if (( temp_diff > 0 )); then
        predicted_temp=$((predicted_temp + temp_diff))
    fi
    
    # 3. Acceleration Correction
    if (( temp_accel > 0 )); then
        local boost=$((temp_accel * 3))
        predicted_temp=$((predicted_temp + boost))
        log_message "PERF-BOOST: Thermal acceleration (+${temp_accel}), Predicted Temp: ${predicted_temp}°C"
    fi
    
    # Prediction limits
    if (( predicted_temp > MAX_TEMP )); then predicted_temp=$MAX_TEMP; fi
    if (( predicted_temp < MIN_TEMP )); then predicted_temp=$MIN_TEMP; fi
    
    # Linear Mapping on prediction
    local pwm=$(( (predicted_temp - MIN_TEMP) * (MAX_PWM - MIN_PWM) / (MAX_TEMP - MIN_TEMP) + MIN_PWM ))
    
    # Elevated minimum floor for performance
    local perf_min_pwm=$((MIN_PWM + 30))
    if (( pwm < perf_min_pwm )); then pwm=$perf_min_pwm; fi
    
    echo $pwm
}

# Main calculation function (Dispatcher)
calculate_pwm() {
    local temp=$1
    local temp_diff=$2
    local temp_accel=$3
    local cpu_load=$4
    local current_rpm=$5
    
    # Safety Override: Absolute critical protection
    if (( temp >= CRITICAL_TEMP )); then
        log_message "CRITICAL: Critical temperature ${temp}°C, Max PWM"
        echo $MAX_PWM
        return
    fi
    
    case "$PROFILE" in
        "performance") strategy_performance "$temp" "$temp_diff" "$temp_accel" "$cpu_load" ;;
        "balanced"|*)  strategy_balanced "$temp" "$temp_diff" "$cpu_load" "$current_rpm" ;;
    esac
}

# Function to check hardware files
check_hardware_files() {
    if [[ ! -r $GET_CPU_TEMP_FILE ]]; then
        log_message "ERROR: Cannot read temperature file: $GET_CPU_TEMP_FILE"
        exit 1
    fi
    
    # Only check PWM if available
    if [[ -n "$SET_FAN_SPEED_FILE" ]] && [[ ! -w $SET_FAN_SPEED_FILE ]] && [[ $EUID -ne 0 ]]; then
        log_message "ERROR: Cannot write to PWM file: $SET_FAN_SPEED_FILE (run as root)"
        exit 1
    fi
}

# Cleanup function on exit
cleanup() {
    log_message "Termination signal received, restoring fan to automatic"
    # Optional: restore fan to automatic mode
    exit 0
}

# Function to diagnose dell_smm_hwmon state
diagnose_dell_hwmon() {
    log_message "=== DELL_SMM_HWMON DIAGNOSTIC ==="
    
    # Check if module is loaded
    if lsmod | grep -q dell_smm_hwmon; then
        log_message "INFO: dell_smm_hwmon module loaded"
    else
        log_message "WARN: dell_smm_hwmon module NOT loaded"
        return
    fi
    
    # Check available files
    if [[ -d "/sys/devices/platform/dell_smm_hwmon/hwmon" ]]; then
        local hwmon_dir=$(find /sys/devices/platform/dell_smm_hwmon/hwmon -name "hwmon*" -type d | head -1)
        if [[ -n "$hwmon_dir" ]]; then
            local available_files=$(ls "$hwmon_dir" 2>/dev/null | grep -E "temp|fan|pwm" | tr '\n' ' ')
            log_message "INFO: Available files: $available_files"
            
            # Check module parameters if there are issues
            if [[ ! -f "$hwmon_dir/pwm1" ]]; then
                if [[ -f "/sys/module/dell_smm_hwmon/parameters/restricted" ]]; then
                    local restricted_val=$(cat /sys/module/dell_smm_hwmon/parameters/restricted)
                    log_message "DEBUG: Module 'restricted' parameter is: $restricted_val (Must be 0 for PWM control)"
                fi
            fi

            # Check specifically for PWM and fan
            if ls "$hwmon_dir"/pwm* >/dev/null 2>&1; then
                log_message "SUCCESS: PWM files found - control available"
            elif ls "$hwmon_dir"/fan* >/dev/null 2>&1; then
                log_message "PARTIAL: Only fan files - no PWM control"
            else
                log_message "LIMITED: Only temperature sensors - EC blocked fans"
            fi
        fi
    else
        log_message "ERROR: dell_smm_hwmon directory not found"
    fi
    
    log_message "=== END DIAGNOSTIC ==="
}

# Capture signals for cleanup
trap cleanup SIGTERM SIGINT

log_message "Starting intelligent fan control (Profile: $PROFILE)"
diagnose_dell_hwmon
resolve_paths
check_hardware_files

# Function to apply fan changes (Hysteresis + Slew Rate + Writing)
apply_fan_control() {
    local target_pwm=$1
    local current_temp=$2
    local temp_diff=$3
    local is_emergency=$4
    local cpu_load=$5
    local current_rpm=$6
    
    # Calculate difference with current PWM
    local pwm_diff=$((target_pwm - previous_pwm))
    if (( pwm_diff < 0 )); then pwm_diff=$((-pwm_diff)); fi
    
    # Update conditions: Significant change, leaving minimum, or emergency
    if (( pwm_diff > 10 )) || (( previous_pwm == MIN_PWM )) || (( is_emergency )); then
        
        # === SLEW RATE LIMITING (Smoothing) ===
        if (( ! is_emergency )); then
            local change=$((target_pwm - previous_pwm))
            if (( change > SLEW_RATE_LIMIT )); then
                target_pwm=$((previous_pwm + SLEW_RATE_LIMIT))
                log_message "SLEW-LIMIT: Limiting acceleration to +${SLEW_RATE_LIMIT} (Real target: $((previous_pwm + change)))"
            elif (( change < -SLEW_RATE_LIMIT )); then
                target_pwm=$((previous_pwm - SLEW_RATE_LIMIT))
            fi
        fi

        # === HARDWARE WRITING ===
        # Format load for display (e.g. 150 -> 1.50)
        local load_display
        if (( cpu_load < 100 )); then
            printf -v load_display "0.%02d" $cpu_load
        else
            local whole=$((cpu_load / 100))
            local dec=$((cpu_load % 100))
            printf -v load_display "%d.%02d" $whole $dec
        fi

        if [[ -n "$SET_FAN_SPEED_FILE" ]]; then
            echo "$target_pwm" > "$SET_FAN_SPEED_FILE"
            log_message "Temp: ${current_temp}°C (Δ+${temp_diff}°C), Load: ${load_display}, RPM: ${current_rpm}, PWM: ${target_pwm} (prev: ${previous_pwm})"
        else
            log_message "Temp: ${current_temp}°C (Δ+${temp_diff}°C), Load: ${load_display}, RPM: ${current_rpm}, PWM: ${target_pwm} (NO CONTROL - monitoring only)"
        fi
        
        # Update global state
        previous_pwm=$target_pwm
    fi
}

# The script logic will run in an infinite loop
while true; do
    # 1. SENSOR READING
    read -r raw_temp < "$GET_CPU_TEMP_FILE"
    current_cpu_temp=$((raw_temp / 1000))
    
    # Read CPU Load (1 min avg)
    read -r load_str _ < /proc/loadavg
    # Convert to integer (e.g. 1.50 -> 150) for arithmetic
    load_int=${load_str/./}
    # Remove leading zeros to avoid octal interpretation (unless it's just "0")
    if [[ "$load_int" =~ ^0+([1-9][0-9]*)$ ]]; then
        load_int=${BASH_REMATCH[1]}
    elif [[ "$load_int" =~ ^0+$ ]]; then
        load_int=0
    fi
    current_cpu_load=$load_int
    
    # 2. DERIVATIVE CALCULATION (Velocity and Acceleration)
    temp_diff=$((current_cpu_temp - previous_temp))
    temp_accel=$((temp_diff - previous_temp_diff))
    
    # Read RPM if available
    current_rpm=0
    if [[ -n "$GET_FAN_RPM_FILE" ]] && [[ -r "$GET_FAN_RPM_FILE" ]]; then
        read -r current_rpm < "$GET_FAN_RPM_FILE"
    fi

    # Normalize diff for base calculations (only rises matter for fast reaction)
    calc_diff=$temp_diff
    if (( calc_diff < 0 )); then calc_diff=0; fi
    
    # 3. TARGET PWM CALCULATION
    target_pwm=$(calculate_pwm $current_cpu_temp $calc_diff $temp_accel $current_cpu_load $current_rpm)
    
    # 4. EMERGENCY EVALUATION
    emergency_condition=$((current_cpu_temp >= CRITICAL_TEMP || temp_diff > TEMP_RISE_THRESHOLD))
    
    # 5. CONTROL APPLICATION
    apply_fan_control "$target_pwm" "$current_cpu_temp" "$temp_diff" "$emergency_condition" "$current_cpu_load" "$current_rpm"
    
    # 6. STATE UPDATE
    previous_temp_diff=$temp_diff
    previous_temp=$current_cpu_temp

    sleep 2
done
