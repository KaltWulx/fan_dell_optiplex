#!/bin/bash

# fan_calibration.sh
# Tool to calibrate PWM/RPM curve and generate configuration for fan_control.sh
# Author: KaltWulx

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

cat <<'EOF'
╔═════════════════════════════════════════════════╗
║   Dell Optiplex Fan Control - Calibration Tool   ║
╚═════════════════════════════════════════════════╝
This guided routine will:
    1. stop the active fan_control service,
    2. capture your desired temperature thresholds,
    3. read your idle temperature baseline,
    4. sweep fan PWM steps while you evaluate noise,
    5. save or skip a tuned `/etc/fan_control.conf` entry.
EOF

read -p "Press [Enter] to begin the calibration journey..."

# === 1. HARDWARE DETECTION ===
echo ""
echo "🧭 Step 1 – Hardware Detection"
echo "--------------------------------"
echo "Scanning for the CPU temperature sensor..."

# Enable nullglob
shopt -s nullglob

# Find Temp Sensor
temp_candidates=(/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)
if (( ${#temp_candidates[@]} == 0 )); then
    echo "Error: CPU Temperature sensor not found."
    exit 1
fi
GET_CPU_TEMP_FILE="${temp_candidates[0]}"
echo "  ✅ CPU Temp Sensor located at: $GET_CPU_TEMP_FILE"

# Find PWM and Fan Inputs
pwm_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/pwm1)
fan_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/fan1_input)

if (( ${#pwm_candidates[@]} == 0 )); then
    echo "  ⚠️  PWM Control file missing. Reloading dell_smm_hwmon..."
    modprobe -r dell_smm_hwmon 2>/dev/null
    sleep 2
    modprobe dell_smm_hwmon force=1 restricted=0 2>/dev/null
    sleep 2
    pwm_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/pwm1)
    fan_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/fan1_input)
fi

if (( ${#pwm_candidates[@]} > 0 )); then
    SET_FAN_SPEED_FILE="${pwm_candidates[0]}"
    echo "  ✅ PWM Control ready at: $SET_FAN_SPEED_FILE"
else
    echo "Error: Could not enable PWM control. Check BIOS settings."
    exit 1
fi

if (( ${#fan_candidates[@]} > 0 )); then
    GET_FAN_RPM_FILE="${fan_candidates[0]}"
    echo "  ✅ RPM Sensor ready at: $GET_FAN_RPM_FILE"
else
    echo "  ⚠️  RPM sensor missing; RPM data will be unavailable."
fi


CONFIG_FAN_RPM_FILES=()
CONFIG_FAN_MIN_VALUES=()
CONFIG_FAN_MAX_VALUES=()

if (( ${#fan_candidates[@]} > 0 )); then
    CONFIG_FAN_RPM_FILES=("${fan_candidates[@]}")
    for fan_path in "${fan_candidates[@]}"; do
        fan_min="N/A"
        fan_max="N/A"
        min_file="${fan_path%_input}_min"
        max_file="${fan_path%_input}_max"

        if [[ -r "$min_file" ]]; then
            fan_min=$(<"$min_file")
        fi
        if [[ -r "$max_file" ]]; then
            fan_max=$(<"$max_file")
        fi

        CONFIG_FAN_MIN_VALUES+=("$fan_min")
        CONFIG_FAN_MAX_VALUES+=("$fan_max")
        echo "  ℹ️  Detected fan $(basename "$fan_path") range min=${fan_min} max=${fan_max}"
    done
    echo "  ℹ️  Total fans detected: ${#CONFIG_FAN_RPM_FILES[@]}"
else
    echo "  ℹ️  No RPM sensors detected via dell_smm_hwmon. Fan list will remain empty."
fi

shopt -u nullglob

# === 2. STOP SERVICE ===
echo ""
echo "⏹️ Step 2 – Pausing the fan_control service"
echo "--------------------------------------------"
systemctl stop fan_control.service 2>/dev/null
echo "  ✅ fan_control.service stopped temporarily."

# === 3. USER CONFIGURATION (MAX & CRITICAL) ===
echo ""
echo "⚙️ Step 3 – Temperature Targets"
echo "--------------------------------"
echo "We will capture the ramp point and emergency ceiling for your system."

# MAX_TEMP Input
while true; do
    read -p "  🌡️  Enter MAX_TEMP (fan ramps aggressively at this temp, rec 60-70) [65]: " input_max
    input_max=${input_max:-65}
    if [[ "$input_max" =~ ^[0-9]+$ ]] && (( input_max > 40 && input_max < 90 )); then
        USER_MAX_TEMP=$input_max
        break
    else
    echo "  ❌ Invalid. Pick a number between 40 and 90."
    fi
done

# CRITICAL_TEMP Input
while true; do
    read -p "  🚨 Enter CRITICAL_TEMP (emergency full speed, rec 80-95) [85]: " input_crit
    input_crit=${input_crit:-85}
    if [[ "$input_crit" =~ ^[0-9]+$ ]] && (( input_crit > USER_MAX_TEMP && input_crit <= 105 )); then
        USER_CRITICAL_TEMP=$input_crit
        break
    else
    echo "  ❌ Invalid. Must be > MAX_TEMP ($USER_MAX_TEMP) and ≤ 105."
    fi
done
echo "--> Settings accepted: MAX=$USER_MAX_TEMP°C, CRITICAL=$USER_CRITICAL_TEMP°C"

# === 4. IDLE TEMP MEASUREMENT ===
echo ""
echo "🧊 Step 4 – Idle Temperature Measurement"
echo "----------------------------------------"
echo "Ensure nothing demanding is running. This samples your quiet idle temp."
echo "Close browsers, terminals, or anything that could spike heat."
read -p "Press [Enter] once your system is idle..."

echo "Cooling down fan to safe level (PWM 128) and measuring..."
echo "128" > "$SET_FAN_SPEED_FILE"
sleep 5

total_temp=0
samples=5
echo "Taking $samples samples..."

for ((i=1; i<=samples; i++)); do
    read -r raw_temp < "$GET_CPU_TEMP_FILE"
    temp=$((raw_temp / 1000))
    echo "    Sample $i: $temp°C"
    total_temp=$((total_temp + temp))
    sleep 2
done

avg_temp=$((total_temp / samples))
echo "--> Average Idle Temp: $avg_temp°C"

# Calculate recommended MIN_TEMP (Idle + 5 degrees buffer)
rec_min_temp=$((avg_temp + 5))
if (( rec_min_temp < 30 )); then rec_min_temp=30; fi # Floor at 30

# Validate MIN vs MAX
if (( rec_min_temp >= USER_MAX_TEMP - 10 )); then
    echo "WARNING: Idle temp is very close to MAX_TEMP."
    echo "Adjusting MAX_TEMP to $((rec_min_temp + 15))°C to ensure proper curve."
    USER_MAX_TEMP=$((rec_min_temp + 15))
    if (( USER_CRITICAL_TEMP <= USER_MAX_TEMP )); then
         USER_CRITICAL_TEMP=$((USER_MAX_TEMP + 10))
    fi
    echo "New Limits: MAX=$USER_MAX_TEMP°C, CRIT=$USER_CRITICAL_TEMP°C"
fi

# === 5. RPM/NOISE PROFILING ===
echo ""
echo "🎧 Step 5 – RPM & Noise Profiling"
echo "----------------------------------"
echo "We will increase the fan PWM in stages while you listen for noise thresholds."
echo "Tell us when the fan becomes too loud; otherwise press Enter to continue."
echo "Ctrl+C cancels the process safely at any time."
echo ""

# Reset to min
echo "Resetting fan to minimum..."
echo "0" > "$SET_FAN_SPEED_FILE"
sleep 3

found_limit=false
limit_pwm=255
limit_rpm=0

# Header
printf "%-10s | %-10s | %-20s\n" "PWM (0-255)" "RPM" "Status"
echo "--------------------------------------------------"

for pwm in {60..255..15}; do
    echo "$pwm" > "$SET_FAN_SPEED_FILE"
    
    # Wait for spin up
    sleep 4 

    rpm="N/A"
    if [[ -n "$GET_FAN_RPM_FILE" ]]; then
        read -r rpm < "$GET_FAN_RPM_FILE"
    fi

    printf "%-10s | %-10s | Listening...\n" "$pwm" "$rpm"

    while true; do
    read -r -p "    Is this too noisy? (y/n/Enter=no): " user_input
        user_input=${user_input:-n}

        if [[ "$user_input" =~ ^[yY]$ ]]; then
            echo "--> Threshold found at PWM $pwm (~$rpm RPM)"
            limit_pwm=$((pwm - 15)) # Set limit to previous step
            limit_rpm=$rpm
            found_limit=true
            break 2
        elif [[ "$user_input" =~ ^[nN]$ ]]; then
            echo "--> Noted. Advancing to the next step..."
            break
        else
            echo "    Please answer 'y' or 'n'."
        fi
    done
done

if [ "$found_limit" = false ]; then
    echo "--> Max speed reached without 'noisy' report."
    limit_pwm=255
fi

# === 6. GENERATE CONFIG ===
echo ""
echo "✅ Calibration Complete"
echo "------------------------"
echo "Summary of the detected curve:"
echo "  🧊 Idle Temp:          $avg_temp°C → MIN_TEMP: $rec_min_temp°C"
echo "  🚀 Max Temp:           $USER_MAX_TEMP°C"
echo "  🚨 Critical Temp:      $USER_CRITICAL_TEMP°C"
echo "  🔇 Quiet Limit PWM:    $limit_pwm (≈ $limit_rpm RPM)"
echo ""
read -p "Would you like to save this configuration? (y/n): " save_opt

if [[ "$save_opt" == "y" || "$save_opt" == "Y" ]]; then
    {
        cat <<EOF
# /etc/fan_control.conf
# Generated on $(date)

# Energy profile: "balanced" or "performance"
PROFILE="balanced"

# Temperature Thresholds
MIN_TEMP=$rec_min_temp
MAX_TEMP=$USER_MAX_TEMP
CRITICAL_TEMP=$USER_CRITICAL_TEMP

# PWM Limits
MIN_PWM=60
MAX_PWM=255

# Custom Tuning
# The PWM value where noise becomes annoying (detected during calibration)
# Used by the 'balanced' profile as a soft limit.
QUIET_MAX_PWM=$limit_pwm

# Fan configuration detected during calibration
CONFIG_FAN_RPM_FILES=(
EOF
        if (( ${#CONFIG_FAN_RPM_FILES[@]} > 0 )); then
            for path in "${CONFIG_FAN_RPM_FILES[@]}"; do
                printf '    "%s"\n' "$path"
            done
        fi
        cat <<EOF
)
CONFIG_FAN_MIN_VALUES=(
EOF
        if (( ${#CONFIG_FAN_MIN_VALUES[@]} > 0 )); then
            for val in "${CONFIG_FAN_MIN_VALUES[@]}"; do
                printf '    "%s"\n' "$val"
            done
        fi
        cat <<EOF
)
CONFIG_FAN_MAX_VALUES=(
EOF
        if (( ${#CONFIG_FAN_MAX_VALUES[@]} > 0 )); then
            for val in "${CONFIG_FAN_MAX_VALUES[@]}"; do
                printf '    "%s"\n' "$val"
            done
        fi
        cat <<EOF
)

# Advanced
TEMP_HYSTERESIS=2
SLEW_RATE_LIMIT=15
EOF
    } > /etc/fan_control.conf
    echo "  💾 Configuration saved to /etc/fan_control.conf"
    echo "  🔁 Restarting fan_control.service..."
    systemctl start fan_control.service
    echo "  ✅ Service restarted."
else
    echo "  ❌ Changes discarded."
    echo "  🔁 Restarting fan_control.service with previous settings..."
    systemctl start fan_control.service
fi
