.PHONY: test vet image run

test:
	go test ./... -count=1

vet:
	go vet ./...

image:
	docker build -t vanir.lab/eviction-notice:dev .

# End-to-end on the kind lab (needs `make up` at the repo root).
run:
	../../scripts/reset.sh
	./run.sh
