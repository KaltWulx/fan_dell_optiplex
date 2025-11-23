#!/bin/bash

# fan_calibration.sh
# Tool to calibrate PWM/RPM curve and generate configuration for fan_control.sh
# Author: KaltWulx

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

echo "=================================================="
echo "   Dell Optiplex Fan Control - Calibration Tool   "
echo "=================================================="
echo "This tool will:"
echo "1. Stop the fan_control service."
echo "2. Ask for your preferred temperature limits."
echo "3. Measure idle temperature (System must be idle!)."
echo "4. Test fan speeds to find your noise tolerance."
echo "5. Generate a recommended configuration file."
echo ""
read -p "Press [Enter] to start..."

# === 1. HARDWARE DETECTION ===
echo "--> Detecting hardware..."

# Enable nullglob
shopt -s nullglob

# Find Temp Sensor
temp_candidates=(/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input)
if (( ${#temp_candidates[@]} == 0 )); then
    echo "Error: CPU Temperature sensor not found."
    exit 1
fi
GET_CPU_TEMP_FILE="${temp_candidates[0]}"
echo "    CPU Temp Sensor: Found"

# Find PWM and Fan Inputs
pwm_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/pwm1)
fan_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/fan1_input)

if (( ${#pwm_candidates[@]} == 0 )); then
    echo "    PWM Control: Not found. Attempting module reload..."
    modprobe -r dell_smm_hwmon 2>/dev/null
    sleep 2
    modprobe dell_smm_hwmon force=1 restricted=0 2>/dev/null
    sleep 2
    pwm_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/pwm1)
    fan_candidates=(/sys/devices/platform/dell_smm_hwmon/hwmon/hwmon*/fan1_input)
fi

if (( ${#pwm_candidates[@]} > 0 )); then
    SET_FAN_SPEED_FILE="${pwm_candidates[0]}"
    echo "    PWM Control: Found ($SET_FAN_SPEED_FILE)"
else
    echo "Error: Could not enable PWM control. Check BIOS settings."
    exit 1
fi

if (( ${#fan_candidates[@]} > 0 )); then
    GET_FAN_RPM_FILE="${fan_candidates[0]}"
    echo "    RPM Sensor: Found ($GET_FAN_RPM_FILE)"
else
    echo "Warning: RPM sensor not found. Calibration will rely on PWM values only."
fi

shopt -u nullglob

# === 2. STOP SERVICE ===
echo ""
echo "--> Stopping existing fan service..."
systemctl stop fan_control.service 2>/dev/null
echo "    Service stopped."

# === 3. USER CONFIGURATION (MAX & CRITICAL) ===
echo ""
echo "=================================================="
echo "           PHASE 1: CONFIGURATION                 "
echo "=================================================="
echo "Please define your temperature limits."

# MAX_TEMP Input
while true; do
    read -p "Enter MAX_TEMP (Temp where fan hits high speed, rec: 60-70) [65]: " input_max
    input_max=${input_max:-65}
    if [[ "$input_max" =~ ^[0-9]+$ ]] && (( input_max > 40 && input_max < 90 )); then
        USER_MAX_TEMP=$input_max
        break
    else
        echo "Invalid value. Please enter a number between 40 and 90."
    fi
done

# CRITICAL_TEMP Input
while true; do
    read -p "Enter CRITICAL_TEMP (Emergency full speed, rec: 80-95) [85]: " input_crit
    input_crit=${input_crit:-85}
    if [[ "$input_crit" =~ ^[0-9]+$ ]] && (( input_crit > USER_MAX_TEMP && input_crit <= 105 )); then
        USER_CRITICAL_TEMP=$input_crit
        break
    else
        echo "Invalid value. Must be higher than MAX_TEMP ($USER_MAX_TEMP) and <= 105."
    fi
done
echo "--> Settings accepted: MAX=$USER_MAX_TEMP°C, CRITICAL=$USER_CRITICAL_TEMP°C"

# === 4. IDLE TEMP MEASUREMENT ===
echo ""
echo "=================================================="
echo "           PHASE 2: IDLE TEMPERATURE              "
echo "=================================================="
echo "IMPORTANT: Please ensure your system is IDLE."
echo "Close heavy applications (browsers, games, compilation)."
echo "We will measure the baseline temperature to set MIN_TEMP."
read -p "Press [Enter] when the system is idle..."

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
echo "=================================================="
echo "           PHASE 3: NOISE CALIBRATION             "
echo "=================================================="
echo "The fan will speed up in steps."
echo "Please listen carefully to the fan noise."
echo "Press [Ctrl+C] at any time to abort safely."
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
            echo "--> Noted. Waiting for you to be ready for the next step..."
            read -r -p "    Press [Enter] to continue..." _
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
echo "=================================================="
echo "           CALIBRATION COMPLETE                   "
echo "=================================================="
echo "Summary:"
echo "- Idle Temp:   $avg_temp°C  -> MIN_TEMP: $rec_min_temp°C"
echo "- Max Temp:    $USER_MAX_TEMP°C"
echo "- Crit Temp:   $USER_CRITICAL_TEMP°C"
echo "- Quiet Limit: PWM $limit_pwm (approx $limit_rpm RPM)"
echo ""
read -p "Do you want to save this configuration? (y/n): " save_opt

if [[ "$save_opt" == "y" || "$save_opt" == "Y" ]]; then
    cat <<EOF > /etc/fan_control.conf
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

# Advanced
TEMP_HYSTERESIS=2
SLEW_RATE_LIMIT=15
EOF
    echo "Configuration saved to /etc/fan_control.conf"
    echo "Restarting service..."
    systemctl start fan_control.service
    echo "Done!"
else
    echo "Configuration NOT saved."
    echo "Restarting service with old config..."
    systemctl start fan_control.service
fi
