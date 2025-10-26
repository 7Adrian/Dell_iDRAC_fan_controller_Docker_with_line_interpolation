# Define global functions
# This function applies Dell's default dynamic fan control profile
function apply_Dell_default_fan_control_profile() {
  # Use ipmitool to send the raw command to set fan control to Dell default
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# Apply user-defined fan control settings
#
# This function applies user-defined fan control settings based on the specified mode and fan speed.
# It handles both decimal and hexadecimal fan speed inputs, converting between them as needed.
# The function then applies the fan control and updates the current fan control profile.
#
# Parameters:
#   $1 (FAN_CONTROL_PROFILE): The fan control mode.
#                             1 for static fan speed, 2 for dynamic (interpolated) fan control.
#   $2 (LOCAL_FAN_SPEED): The desired fan speed. Can be in decimal (0-100) or hexadecimal (0x00-0x64) format.
#
# Global variables used:
#   CURRENT_FAN_CONTROL_PROFILE: Updated with the current fan control profile description.
#
# Returns:
#   None. In case of an invalid mode, it calls graceful_exit().
function apply_user_fan_control_profile() {
  local FAN_CONTROL_PROFILE=$1
  local LOCAL_FAN_SPEED=$2
  # TODO Tigerblue77 : change in apply_fan_control_profile and include Dell default fan control profile as case 3 ?
  # TODO Tigerblue77 : add column % and set comment on profile change (store current_applied_profile as 1 / 2 / 3)
  # TODO Tigerblue77 : check and improve startup graph + show it even if not in interpolated mode
  # TODO Tigerblue77 : set all local variables to lowercase
  if [[ $LOCAL_FAN_SPEED == 0x* ]]; then
    local LOCAL_DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$LOCAL_FAN_SPEED")
    local LOCAL_HEXADECIMAL_FAN_SPEED=$LOCAL_FAN_SPEED
  else
    local LOCAL_DECIMAL_FAN_SPEED=$LOCAL_FAN_SPEED
    local LOCAL_HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$LOCAL_FAN_SPEED")
  fi

  case $FAN_CONTROL_PROFILE in
    1)
      set_fans_speed "$LOCAL_HEXADECIMAL_FAN_SPEED"
      CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($LOCAL_DECIMAL_FAN_SPEED%)"
      ;;
    2)
      set_fans_speed "$LOCAL_HEXADECIMAL_FAN_SPEED"
      CURRENT_FAN_CONTROL_PROFILE="Interpolated fan control profile ($LOCAL_DECIMAL_FAN_SPEED%)"
      ;;
    *)
      echo "Invalid mode selected. Please use 1 for static fan speed or 2 for dynamic fan control."
      graceful_exit
      ;;
  esac
}

# Set fans speed to a specified value
#
# This function sets the fan speed to a specific value using ipmitool.
# It first checks if the input value is in hexadecimal format, and converts it
# if necessary. Then it sends raw commands to iDRAC to set the fan control.
#
# Parameters:
#   $1 (VALUE): The desired fan speed value. Can be in decimal or hexadecimal format.
#               If in decimal, it will be converted to hexadecimal.
#
# Returns:
#   None
#
# Note:
#   This function uses the global variable $IDRAC_LOGIN_STRING for iDRAC login.
function set_fans_speed() {
  local HEXADECIMAL_FAN_SPEED_TO_APPLY=$1

  # Check if the input value is a hexadecimal number, if not, convert it to hexadecimal
  if [[ $HEXADECIMAL_FAN_SPEED_TO_APPLY != 0x* ]]; then
    HEXADECIMAL_FAN_SPEED_TO_APPLY=$(convert_decimal_value_to_hexadecimal "$HEXADECIMAL_FAN_SPEED_TO_APPLY")
  fi

  # Enable manual fan control
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
  # Set fans speed to a specific value
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff "$HEXADECIMAL_FAN_SPEED_TO_APPLY" > /dev/null
}

# Convert first parameter given ($DECIMAL_NUMBER) to hexadecimal
# Usage : convert_decimal_value_to_hexadecimal "$DECIMAL_NUMBER"
# Returns : hexadecimal value of DECIMAL_NUMBER
function convert_decimal_value_to_hexadecimal() {
  local -r DECIMAL_NUMBER=$1
  local -r HEXADECIMAL_NUMBER=$(printf '0x%02x' $DECIMAL_NUMBER)
  echo $HEXADECIMAL_NUMBER
}

