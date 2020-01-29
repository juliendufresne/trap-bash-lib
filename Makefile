
# ability to change the bash binary used.
SHELL = bash
SHELLCHECK = bin/shellcheck
SHUNIT = bin/shunit2.sh

# bash files to be checked by shellcheck
CHECK_FILES = trap.sh features/features.bash

.DEFAULT_GOAL := ci

.PHONY: ci-watch
ci-watch:
	while : ;\
	do \
    	$(MAKE) ci; \
    	inotifywait -e close_write -r .; \
	done

.PHONY: ci
ci:: check tests

.PHONY: check
check:: | $(SHELLCHECK) $(SHUNIT)
	$(SHELLCHECK) --enable=all --external-sources -s bash -S style -P SCRIPTDIR $(CHECK_FILES)

.PHONY: tests
tests:: feature-tests

.PHONY: feature-tests
feature-tests:: | $(SHUNIT)
	$(SHELL) ${SHUNIT} features/features.bash test_features

.PHONY: clean
clean::
	# use interactive because user might have put a non generated file
	! test -d bin || rm -r --interactive=once bin

$(SHELLCHECK):
	mkdir -p $$(dirname $(SHELLCHECK))
	wget -q -O shellcheck.tar.xz https://storage.googleapis.com/shellcheck/shellcheck-stable.linux.x86_64.tar.xz
	tar -x -O -f shellcheck.tar.xz shellcheck-stable/shellcheck > $(SHELLCHECK)
	rm shellcheck.tar.xz
	chmod u+x $(SHELLCHECK)

$(SHUNIT):
	mkdir -p $$(dirname $(SHUNIT))
	wget -q -O $(SHUNIT) https://raw.githubusercontent.com/kward/shunit2/master/shunit2
	chmod u+x $(SHUNIT)
