FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
COPY web ./web
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /uploader .

FROM alpine:3.20
RUN adduser -D -u 10001 app && mkdir /data && chown app /data
COPY --from=build /uploader /usr/local/bin/uploader
USER app
ENV DATA_DIR=/data LISTEN=:8080
VOLUME /data
EXPOSE 8080
CMD ["uploader"]