# Convert first parameter given ($HEXADECIMAL_NUMBER) to decimal
# Usage : convert_hexadecimal_value_to_decimal "$HEXADECIMAL_NUMBER"
# Returns : decimal value of HEXADECIMAL_NUMBER
function convert_hexadecimal_value_to_decimal() {
  local -r HEXADECIMAL_NUMBER=$1
  local -r DECIMAL_NUMBER=$(printf '%d' $HEXADECIMAL_NUMBER)
  echo $DECIMAL_NUMBER
}

# Set the IDRAC_LOGIN_STRING variable based on connection type
# Usage : set_iDRAC_login_string $IDRAC_HOST $IDRAC_USERNAME $IDRAC_PASSWORD
# Returns : IDRAC_LOGIN_STRING
function set_iDRAC_login_string() {
  local IDRAC_LOGIN_STRING=""
  local IDRAC_HOST="$1"
  local IDRAC_USERNAME="$2"
  local IDRAC_PASSWORD="$3"
  # Check if the iDRAC host is set to 'local' or not then set the IDRAC_LOGIN_STRING accordingly
  if [[ "$IDRAC_HOST" == "local" ]]; then
    # Check that the Docker host IPMI device (the iDRAC) has been exposed to the Docker container
    if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
      print_error_and_exit "Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode"
    fi
    IDRAC_LOGIN_STRING='open'
  else
    echo "iDRAC/IPMI username: \"$IDRAC_USERNAME\""
    #echo "iDRAC/IPMI password: \"$IDRAC_PASSWORD\""
    IDRAC_LOGIN_STRING="lanplus -H \"$IDRAC_HOST\" -U \"$IDRAC_USERNAME\" -P \"$IDRAC_PASSWORD\""
  fi
  echo $IDRAC_LOGIN_STRING
}

# Retrieve temperature sensors data using ipmitool
# Usage : retrieve_temperatures "$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT" "$IS_CPU2_TEMPERATURE_SENSOR_PRESENT"
# Globally sets :
# - $INLET_TEMPERATURE
# - $CPU1_TEMPERATURE
# - $CPU2_TEMPERATURE if sensor is present
# - $EXHAUST_TEMPERATURE if sensor is present
function retrieve_temperatures() {
  if (( $# != 2 )); then
    print_error "Illegal number of parameters.\nUsage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT \$IS_CPU2_TEMPERATURE_SENSOR_PRESENT"
    return 1
  fi
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1
  local -r IS_CPU2_TEMPERATURE_SENSOR_PRESENT=$2

  local -r DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature | grep degrees)

  # Parse CPU data
  local -r CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU1_TEMPERATURE_INDEX;}")

  # Initialize CPUS_TEMPERATURES
  CPUS_TEMPERATURES="$CPU1_TEMPERATURE"

  # If CPU2 is present, parse its temperature data and add it to CPUS_TEMPERATURES
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
    CPU2_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU2_TEMPERATURE_INDEX;}")
    CPUS_TEMPERATURES+=";$CPU2_TEMPERATURE" # Ajout avec un ;
  else
    CPU2_TEMPERATURE="-"
  fi

  # Parse inlet temperature data
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  else
    EXHAUST_TEMPERATURE="-"
  fi
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null
}

# Returns :
# - 0 if third-party PCIe card Dell default cooling response is currently DISABLED
# - 1 if third-party PCIe card Dell default cooling response is currently ENABLED
# - 2 if the current status returned by ipmitool command output is unexpected
# function is_third_party_PCIe_card_Dell_default_cooling_response_disabled() {
#   THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00)

#   if [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 01 00 00" ]; then
#     return 0
#   elif [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 00 00 00" ]; then
#     return 1
#   else
#     print_error "Unexpected output: $THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE"
#     return 2
#   fi
# }

# Prepare traps in case of container exit
function graceful_exit() {
  echo "Gracefully exiting as requested..."
  apply_Dell_default_fan_control_profile

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety"
}

# Helps debugging when people are posting their output
function get_Dell_server_model() {
  local -r IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>/dev/null) # FRU stands for "Field Replaceable Unit"

  if [ $? -ne 0 ]; then
    echo "Failed to retrieve iDRAC data, please check IP and credentials." >&2
    return
  fi

  SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | grep "Product Manufacturer" | awk -F ': ' '{print $2}')
  SERVER_MODEL=$(echo "$IPMI_FRU_content" | grep "Product Name" | awk -F ': ' '{print $2}')

  # Check if SERVER_MANUFACTURER is empty, if yes, assign value based on "Board Mfg"
  if [ -z "$SERVER_MANUFACTURER" ]; then
    SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Mfg :" | awk -F ': ' '{print $2}')
  fi

  # Check if SERVER_MODEL is empty, if yes, assign value based on "Board Product"
  if [ -z "$SERVER_MODEL" ]; then
    SERVER_MODEL=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Product :" | awk -F ': ' '{print $2}')
  fi
}

