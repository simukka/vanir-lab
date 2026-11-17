FROM golang:1.27.0-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /eviction-notice ./cmd

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /eviction-notice /eviction-notice
USER 65532:65532
ENTRYPOINT ["/eviction-notice"]
