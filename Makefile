.PHONY: test shellcheck install lint

test:
	bats test/

shellcheck:
	# -x follows `source` directives so cross-module references aren't false positives
	shellcheck -x zfsbay install.sh
	# Lib files are checked standalone with our annotated suppressions
	shellcheck lib/*.sh

lint: shellcheck

install:
	./install.sh
