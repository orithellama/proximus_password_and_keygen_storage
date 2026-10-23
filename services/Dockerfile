FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY internal ./internal
COPY relay ./relay
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relay ./relay && \
    mkdir /data && chown 65532:65532 /data

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/relay /relay
COPY --from=build --chown=65532:65532 /data /data
USER 65532:65532
WORKDIR /data
ENV PROXIMUS_LISTEN=0.0.0.0:8088 PROXIMUS_DATA=/data/relay
EXPOSE 8088
ENTRYPOINT ["/relay"]
