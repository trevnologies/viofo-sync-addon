ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    mosquitto-clients \
    tzdata

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/bin/bash", "/run.sh"]
