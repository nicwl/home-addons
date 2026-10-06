ARG BUILD_FROM
FROM $BUILD_FROM
RUN apk upgrade --no-cache && apk add --no-cache curl jq
COPY rootfs /
RUN chmod a+x /run.sh
CMD [ "/run.sh" ]
