;;; opencode-domain-test.el --- Tests for opencode-domain -*- lexical-binding: t; -*-

;; Buffer-free tests: every assertion here must run without
;; `opencode-test-with-temp-buffer'.  If a new domain helper needs a
;; buffer, it does not belong in opencode-domain.

;;; Code:

(require 'ert)
(require 'opencode-domain)

(defmacro opencode-domain-test--with-fresh-cache (&rest body)
  "Run BODY with a fresh, isolated child-parent cache."
  (declare (indent 0))
  `(let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal)))
     ,@body))

;;; --- child-parent-put / child-parent-get ---

(ert-deftest opencode-domain-child-parent-put-stores-pair ()
  "`opencode-domain-child-parent-put' must persist the mapping so
`child-parent-get' retrieves it.  Without this, popup dispatch
cannot route child-session events to their parent buffer."
  (opencode-domain-test--with-fresh-cache
    (opencode-domain-child-parent-put "ses_child" "ses_parent")
    (should (equal "ses_parent"
                   (opencode-domain-child-parent-get "ses_child")))))

(ert-deftest opencode-domain-child-parent-put-ignores-nil ()
  "`opencode-domain-child-parent-put' must silently no-op when either
argument is nil.  Callers fire this from SSE handlers that may or may
not have a parentID; a nil-check at every call site would be noise."
  (opencode-domain-test--with-fresh-cache
    (opencode-domain-child-parent-put nil "ses_parent")
    (opencode-domain-child-parent-put "ses_child" nil)
    (should-not (opencode-domain-child-parent-get "ses_child"))
    (should-not (opencode-domain-child-parent-get nil))))

(ert-deftest opencode-domain-child-parent-get-missing-returns-nil ()
  "Missing mapping must return nil, not signal.  Popup dispatch treats
nil as \"not a child session\" and proceeds with normal routing."
  (opencode-domain-test--with-fresh-cache
    (should-not (opencode-domain-child-parent-get "ses_unknown"))))

;;; --- find-root-session ---

(ert-deftest opencode-domain-find-root-returns-self-when-orphan ()
  "A session with no parent in the cache is its own root.  Without this
invariant, popup dispatch on the outermost session would return nil
and fall through to the broadcast path."
  (opencode-domain-test--with-fresh-cache
    (should (equal "ses_root"
                   (opencode-domain-find-root-session "ses_root")))))

(ert-deftest opencode-domain-find-root-walks-one-hop ()
  "Single-parent chain resolves to the parent.  This is the common
sub-agent case: one child session whose parent is a normal chat."
  (opencode-domain-test--with-fresh-cache
    (opencode-domain-child-parent-put "ses_child" "ses_root")
    (should (equal "ses_root"
                   (opencode-domain-find-root-session "ses_child")))))

(ert-deftest opencode-domain-find-root-walks-multi-hop ()
  "Deep chain resolves to the top-most ancestor.  Sub-agents can spawn
sub-agents; the popup must still reach the user-facing root buffer."
  (opencode-domain-test--with-fresh-cache
    (opencode-domain-child-parent-put "d" "c")
    (opencode-domain-child-parent-put "c" "b")
    (opencode-domain-child-parent-put "b" "a")
    (should (equal "a" (opencode-domain-find-root-session "d")))))

(ert-deftest opencode-domain-find-root-applies-path-compression ()
  "Walking a deep chain must compress the path so subsequent lookups
are O(1).  Without compression, every SSE event re-walks the chain —
visible latency on busy sessions."
  (opencode-domain-test--with-fresh-cache
    (opencode-domain-child-parent-put "d" "c")
    (opencode-domain-child-parent-put "c" "b")
    (opencode-domain-child-parent-put "b" "a")
    (opencode-domain-find-root-session "d")
    ;; After the walk, intermediate nodes point directly to the root.
    (should (equal "a" (opencode-domain-child-parent-get "d")))
    (should (equal "a" (opencode-domain-child-parent-get "c")))
    (should (equal "a" (opencode-domain-child-parent-get "b")))))

(ert-deftest opencode-domain-find-root-breaks-cycles ()
  "A cycle in the cache (e.g. corrupted server metadata pointing A→B→A)
must not loop forever.  `find-root-session' caps at
`opencode-domain--max-session-depth' hops and drops the offending
link so subsequent calls terminate."
  (opencode-domain-test--with-fresh-cache
    ;; Self-cycle: a session whose parent is itself.
    (opencode-domain-child-parent-put "ses_self" "ses_self")
    (opencode-domain-find-root-session "ses_self")
    ;; The offending link is broken so the next call terminates cleanly.
    (should-not (opencode-domain-child-parent-get "ses_self"))))

(ert-deftest opencode-domain-find-root-caps-at-max-depth ()
  "Pathologically deep chains beyond the depth cap must terminate at
the cap (not loop, not crash).  The cap is deliberately low (8) because
sub-agent nesting in practice is 0–3 levels; anything deeper is
defensively treated as a cycle."
  (opencode-domain-test--with-fresh-cache
    ;; Build a chain longer than the cap.
    (dotimes (i (1+ opencode-domain--max-session-depth))
      (opencode-domain-child-parent-put
       (format "node-%d" i) (format "node-%d" (1+ i))))
    ;; Must not loop / crash.  Result may be the cap-break node.
    (let ((result (opencode-domain-find-root-session "node-0")))
      (should (stringp result)))))

;;; --- Buffer-freedom invariant ---

(ert-deftest opencode-domain-has-no-buffer-dependencies ()
  "Domain layer must be loadable and testable without any buffer
context.  This test runs with no `with-temp-buffer' wrapper and the
current buffer is the ERT harness's messages buffer — if domain code
accidentally reaches for buffer-local state, this test fails."
  (opencode-domain-test--with-fresh-cache
    (opencode-domain-child-parent-put "a" "b")
    (should (equal "b" (opencode-domain-find-root-session "a")))
    (should (equal "b" (opencode-domain-child-parent-get "a")))))

(provide 'opencode-domain-test)
;;; opencode-domain-test.el ends here
