# Thin wrapper - the real logic is in build.sh / run.sh / test/run_tests.sh
all:
	./build.sh
run: all
	./run.sh --no-build
test:
	test/run_tests.sh
clean:
	./build.sh clean
.PHONY: all run test clean
