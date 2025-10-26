# Define global functions
# This function applies Dell's default dynamic fan control profile
function apply_Dell_fan_control_profile() {
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
#   $1 (MODE): The fan control mode.
#              1 for static fan speed, 2 for dynamic (interpolated) fan control.
#   $2 (LOCAL_FAN_SPEED): The desired fan speed. Can be in decimal (0-100) or hexadecimal (0x00-0x64) format.
#
# Global variables used:
#   CURRENT_FAN_CONTROL_PROFILE: Updated with the current fan control profile description.
#
# Returns:
#   None. In case of an invalid mode, it calls graceful_exit().
function apply_user_fan_control() {
  # todo - mode parameter for now could be avoided, but it ease adding something in future
  local MODE=$1
  local LOCAL_FAN_SPEED=$2

  if [[ $LOCAL_FAN_SPEED == 0x* ]]; then
    local LOCAL_DECIMAL_FAN_SPEED
    LOCAL_DECIMAL_FAN_SPEED=$(printf '%d' "$LOCAL_FAN_SPEED")
    local LOCAL_HEXADECIMAL_FAN_SPEED=$LOCAL_FAN_SPEED
  else
    local LOCAL_DECIMAL_FAN_SPEED=$LOCAL_FAN_SPEED
    local LOCAL_HEXADECIMAL_FAN_SPEED
    LOCAL_HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$LOCAL_FAN_SPEED")
  fi

  case $MODE in
    1)
      apply_fan_control_to_specified_value "$LOCAL_HEXADECIMAL_FAN_SPEED"
      CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($LOCAL_DECIMAL_FAN_SPEED%)"
      ;;
    2)
      apply_fan_control_to_specified_value "$LOCAL_HEXADECIMAL_FAN_SPEED"
      CURRENT_FAN_CONTROL_PROFILE="Interpolated fan control profile ($LOCAL_DECIMAL_FAN_SPEED%)"
      ;;
    *)
      echo "Invalid mode selected. Please use 1 for static fan speed or 2 for dynamic fan control."
      graceful_exit
      ;;
  esac
}

# Apply fan control to a specified value
#
# This function sets the fan speed to a user-specified value using ipmitool.
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
function apply_fan_control_to_specified_value() {
  local VALUE=$1

  # Check if the input value is a hexadecimal number, if not, convert it to hexadecimal
  if [[ $VALUE != 0x* ]]; then
      VALUE=$(convert_decimal_value_to_hexadecimal "$VALUE")
  fi

  # Use ipmitool to send the raw command to set fan control to user-specified value
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff "$VALUE" > /dev/null
}

# This function applies a user-specified static fan control profile
#function apply_user_fan_control_profile() {
#  # Use ipmitool to send the raw command to set fan control to user-specified value
#  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
#  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null
#  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
#}
#
## This function applies a user-specified interpolated fan control profile
#function apply_user_fan_control_profile_with_interpolation () {
#  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
#  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_CURRENT_FAN_SPEED > /dev/null
#  CURRENT_FAN_CONTROL_PROFILE="Interpolated fan control profile ($DECIMAL_CURRENT_FAN_SPEED%)"
#}

# Convert first parameter given ($DECIMAL_NUMBER) to hexadecimal
# Usage : convert_decimal_value_to_hexadecimal $DECIMAL_NUMBER
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
# Usage : retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
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
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
    CPU2_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU2_TEMPERATURE_INDEX;}")
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
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER
  then
    # 14 Gen server or newer
    continue
  else
    # 13 Gen server or older
    ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null
  fi
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER
  then
    # 14 Gen server or newer
    continue
  else
    # 13 Gen server or older
    ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null
  fi
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
  echo "Gracefully exit"
  apply_Dell_fan_control_profile

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety"
}

# Helps debugging when people are posting their output
function get_Dell_server_model() {
  local -r IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>/dev/null) # FRU stands for "Field Replaceable Unit"
  # TODO - Add check if connection was established. There are a chance user type wrong login and pass. In my case it returns "Error: Unable to establish IPMI v2 / RMCP+ session"

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

# Define functions to check if CPU 1 and CPU 2 temperatures are above the threshold
function CPU1_OVERHEATING() { [ $CPU1_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }
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
