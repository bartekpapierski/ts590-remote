# Build stage
FROM golang:1.26 AS build
RUN apt-get update && apt-get install -y \
    gcc pkg-config portaudio19-dev libopus-dev libopusfile-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -o /out/ts590-server ./cmd/server

# Runtime stage
FROM debian:stable-slim
RUN apt-get update && apt-get install -y \
    libportaudio2 libopus0 libopusfile0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/ts590-server /app/ts590-server
COPY server.yaml /app/server.yaml
EXPOSE 5900/tcp 5901/udp
# Pass the serial device through, e.g.:
#   docker run -v /dev/ttyACM0:/dev/ttyACM0 -p 5900:5900/tcp -p 5901:5901/udp ts590-server
ENTRYPOINT ["/app/ts590-server", "-config", "/app/server.yaml"]
