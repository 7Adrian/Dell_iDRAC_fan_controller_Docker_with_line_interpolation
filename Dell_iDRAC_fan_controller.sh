#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# Prepare, format and define initial variables

# readonly DELL_FRESH_AIR_COMPLIANCE=45

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ $FAN_SPEED == 0x* ]]; then
  readonly DECIMAL_LOW_FAN_SPEED_OBJECTIVE=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  # Unused
  # readonly HEXADECIMAL_FAN_SPEED=$FAN_SPEED
else
  readonly DECIMAL_LOW_FAN_SPEED_OBJECTIVE=$FAN_SPEED
  # Unused
  # readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

# Check if fan speed interpolation is enabled
if [ -z "$HIGH_FAN_SPEED" ] || [ -z "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ] || [ "$CPU_TEMPERATURE_THRESHOLD" -eq "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ]; then
  readonly FAN_SPEED_INTERPOLATION_ENABLED=false
  
  # We define these variables to the same values than user fan control profile
  readonly HIGH_FAN_SPEED=$FAN_SPEED
  readonly CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=$CPU_TEMPERATURE_THRESHOLD
elif [[ "$FAN_SPEED" -gt "$HIGH_FAN_SPEED" ]]; then
  echo 'Error : $FAN_SPEED have to be less or equal to $HIGH_FAN_SPEED. Exiting.'
  exit 1
else
  readonly FAN_SPEED_INTERPOLATION_ENABLED=true
fi

# Check if HIGH_FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ $HIGH_FAN_SPEED == 0x* ]]; then
  readonly DECIMAL_HIGH_FAN_SPEED_OBJECTIVE=$(convert_hexadecimal_value_to_decimal "$HIGH_FAN_SPEED")
  # Unused
  # readonly HEXADECIMAL_HIGH_FAN_SPEED=$HIGH_FAN_SPEED
else
  readonly DECIMAL_HIGH_FAN_SPEED_OBJECTIVE=$HIGH_FAN_SPEED
  # Unused
  # readonly HEXADECIMAL_HIGH_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$HIGH_FAN_SPEED")
fi

# Check if the iDRAC host is set to 'local' or not then set the IDRAC_LOGIN_STRING accordingly
if [[ $IDRAC_HOST == "local" ]]; then
  # Check that the Docker host IPMI device (the iDRAC) has been exposed to the Docker container
  if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
    print_error_and_exit "Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode"
  fi
  IDRAC_LOGIN_STRING='open'
else
  echo "iDRAC/IPMI username: $IDRAC_USERNAME"
  #echo "iDRAC/IPMI password: $IDRAC_PASSWORD"
  IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# If server model is Gen 14 (*40) or newer
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=true
  readonly CPU1_TEMPERATURE_INDEX=2
  readonly CPU2_TEMPERATURE_INDEX=4
else
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=false
  readonly CPU1_TEMPERATURE_INDEX=1
  readonly CPU2_TEMPERATURE_INDEX=2
fi

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the check interval, fan speed objective and CPU temperature threshold
echo "Check interval: ${CHECK_INTERVAL}s"
echo "Fan speed interpolation enabled: $FAN_SPEED_INTERPOLATION_ENABLED"
if $FAN_SPEED_INTERPOLATION_ENABLED; then
  echo "Fan speed lower value: $DECIMAL_LOW_FAN_SPEED_OBJECTIVE%"
  echo "Fan speed higher value: $DECIMAL_HIGH_FAN_SPEED_OBJECTIVE%"
  echo "CPU lower temperature threshold: $CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION°C"
  echo "CPU higher temperature threshold: $CPU_TEMPERATURE_THRESHOLD°C"
  echo ""
  # Print interpolated fan speeds for demonstration
  print_interpolated_fan_speeds "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" "$CPU_TEMPERATURE_THRESHOLD" "$DECIMAL_LOW_FAN_SPEED_OBJECTIVE" "$DECIMAL_HIGH_FAN_SPEED_OBJECTIVE"
else
  echo "Fan speed objective: $DECIMAL_LOW_FAN_SPEED_OBJECTIVE%"
  echo "CPU temperature threshold: $CPU_TEMPERATURE_THRESHOLD°C"
fi
echo ""