# Print interpolated fan speeds for a range of CPU temperatures
#
# This function generates 10 CPU temperatures between the lower and upper thresholds,
# calculates the corresponding fan speeds using the calculate_interpolated_fan_speed function,
# and displays the results.
#
# Parameters:
#   $1 (CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION): The lower temperature threshold
#   $2 (CPU_TEMPERATURE_THRESHOLD): The upper temperature threshold
#   $3 (LOCAL_DECIMAL_FAN_SPEED): The base fan speed (as a decimal percentage)
#   $4 (LOCAL_DECIMAL_HIGH_FAN_SPEED): The maximum fan speed (as a decimal percentage)
#
# Returns:
#   None (prints the results to stdout)
print_interpolated_fan_speeds() {
  local CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=$1
  local CPU_TEMPERATURE_THRESHOLD=$2
  local LOCAL_DECIMAL_FAN_SPEED=$3
  local LOCAL_DECIMAL_HIGH_FAN_SPEED=$4

  echo -e "\e[1mInterpolated Fan Speeds Chart\e[0m"
  echo "=================================================================="

  local temperature_range=$((CPU_TEMPERATURE_THRESHOLD - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION))
  local step=$((temperature_range / 9))
  local chart_width=50

  # Calculate color thresholds
  local green_threshold=$((CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION + temperature_range * 80 / 100))
  local yellow_threshold=$((CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION + temperature_range * 90 / 100))

  # Print column names
  printf " Temp | Fan  | %-${chart_width}s\n" "Speed"
  printf "======+======+"
  printf '%0.s=' $(seq 1 $((chart_width + 2)))
  printf "\n"

  local highest_CPU_temperature
  local fan_speed
  local bar_length
  local empty_length
  # Print the chart
  for i in {0..9}; do
    if [ $i -eq 9 ]; then
      highest_CPU_temperature="$CPU_TEMPERATURE_THRESHOLD"
    else
      highest_CPU_temperature=$((CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION + i * step))
    fi
    fan_speed=$(calculate_interpolated_fan_speed LOCAL_DECIMAL_FAN_SPEED LOCAL_DECIMAL_HIGH_FAN_SPEED highest_CPU_temperature CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION CPU_TEMPERATURE_THRESHOLD)
    bar_length=$((fan_speed * chart_width / 100))
    empty_length=$((chart_width - bar_length))

    # Calculate color based on highest_CPU_temperature
    if [ "$highest_CPU_temperature" -lt "$green_threshold" ]; then
      color="\e[32m"  # Green
    elif [ "$highest_CPU_temperature" -lt "$yellow_threshold" ]; then
      color="\e[33m"  # Yellow
    else
      color="\e[31m"  # Red
    fi
    printf "%3d°C | %3d%% | ${color}%-${bar_length}s%-${empty_length}s\e[0m|\n" "$highest_CPU_temperature" "$fan_speed" "$(printf '%0.s█' $(seq 1 "$bar_length"))" "$(printf '%0.s ' $(seq 1 "$empty_length"))"
  done

  echo
  echo -e "\e[1mLower Threshold:\e[0m ${CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION}°C"
  echo -e "\e[1mUpper Threshold:\e[0m ${CPU_TEMPERATURE_THRESHOLD}°C"
  echo -e "\e[1mBase Fan Speed:\e[0m ${LOCAL_DECIMAL_FAN_SPEED}%"
  echo -e "\e[1mMax Fan Speed:\e[0m ${LOCAL_DECIMAL_HIGH_FAN_SPEED}%"
  echo -e "\e[1mColor Thresholds:\e[0m"
  echo -e "  \e[32mGreen:\e[0m  < ${green_threshold}°C"
  echo -e "  \e[33mYellow:\e[0m ${green_threshold}°C - ${yellow_threshold}°C"
  echo -e "  \e[31mRed:\e[0m    > ${yellow_threshold}°C"
}

