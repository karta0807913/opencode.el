;;; opencode-pi-widget-test.el --- Tests for opencode-pi-widget.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the Pi extension widget/status surface.  These exercise the
;; keyed replace-on-update model and the backing buffer content.  Presentation
;; (child frame / side window) is stubbed: batch Emacs is non-graphic, so the
;; `--show' path would try to pop a window; we stub the display + hide calls and
;; assert on the backing buffer + surface state instead.

;;; Code:

(require 'test-helper nil t)
(require 'cl-lib)
(require 'opencode-pi-widget)

(defmacro opencode-pi-widget-test--isolated (&rest body)
  "Run BODY with a fresh surface registry and stubbed presentation."
  (declare (indent 0))
  `(let ((opencode-pi-widget--surfaces (make-hash-table :test 'equal))
         (shown nil) (hidden nil))
     (cl-letf (((symbol-function 'opencode-pi-widget--show)
                (lambda (sid _surface) (push sid shown)))
               ((symbol-function 'opencode-pi-widget--hide)
                (lambda (_surface) (setq hidden t))))
       (ignore shown hidden)
       ,@body)))

(defun opencode-pi-widget-test--buffer-string (session-id)
  "Return the backing buffer content for SESSION-ID."
  (with-current-buffer (opencode-pi-widget-surface-buffer
                        (gethash session-id opencode-pi-widget--surfaces))
    (buffer-substring-no-properties (point-min) (point-max))))

;;; --- Widget model ---

(ert-deftest opencode-pi-widget-set-renders-lines ()
  "Setting a widget key renders its lines into the backing buffer.
This is how /btw's streamed answer becomes visible."
  (opencode-pi-widget-test--isolated
    (opencode-pi-widget-set "ses_pi" "btw-1" '("line one" "line two"))
    (let ((content (opencode-pi-widget-test--buffer-string "ses_pi")))
      (should (string-match-p "line one" content))
      (should (string-match-p "line two" content)))))

(ert-deftest opencode-pi-widget-set-replaces-on-update ()
  "Re-setting the same key replaces its lines (streaming replace-on-update).
Pi sends the full accumulated widget on each update, not a delta."
  (opencode-pi-widget-test--isolated
    (opencode-pi-widget-set "ses_pi" "btw-1" '("partial"))
    (opencode-pi-widget-set "ses_pi" "btw-1" '("partial answer complete"))
    (let ((content (opencode-pi-widget-test--buffer-string "ses_pi")))
      (should (string-match-p "partial answer complete" content))
      ;; The stale shorter line must not linger as a separate entry.
      (should-not (string-match-p "^partial$" content)))))

(ert-deftest opencode-pi-widget-set-nil-removes-key ()
  "Setting nil lines removes the widget key.
This is how Pi clears a widget (widgetLines: undefined)."
  (opencode-pi-widget-test--isolated
    (opencode-pi-widget-set "ses_pi" "btw-1" '("hello"))
    (opencode-pi-widget-set "ses_pi" "btw-1" nil)
    (let ((surface (gethash "ses_pi" opencode-pi-widget--surfaces)))
      (should (null (opencode-pi-widget-surface-widgets surface)))
      (should (opencode-pi-widget--empty-p surface)))))

(ert-deftest opencode-pi-widget-vector-lines-accepted ()
  "Widget lines may arrive as a vector (JSON array) and still render.
Pi's widgetLines is a JSON array → vector after parse."
  (opencode-pi-widget-test--isolated
    (opencode-pi-widget-set "ses_pi" "k" (vector "a" "b"))
    (let ((content (opencode-pi-widget-test--buffer-string "ses_pi")))
      (should (string-match-p "a" content))
      (should (string-match-p "b" content)))))

(ert-deftest opencode-pi-widget-multiple-keys-divided ()
  "Two widget keys render as separate divided sections.
Multiple /btw turns accumulate; each is its own block."
  (opencode-pi-widget-test--isolated
    (opencode-pi-widget-set "ses_pi" "k1" '("first"))
    (opencode-pi-widget-set "ses_pi" "k2" '("second"))
    (let ((content (opencode-pi-widget-test--buffer-string "ses_pi")))
      (should (string-match-p "first" content))
      (should (string-match-p "second" content))
      (should (string-match-p "─" content)))))

;;; --- Status model ---

(ert-deftest opencode-pi-widget-status-renders-and-clears ()
  "Status text renders, and nil text removes the status key.
setStatus drives the /btw:summarize status line; clearing must work."
  (opencode-pi-widget-test--isolated
    (opencode-pi-widget-status "ses_pi" "s1" "summarizing...")
    (should (string-match-p "summarizing"
                            (opencode-pi-widget-test--buffer-string "ses_pi")))
    (opencode-pi-widget-status "ses_pi" "s1" nil)
    (let ((surface (gethash "ses_pi" opencode-pi-widget--surfaces)))
      (should (null (opencode-pi-widget-surface-statuses surface))))))

;;; --- Show / hide lifecycle ---

(ert-deftest opencode-pi-widget-shows-when-content-hides-when-empty ()
  "The surface shows while it has content and hides when emptied.
Prevents a stale empty panel lingering after /btw:clear."
  (let ((opencode-pi-widget--surfaces (make-hash-table :test 'equal))
        (shows 0) (hides 0))
    (cl-letf (((symbol-function 'opencode-pi-widget--show)
               (lambda (_sid _s) (cl-incf shows)))
              ((symbol-function 'opencode-pi-widget--hide)
               (lambda (_s) (cl-incf hides))))
      (opencode-pi-widget-set "ses_pi" "k" '("x"))
      (should (= shows 1))
      (should (= hides 0))
      (opencode-pi-widget-set "ses_pi" "k" nil)
      (should (= hides 1)))))

(ert-deftest opencode-pi-widget-cleanup-removes-surface ()
  "Cleanup removes the surface from the registry and kills its buffer.
Called on chat-buffer kill / conn exit so sessions don't leak surfaces."
  (let ((opencode-pi-widget--surfaces (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'opencode-pi-widget--show) #'ignore)
              ((symbol-function 'opencode-pi-widget--hide) #'ignore))
      (opencode-pi-widget-set "ses_pi" "k" '("x"))
      (let ((buf (opencode-pi-widget-surface-buffer
                  (gethash "ses_pi" opencode-pi-widget--surfaces))))
        (opencode-pi-widget-cleanup "ses_pi")
        (should-not (gethash "ses_pi" opencode-pi-widget--surfaces))
        (should-not (buffer-live-p buf))))))

(provide 'opencode-pi-widget-test)
;;; opencode-pi-widget-test.el ends here
