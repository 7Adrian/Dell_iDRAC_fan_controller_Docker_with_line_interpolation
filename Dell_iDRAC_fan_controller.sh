#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGQUIT SIGTERM

# Prepare, format and define initial variables

# readonly DELL_FRESH_AIR_COMPLIANCE=45

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ $FAN_SPEED == 0x* ]]
then
  readonly DECIMAL_FAN_SPEED=$(printf '%d' $FAN_SPEED)
  readonly HEXADECIMAL_FAN_SPEED=$FAN_SPEED
else
  readonly DECIMAL_FAN_SPEED=$FAN_SPEED
  readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal $FAN_SPEED)
fi

# Check if fan speed interpolation is enabled
if [ -z "$HIGH_FAN_SPEED" ] || [ -z "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ]
then
  readonly FAN_SPEED_INTERPOLATION_ENABLED=false
else
  readonly FAN_SPEED_INTERPOLATION_ENABLED=true

  # Check if HIGH_FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
  if [[ $HIGH_FAN_SPEED == 0x* ]]
  then
    readonly DECIMAL_HIGH_FAN_SPEED=$(printf '%d' $HIGH_FAN_SPEED)
    readonly HEXADECIMAL_HIGH_FAN_SPEED=$HIGH_FAN_SPEED
  else
    readonly DECIMAL_HIGH_FAN_SPEED=$HIGH_FAN_SPEED
    readonly HEXADECIMAL_HIGH_FAN_SPEED=$(convert_decimal_value_to_hexadecimal $HIGH_FAN_SPEED)
  fi
fi

# Check if the iDRAC host is set to 'local' or not then set the IDRAC_LOGIN_STRING accordingly
if [[ $IDRAC_HOST == "local" ]]
then
  # Check that the Docker host IPMI device (the iDRAC) has been exposed to the Docker container
  if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
    echo "/!\ Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode. Exiting." >&2
    exit 1
  fi
  IDRAC_LOGIN_STRING='open'
else
  echo "iDRAC/IPMI username: $IDRAC_USERNAME"
  echo "iDRAC/IPMI password: $IDRAC_PASSWORD"
  IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]
then
  echo "/!\ Your server isn't a Dell product. Exiting." >&2
  exit 1
fi

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the fan speed objective, CPU temperature threshold and check interval
echo "Fan speed interpolation enabled: $FAN_SPEED_INTERPOLATION_ENABLED"
if $FAN_SPEED_INTERPOLATION_ENABLED
then
  echo "Fan speed lower value: $DECIMAL_FAN_SPEED%"
  echo "Fan speed higher value: $DECIMAL_HIGH_FAN_SPEED%"
  echo "CPU lower temperature threshold: $CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION°C"
  echo "CPU higher temperature threshold: $CPU_TEMPERATURE_THRESHOLD°C"
else
  echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
  echo "CPU temperature threshold: $CPU_TEMPERATURE_THRESHOLD°C"
fi
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

# Define the interval for printing
readonly TABLE_HEADER_PRINT_INTERVAL=10
i=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
IS_DELL_FAN_CONTROL_PROFILE_APPLIED=true

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true
retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
if [ -z "$EXHAUST_TEMPERATURE" ]
then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
if [ -z "$CPU2_TEMPERATURE" ]
then
  echo "No CPU2 temperature sensor detected."
  IS_CPU2_TEMPERATURE_SENSOR_PRESENT=false
fi
# Output new line to beautify output if one of the previous conditions have echoed
if ! $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT || ! $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
then
  echo ""
fi