# F1 - lower fan speed
# F2 - higher fan speed
# T_CPU - highest temperature of all CPUs (if only one present the value will be CPU1 temperature)
# T1 - lower temperature threshold
# T2 - higher temperature threshold
# Fan speed = F1 + (( F2 - F1 ) * ( T_CPU - T1 ) / ( T2 - T1 ))
function calculate_interpolated_fan_speed() {
  local -r LOCAL_DECIMAL_FAN_SPEED=$1
  local -r LOCAL_DECIMAL_HIGH_FAN_SPEED=$2
  local -r highest_CPU_temperature=$3
  local -r CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=$4
  local -r CPU_TEMPERATURE_THRESHOLD=$5
  return $((LOCAL_DECIMAL_FAN_SPEED + ((LOCAL_DECIMAL_HIGH_FAN_SPEED - LOCAL_DECIMAL_FAN_SPEED) * ((highest_CPU_temperature - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION) / (CPU_TEMPERATURE_THRESHOLD - CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION))))
}

# function calculate_fan_speed() {
#   local -r LOCAL_DECIMAL_FAN_SPEED=$1
#   local -r LOCAL_DECIMAL_HIGH_FAN_SPEED=$2
#   local -r highest_CPU_temperature=$3
#   local -r CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION=$4
#   local -r CPU_TEMPERATURE_THRESHOLD=$5

# }

# Returns the maximum value among the given integer arguments.
# Usage: max <integer1> <integer2> ... <integerN>
function max() {
  local highest_temperature=$1
  shift # Moves the arguments, the first one is now deleted

  for temperature in "$@"; do # Iterates over the remaining arguments
    if [ "$temperature" -gt "$highest_temperature" ]; then
      highest_temperature="$temperature"
    fi
  done
  echo $highest_temperature
}

# Returns a formatted string containing the indexes of CPUs whose temperature exceeds the threshold.
# Returns an empty string if no CPU is overheating
# Usage: get_overheating_CPUs <temperature threshold> <CPU_temp1> <CPU_temp2> ... <CPU_tempN>
function get_overheating_CPUs() {
  # Check number of arguments (exactly 2: temperature threshold and CPUs temperatures string)
  if [ "$#" -ne 2 ]; then
    print_error "Two arguments are required (threshold and CPUs temperatures)"
    return 1
  fi

  local -r temperature_threshold="$1"
  local -r CPUs_temperatures="$2"

  # Creating an array from the string
  local -r CPUs_temperatures_array=(${CPUs_temperatures//;/ })

  local overheating_CPUs=""
  local CPU_index=1

  # Itération sur les températures dans le tableau
  for temperature in "${CPUs_temperatures_array[@]}"; do
    if [ "$temperature" -gt "$temperature_threshold" ]; then
      if [ -z "$overheating_CPUs" ]; then # If overheating_CPUs is empty
        overheating_CPUs="$CPU_index"
      else
        overheating_CPUs+=";$CPU_index"
      fi
    fi
    ((CPU_index++))
  done

  echo "$overheating_CPUs"
}

function redact_comment() {
  local -r PROFILE_ID="$1"
  local -r OVERHEATING_CPUs="$2"
  local -r CPU_TEMPERATURE_THRESHOLD="$3"
  local -r overheating_CPUs_array=(${OVERHEATING_CPUs//;/ })
  local -r number_of_overheating_CPUs=${#overheating_CPUs_array[@]}

  local -r CLASSIC_USER_FAN_CONTROL_PROFILE_APPLIED_MESSAGE="Dell default dynamic fan control profile applied for safety"
  local -r INTERPOLATED_USER_FAN_CONTROL_PROFILE_APPLIED_MESSAGE="Interpolated user's fan control profile applied"
  local -r DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED_MESSAGE="Classic user's fan control profile applied"
  
  case PROFILE_ID in
    CLASSIC_USER_FAN_CONTROL_PROFILE_ID)
      FAN_CONTROL_PROFILE_APPLIED_MESSAGE=$CLASSIC_USER_FAN_CONTROL_PROFILE_APPLIED_MESSAGE
      ;;
    INTERPOLATED_USER_FAN_CONTROL_PROFILE_ID)
      FAN_CONTROL_PROFILE_APPLIED_MESSAGE=$INTERPOLATED_USER_FAN_CONTROL_PROFILE_APPLIED_MESSAGE
      ;;
    DELL_DEFAULT_FAN_CONTROL_PROFILE_ID)
      FAN_CONTROL_PROFILE_APPLIED_MESSAGE=$DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED_MESSAGE
      ;;
    *)
      print_error "PROFILE_ID unknown. Has to be 1, 2 or 3."
      ;;
  esac

  if ((number_of_overheating_CPUs == 0)); then
    echo "CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), $FAN_CONTROL_PROFILE_APPLIED_MESSAGE."
  elif ((number_of_overheating_CPUs == 1)); then
    echo "CPU ${overheating_CPUs_array[0]//[][]} temperature is too high, $FAN_CONTROL_PROFILE_APPLIED_MESSAGE"
  else
    overheating_CPUs_string=""
    for ((i=0; i<number_of_overheating_CPUs; i++)); do
      overheating_CPUs_string+="CPU ${overheating_CPUs_array[i]}"
      if ((i < number_of_overheating_CPUs - 2)); then
        overheating_CPUs_string+=", "
      elif ((i == number_of_overheating_CPUs - 2)); then
        overheating_CPUs_string+=" and "
      fi
    done
    echo "$overheating_CPUs_string temperatures are too high, $FAN_CONTROL_PROFILE_APPLIED_MESSAGE"
  fi
}

function build_header() {
  # Vérification du nombre d'arguments
  if [ "$#" -ne 1 ]; then
    print_error "build_header() requires an argument (number_of_CPUs)"
    return 1
  fi

  local -r number_of_CPUs="$1"
  local -r CPU_column_width=7

  local header="                     ----" # Width ready for 1 CPU

  # Calculate the number of dashes to add on each side of the title
  number_of_dashes=$(((number_of_CPUs-1)*CPU_column_width/2))

  # Loop to add dashes
  for ((i=1; i<=number_of_dashes; i++)); do
    header+="-"
  done

  header+=" Temperatures ---"

  # Check parity and add an extra dash on the right if odd
  if (( (number_of_CPUs - 1) * CPU_column_width % 2 != 0 )); then
    header+="-"
  fi

  # Loop to add dashes
  for ((i=1; i<=number_of_dashes; i++)); do
    header+="-"
  done
  header+=$'\n    Date & time      Inlet  CPU 1 ' # TODO : check if it works with printf
  # OK

  # Loop to add CPU columns
  for ((i=2; i<=number_of_CPUs; i++)); do
    header+=" CPU $i "
  done
  header+=" Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"
  printf "%s" "$header"
}

function print_header() {
  local -r HEADER="$1"
  printf "%s" "$HEADER"
}

function print_temperature_array_line() {
  local -r $INLET_TEMPERATURE="$1"
  local -r $CPUS_TEMPERATURES="$2"
  local -r $EXHAUST_TEMPERATURE="$3"
  local -r $CURRENT_FAN_CONTROL_PROFILE="$4"
  local -r $THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="$5"
  local -r $COMMENT="$6"

  # Creating an array from the string
  local -r CPUs_temperatures_array=(${CPUs_temperatures//;/ })

  printf "%19s " $INLET_TEMPERATURE
  # Itération sur les températures dans le tableau
  for temperature in "${CPUs_temperatures_array[@]}"; do
    printf " %3d°C " $temperature
  done
  printf " %3s°C  %5s°C  %40s  %51s  %s\n" "$(date +"%d-%m-%Y %T")" $CPU1_TEMPERATURE "$CPU2_TEMPERATURE" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
}

# function CPU_HEATING() { [  ]; }
# function CPU_OVERHEATING() { [  ]; }
# Define functions to check if CPU 1 and CPU 2 temperatures are above the threshold
function CPU1_HEATING() { [ $CPU1_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ]; }
function CPU1_OVERHEATING() { [ $CPU1_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }
function CPU2_HEATING() { [ $CPU2_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ]; }
function CPU2_OVERHEATING() { [ $CPU2_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }

function print_error() {
  local -r ERROR_MESSAGE="$1"
  printf "/!\ Error /!\ %s." "$ERROR_MESSAGE" >&2
}

function print_error_and_exit() {
  local -r ERROR_MESSAGE="$1"
  print_error "$ERROR_MESSAGE"
  printf " Exiting.\n" >&2
  exit 1
}

function print_warning() {
  local -r WARNING_MESSAGE="$1"
  printf "/!\ Warning /!\ %s." "$WARNING_MESSAGE"
}

function print_warning_and_exit() {
  local -r WARNING_MESSAGE="$1"
  print_warning "$WARNING_MESSAGE"
  printf " Exiting.\n"
  exit 0
}
