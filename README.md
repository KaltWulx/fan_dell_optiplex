# Dell Optiplex Intelligent Fan Control

**This tool** is a sophisticated Bash-based daemon designed to take control of the system fan on Dell Optiplex machines (and other hardware using the `dell_smm_hwmon` driver). It replaces the often aggressive or unresponsive BIOS fan curves with a smooth, physics-based control algorithm.

## 🎯 Objective

The primary goal is to achieve **silence** during normal operation without compromising **performance** or **safety**. 

Unlike simple linear scripts, this controller uses advanced control theory concepts:
*   **Feed-Forward:** Anticipates heat by reading CPU Load before the temperature actually rises.
*   **Derivative Control:** Reacts to the *speed* of temperature change (velocity and acceleration), catching spikes early.
*   **Hysteresis & Smoothing:** Prevents the annoying "revving" sound (hunting) common in BIOS controllers.

## ✨ Features

*   **Dual Profiles:**
    *   **Balanced:** Optimized for silence. Keeps the fan below your noise threshold (calibrated) until temperatures exceed 60°C.
    *   **Performance:** Aggressive cooling that prioritizes thermal headroom over noise, using predictive algorithms.
*   **Smart Calibration:** Includes an interactive tool (`fan_calibration.sh`) to test your specific hardware and hearing tolerance.
    *   During calibration the script enumerates every `dell_smm_hwmon` fan (`fan*_input`) and records each `_min`/`_max` range.
    *   Those findings are serialized into `/etc/fan_control.conf` as the `CONFIG_FAN_...` arrays so the controller knows exactly which sensors to monitor.
*   **Safety First:** Hard-coded critical temperature overrides and fail-safe mechanisms.
*   **Resource Efficient:** Written in pure Bash using built-ins to minimize CPU usage.

## 📋 Requirements

*   **OS:** Linux (Tested on Arch Linux, Kernel 6.17.8).
*   **Hardware:** Tested on Dell OptiPlex 7070 (Intel Core i5-9500).
*   **Kernel Module:** `dell_smm_hwmon` (Standard in most kernels).
*   **Permissions:** Root access (required to write to hardware PWM controls).
*   **Dependencies:** Standard system tools (`bash`, `systemd`, `coreutils`).

## 🚀 Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/KaltWulx/fan_dell_optiplex.git
    cd fan_dell_optiplex
    ```

2.  **Run the installer:**
    ```bash
    chmod +x install.sh
    sudo ./install.sh
    ```

3.  **Follow the on-screen instructions:**
    The installer will ask to run the **Calibration Tool**. It is highly recommended to do so to detect your specific hardware sensors and define your noise tolerance limits.

## ⚙️ Usage

Once installed, the script runs as a systemd service (`fan_control.service`) in the background.

### CLI Commands
You can interact with the script using the installed command `fan-control`:

*   **View Status/Logs:**
    ```bash
    fan-control --log
    ```
*   **Check Configuration:**
    ```bash
    fan-control --help
    ```
*   **Change Profile (Temporary):**
    ```bash
    # Edit /etc/fan_control.conf for permanent changes
    sudo systemctl restart fan_control.service
    ```

### Calibration
To re-run the calibration tool at any time:
```bash
sudo fan-calibrate
```

### Configuration File
Located at `/etc/fan_control.conf`. You can edit this file to tweak settings manually. The calibration tool also writes the detected fan devices and their `_min/_max` readings into `CONFIG_FAN_RPM_FILES`, `CONFIG_FAN_MIN_VALUES`, and `CONFIG_FAN_MAX_VALUES`, which `fan_control.sh` consumes when it starts, ensuring the daemon always knows which sensors to monitor.

```bash
PROFILE="balanced"      # "balanced" or "performance"
MIN_TEMP=35              # Fan starts ramping up here
MAX_TEMP=65              # Fan reaches high speed here
QUIET_MAX_PWM=165        # Max PWM for "Quiet" zone in Balanced mode
```

## 🗑️ Uninstallation

To remove the fan control from your system completely, simply run:

```bash
sudo fan-control uninstall
```

This command will:
*   Stop and remove the systemd service.
*   Remove all installed files and configurations.
*   Clean up symlinks (`fan-control`, `fan-calibrate`).

## ⚠️ Disclaimer

This software controls hardware cooling. While it includes safety features, **use it at your own risk**. The author is not responsible for overheating or hardware damage caused by improper configuration or usage.
