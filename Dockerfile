FROM ubuntu:24.04
LABEL org.opencontainers.image.authors="bradbarnhill"

RUN apt-get update

RUN apt-get install ipmitool -y

ADD Dell_iDRAC_fan_controller.sh /Dell_iDRAC_fan_controller.sh

RUN chmod 0777 /Dell_iDRAC_fan_controller.sh

# you should override these default values when running. See README.md
#ENV IDRAC_HOST 192.168.1.100
ENV IDRAC_HOST local
#ENV IDRAC_USERNAME root
#ENV IDRAC_PASSWORD calvin
ENV FAN_SPEED 15
ENV HIGH_FAN_SPEED 45
ENV CPU_TEMPERATURE_THRESHOLD 70
ENV CHECK_INTERVAL 3
ENV CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION 50
ENV ENABLE_LINE_INTERPOLATION true
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE false

CMD ["/Dell_iDRAC_fan_controller.sh"]
