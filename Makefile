EMACS ?= emacs
ELPA_DIR = $(HOME)/.emacs.d/elpa

# In CI, use package.el to discover load paths dynamically
ifdef CI
BATCH = $(EMACS) -Q -batch -L . -L test \
  --eval "(require 'package)" \
  --eval "(push '(melpa . \"https://melpa.org/packages/\") package-archives)" \
  --eval "(package-initialize)" \
  --eval "(dolist (d (directory-files package-user-dir t \"[^.].*\")) (when (file-directory-p d) (push d load-path)))"
else
DEPS = $(foreach d,$(wildcard \
         $(ELPA_DIR)/markdown-mode-* \
         $(ELPA_DIR)/treemacs-* \
         $(ELPA_DIR)/s-* \
         $(ELPA_DIR)/dash-* \
         $(ELPA_DIR)/ht-* \
         $(ELPA_DIR)/pfuture-* \
         $(ELPA_DIR)/ace-window-*),-L $(d))
BATCH = $(EMACS) -Q -batch -L . -L test $(DEPS)
endif

SOURCES = $(wildcard *.el)
PIPELINE_SCRIPT_SOURCES = $(filter-out scripts/pipelines/pipeline-scripts-test.el,$(wildcard scripts/pipelines/*.el))
TEST_SOURCES = $(wildcard test/*-test.el) scripts/pipelines/pipeline-scripts-test.el

.PHONY: test pipeline-test lint compile clean all

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

pipeline-test: clean ## Run pipeline script ERT tests
	$(BATCH) -l test/test-helper.el \
	  -l scripts/pipelines/pipeline-scripts-test.el \
	  -f ert-run-tests-batch-and-exit

compile: ## Byte-compile all .el files
	$(BATCH) -L scripts/pipelines -f batch-byte-compile \
	  $(SOURCES) $(PIPELINE_SCRIPT_SOURCES)

lint: ## Run checkdoc on all source files
	@for f in $(SOURCES); do \
	  echo "Checking $$f..."; \
	  $(BATCH) --eval "(checkdoc-file \"$$f\")" 2>&1 || true; \
	done

clean: ## Remove compiled files
	rm -f *.elc test/*.elc scripts/pipelines/*.elc

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
