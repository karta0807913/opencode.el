EMACS ?= emacs
ELPA_DIR = $(HOME)/.emacs.d/elpa

# In CI, use package.el to discover load paths dynamically
ifdef CI
BATCH = $(EMACS) -Q -batch -L . -L test \
  --eval "(require 'package)" \
  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
  --eval "(package-initialize)" \
  --eval "(let ((dirs (directory-files package-user-dir t \"^[^.].*-.*$\"))) (dolist (d dirs) (add-to-list 'load-path d)))"
else
DEPS = -L $(ELPA_DIR)/treemacs-3.2 \
       -L $(ELPA_DIR)/s-1.13.0 \
       -L $(ELPA_DIR)/dash-2.20.0 \
       -L $(ELPA_DIR)/ht-2.3 \
       -L $(ELPA_DIR)/pfuture-1.10.3 \
       -L $(ELPA_DIR)/cfrs-1.7.0 \
       -L $(ELPA_DIR)/ace-window-20220911.358 \
       -L $(ELPA_DIR)/posframe-1.4.4
BATCH = $(EMACS) -Q -batch -L . -L test $(DEPS)
endif

SOURCES = $(wildcard *.el)
TEST_SOURCES = $(wildcard test/*-test.el)

.PHONY: test lint compile clean all

all: compile test ## Build and test

test: clean ## Run all ERT tests
ifdef TEST
	$(BATCH) -l test/test-helper.el -l $(TEST) \
	  -f ert-run-tests-batch-and-exit
else
	$(BATCH) -l test/test-helper.el \
	  $(patsubst %,-l %,$(TEST_SOURCES)) \
	  -f ert-run-tests-batch-and-exit
endif

compile: ## Byte-compile all .el files
	$(BATCH) -f batch-byte-compile $(SOURCES)

lint: ## Run checkdoc on all source files
	@for f in $(SOURCES); do \
	  echo "Checking $$f..."; \
	  $(BATCH) --eval "(checkdoc-file \"$$f\")" 2>&1 || true; \
	done

clean: ## Remove compiled files
	rm -f *.elc test/*.elc

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