# Start monitoring
while true; do
  # Sleep for the specified interval before taking another reading
  sleep $CHECK_INTERVAL &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT

  # Define functions to check if CPU 1 and CPU 2 temperatures are above the threshold
  function CPU1_OVERHEAT () { [ $CPU1_TEMPERATURE -gt $CPU_TEMPERATURE_THRESHOLD ]; }
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
  then
    function CPU2_OVERHEAT () { [ $CPU2_TEMPERATURE -gt $CPU_TEMPERATURE_THRESHOLD ]; }
  fi

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # Check if CPU 1 is overheating then apply Dell default dynamic fan control profile if true
  if CPU1_OVERHEAT
  then
    apply_Dell_fan_control_profile

    if ! $IS_DELL_FAN_CONTROL_PROFILE_APPLIED
    then
      IS_DELL_FAN_CONTROL_PROFILE_APPLIED=true

      # If CPU 2 temperature sensor is present, check if it is overheating too.
      # Do not apply Dell default dynamic fan control profile as it has already been applied before
      if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEAT
      then
        COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
      else
        COMMENT="CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
      fi
    fi
  # If CPU 2 temperature sensor is present, check if it is overheating then apply Dell default dynamic fan control profile if true
  elif $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEAT
  then
    apply_Dell_fan_control_profile

    if ! $IS_DELL_FAN_CONTROL_PROFILE_APPLIED
    then
      IS_DELL_FAN_CONTROL_PROFILE_APPLIED=true
      COMMENT="CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
    fi
  elif $FAN_SPEED_INTERPOLATION_ENABLED
  then
    HIGHEST_CPU_TEMPERATURE=$CPU1_TEMPERATURE
    if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
    then
      if [ $CPU2_TEMPERATURE -gt $CPU1_TEMPERATURE ];
      then
        HIGHEST_CPU_TEMPERATURE=$CPU2_TEMPERATURE
      fi
    fi

    if [ $HIGHEST_CPU_TEMPERATURE -gt $CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION ];
    then
      #
      # F1 - lower fan speed
      # F2 - higher fan speed
      # T_CPU - highest temperature of both CPUs (if only one exists that will be CPU1 temp value)
      # T1 - lower temperature threshold
      # T2 - higher temperature threshold
      # Fan speed = F1 + ( ( F2 - F1 ) * ( T_CPU - T1 ) / ( T2 - T1 ) )
      #
      # Temperature interpolation activation range
      TEMPERATURE_INTERPOLATION_ACTIVATION_RANGE=$((CPU_TEMPERATURE_THRESHOLD - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION))
      FAN_VALUE_TO_ADD=0
      # Check if TEMPERATURE_INTERPOLATION_ACTIVATION_RANGE is > 0
      if [ $TEMPERATURE_INTERPOLATION_ACTIVATION_RANGE -gt $FAN_VALUE_TO_ADD ];
      then
        # Temperature above lower value
        TEMPERATURE_ABOVE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=$((HIGHEST_CPU_TEMPERATURE - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION))
        # Difference between higher and lower fan speed
        FAN_WINDOW=$((DECIMAL_HIGH_FAN_SPEED - DECIMAL_FAN_SPEED))
        FAN_VALUE_TO_ADD=$((FAN_WINDOW * TEMPERATURE_ABOVE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION / TEMPERATURE_INTERPOLATION_ACTIVATION_RANGE))
      fi
      DECIMAL_CURRENT_FAN_SPEED=$((DECIMAL_FAN_SPEED + FAN_VALUE_TO_ADD))
    else
      DECIMAL_CURRENT_FAN_SPEED=$DECIMAL_FAN_SPEED
    fi
    HEXADECIMAL_CURRENT_FAN_SPEED=$(convert_decimal_value_to_hexadecimal $DECIMAL_CURRENT_FAN_SPEED)
    apply_user_fan_control_profile_with_interpolation
  else
    apply_user_fan_control_profile

    # Check if user fan control profile is applied then apply it if not
    if $IS_DELL_FAN_CONTROL_PROFILE_APPLIED
    then
      IS_DELL_FAN_CONTROL_PROFILE_APPLIED=false
      COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
    fi
  fi

  # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
  # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
  if $DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE
  then
    disable_third_party_PCIe_card_Dell_default_cooling_response
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
  else
    enable_third_party_PCIe_card_Dell_default_cooling_response
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $i -eq $TABLE_HEADER_PRINT_INTERVAL ]
  then
    echo "                     ------- Temperatures -------"
    echo "    Date & time      Inlet  CPU 1  CPU 2  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"
    i=0
  fi
  printf "%19s  %3d°C  %3d°C  %3s°C  %5s°C  %40s  %51s  %s\n" "$(date +"%d-%m-%Y %T")" $INLET_TEMPERATURE $CPU1_TEMPERATURE "$CPU2_TEMPERATURE" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((i++))
  wait $SLEEP_PROCESS_PID
done