# Initialize temperature table header print counter
TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
CURRENTLY_APPLIED_PROFILE_ID=$DELL_DEFAULT_FAN_CONTROL_PROFILE_ID

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true
retrieve_temperatures "$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT" "$IS_CPU2_TEMPERATURE_SENSOR_PRESENT"
if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
if [ -z "$CPU2_TEMPERATURE" ]; then
  echo "No CPU2 temperature sensor detected."
  IS_CPU2_TEMPERATURE_SENSOR_PRESENT=false
fi
# Output new line to beautify output if one of the previous conditions have echoed
if ! $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT || ! $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
  echo ""
fi

#readonly NUMBER_OF_DETECTED_CPUS=(${CPUS_TEMPERATURES//;/ })
# TODO : write "X CPU sensors detected." and remove previous ifs
readonly HEADER=$(build_header $NUMBER_OF_DETECTED_CPUS)

# Start monitoring
while true; do
  # Sleep for the specified interval before taking another reading
  sleep $CHECK_INTERVAL &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures "$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT" "$IS_CPU2_TEMPERATURE_SENSOR_PRESENT"

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  OVERHEATING_CPUs=$(get_overheating_CPUs $CPU_TEMPERATURE_THRESHOLD $CPUS_TEMPERATURES)
  # Creating an array from the string
  OVERHEATING_CPUS_ARRAY=(${OVERHEATING_CPUs//;/ })
  NUMBER_OF_OVERHEATING_CPUS=${#OVERHEATING_CPUS_ARRAY[@]}
  # If CPUs are overheating then apply Dell default dynamic fan control profile
  if (( NUMBER_OF_OVERHEATING_CPUS > 0 )); then
    apply_Dell_default_fan_control_profile

    if (( CURRENTLY_APPLIED_PROFILE_ID != DELL_DEFAULT_FAN_CONTROL_PROFILE_ID )); then
      CURRENTLY_APPLIED_PROFILE_ID=$DELL_DEFAULT_FAN_CONTROL_PROFILE_ID
      COMMENT=$(redact_comment $CURRENTLY_APPLIED_PROFILE_ID "$OVERHEATING_CPUs")
    fi
  else
    HEATING_CPUs=$(get_overheating_CPUs $CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION $CPUS_TEMPERATURES)
    # Creating an array from the string
    HEATING_CPUS_ARRAY=(${HEATING_CPUs//;/ })
    NUMBER_OF_HEATING_CPUS=${#HEATING_CPUS_ARRAY[@]}
    # If CPUs are heating then apply interpolated user's fan control profile
    if (( NUMBER_OF_HEATING_CPUS > 0 )); then
      # Apply interpolated user fan control profile
      DECIMAL_FAN_SPEED_TO_APPLY=$(calculate_interpolated_fan_speed $DECIMAL_LOW_FAN_SPEED_OBJECTIVE $DECIMAL_HIGH_FAN_SPEED_OBJECTIVE $HIGHEST_CPU_TEMPERATURE $CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION $CPU_TEMPERATURE_THRESHOLD)
      apply_user_fan_control_profile $INTERPOLATED_USER_FAN_CONTROL_PROFILE_ID $DECIMAL_FAN_SPEED_TO_APPLY

      if (( CURRENTLY_APPLIED_PROFILE_ID != INTERPOLATED_USER_FAN_CONTROL_PROFILE_ID )); then
        # TODO : include the apply in this if
        CURRENTLY_APPLIED_PROFILE_ID=$INTERPOLATED_USER_FAN_CONTROL_PROFILE_ID
        COMMENT=$(redact_comment $CURRENTLY_APPLIED_PROFILE_ID "$HEATING_CPUs")
      fi
    else
      # Apply classic user fan control profile
      apply_user_fan_control_profile $CLASSIC_USER_FAN_CONTROL_PROFILE_ID $DECIMAL_LOW_FAN_SPEED_OBJECTIVE

      if (( CURRENTLY_APPLIED_PROFILE_ID != CLASSIC_USER_FAN_CONTROL_PROFILE_ID )); then
        # TODO : include the apply in this if
        CURRENTLY_APPLIED_PROFILE_ID=$CLASSIC_USER_FAN_CONTROL_PROFILE_ID
        COMMENT=$(redact_comment $CURRENTLY_APPLIED_PROFILE_ID $NUMBER_OF_HEATING_CPUS $CPU_TEMPERATURE_THRESHOLD)
      fi
    fi
  fi

  # If server model is not Gen 14 (*40) or newer
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER; then
    # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
    # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
    if $DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE; then
      disable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
    fi
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    print_header "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))
  wait $SLEEP_PROCESS_PID
done
