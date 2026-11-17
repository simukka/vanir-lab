.PHONY: tools up down reset watch module-%

tools:
	./scripts/install-tools.sh

up:
	./scripts/up.sh

down:
	./scripts/down.sh

reset:
	./scripts/reset.sh

watch:
	./tools/watch.sh

# make module-1 → modules/01-*/run.sh
module-%:
	./scripts/reset.sh
	./modules/$$(printf '%02d' $*)-*/run.sh
