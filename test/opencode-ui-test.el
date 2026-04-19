;;; opencode-ui-test.el --- Tests for opencode-ui.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for section rendering and UI primitives.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-ui)

;;; --- Section creation ---

(ert-deftest opencode-ui--make-section-basic ()
  "Verify section plist contains required type, id, and data fields.
Without proper structure, section creation would fail silently and
section-based features (collapse, navigation, styling) would break."
  (let ((section (opencode-ui--make-section 'message "msg_1" '(:role "user"))))
    (should (eq (plist-get section :type) 'message))
    (should (string= (plist-get section :id) "msg_1"))
    (should (plistp (plist-get section :data)))))

(ert-deftest opencode-ui--make-section-minimal ()
  "Verify section creation works with just type (nil id/data).
Allows minimal sections like separators that need no identification,
reducing boilerplate for simple UI elements."
  (let ((section (opencode-ui--make-section 'separator)))
    (should (eq (plist-get section :type) 'separator))
    (should (null (plist-get section :id)))))

;;; --- Section insertion ---

(ert-deftest opencode-ui--with-section-sets-properties ()
  "Verify with-section macro applies text properties to inserted region.
Without property tagging, section-at queries fail and section-aware
navigation/collapse cannot identify section boundaries."
  (opencode-test-with-temp-buffer "*test-ui-section*"
    (let ((section (opencode-ui--make-section 'test-section "ts_1")))
      (opencode-ui--with-section section
        (insert "Section content\n")))
    (goto-char (point-min))
    (should (opencode-ui--section-at))
    (should (eq (opencode-ui--section-type) 'test-section))
    (should (string= (opencode-ui--section-id) "ts_1"))))

(ert-deftest opencode-ui--with-section-returns-overlay ()
  "Verify with-section returns an overlay spanning the inserted content.
The overlay is essential for collapse/expand mechanics and tracking
section boundaries independent of text modifications."
  (opencode-test-with-temp-buffer "*test-ui-overlay*"
    (let ((result (opencode-ui--with-section
                      (opencode-ui--make-section 'test "t1")
                    (insert "content\n"))))
      (should (overlayp result))
      (should (= (overlay-start result) 1))
      (should (= (overlay-end result) (point)))
      (should (overlay-get result 'opencode-section)))))

;;; --- Section queries ---

(ert-deftest opencode-ui--section-at-returns-nil-outside ()
  "Verify section-at returns nil outside any section.
Prevents false positives where plain text would be treated as a section,
causing spurious collapse/expand or navigation jumps."
  (opencode-test-with-temp-buffer "*test-ui-outside*"
    (insert "plain text\n")
    (goto-char (point-min))
    (should (null (opencode-ui--section-at)))))

;;; --- Section collapse/expand ---

(ert-deftest opencode-ui--toggle-section-collapses ()
  "Verify toggle hides body on first call, shows it on second.
Core collapse/expand cycle must work for users to hide verbose content
and re-expand when needed without data loss."
  (opencode-test-with-temp-buffer "*test-ui-collapse*"
    (opencode-ui--with-section (opencode-ui--make-section 'test "t1")
      (insert "Header line\n")
      (insert "Body line 1\n")
      (insert "Body line 2\n"))
    (goto-char (point-min))
    ;; Should not be collapsed initially
    (should-not (opencode-ui--section-collapsed-p))
    ;; Toggle to collapse
    (opencode-ui--toggle-section)
    (should (opencode-ui--section-collapsed-p))
    ;; Toggle to expand
    (opencode-ui--toggle-section)
    (should-not (opencode-ui--section-collapsed-p))))

;;; --- Text insertion helpers ---

(ert-deftest opencode-ui--insert-separator-renders ()
  "Verify separator has face and display property for full-width line.
Without proper rendering, separators would appear as plain spaces
instead of visual dividers spanning the window width."
  (opencode-test-with-temp-buffer "*test-ui-sep*"
    (opencode-ui--insert-separator)
    (goto-char (point-min))
    ;; Should have the separator face
    (should (opencode-test-has-face-p " " 'opencode-separator))
    ;; Should use display property for full-width extension
    (should (get-text-property (point-min) 'display))))

(ert-deftest opencode-ui--insert-header-renders ()
  "Verify header text is inserted correctly with proper styling.
Headers identify sections visually; failure breaks section identification
and makes the UI layout confusing for users."
  (opencode-test-with-temp-buffer "*test-ui-header*"
    (opencode-ui--insert-header "Test Header")
    (should (opencode-test-buffer-contains-p "Test Header"))))

(ert-deftest opencode-ui--insert-line-with-face ()
  "Verify line insertion applies the specified face.
Faced lines provide visual distinction (cost, status, etc.); without
face application, all text appears uniform and loses semantic meaning."
  (opencode-test-with-temp-buffer "*test-ui-line*"
    (opencode-ui--insert-line "colored text" 'opencode-cost)
    (goto-char (point-min))
    (should (opencode-test-has-face-p "colored text" 'opencode-cost))))

;;; --- Icons ---

(ert-deftest opencode-ui--insert-icon-active ()
  "Verify active icon shows filled circle indicator.
Active status must be visually distinct; wrong icon breaks user's
ability to identify in-progress operations at a glance."
  (opencode-test-with-temp-buffer "*test-ui-icon*"
    (opencode-ui--insert-icon 'active)
    (should (opencode-test-buffer-contains-p "⬤"))))

(ert-deftest opencode-ui--insert-icon-success ()
  "Verify success icon shows check mark indicator.
Success state needs distinct visual feedback; wrong icon would mislead
users about operation completion status."
  (opencode-test-with-temp-buffer "*test-ui-icon-ok*"
    (opencode-ui--insert-icon 'success)
    (should (opencode-test-buffer-contains-p "✓"))))

(ert-deftest opencode-ui--insert-icon-expanded ()
  "Verify expanded icon shows down triangle indicator.
Expanded state must be visually indicated; wrong icon breaks affordance
for users to understand collapse/expand state."
  (opencode-test-with-temp-buffer "*test-ui-icon-exp*"
    (opencode-ui--insert-icon 'expanded)
    (should (opencode-test-buffer-contains-p "▼"))))

;;; --- Tree guides ---

(ert-deftest opencode-ui-tree-guide-not-last ()
  "Verify non-last tree items show branch connector (├─).
Tree hierarchy visualization requires proper connectors; wrong symbols
break the visual tree structure users rely on for navigation."
  (opencode-test-with-temp-buffer "*test-ui-tree*"
    (opencode-ui--insert-tree-guide nil)
    (should (opencode-test-buffer-contains-p "├─"))))

(ert-deftest opencode-ui-tree-guide-last ()
  "Verify last tree item shows end connector (└─).
Last item needs distinct terminator to indicate subtree end; wrong
connector makes hierarchical structure ambiguous."
  (opencode-test-with-temp-buffer "*test-ui-tree-last*"
    (opencode-ui--insert-tree-guide t)
    (should (opencode-test-buffer-contains-p "└─"))))

;;; --- Buffer helpers ---

(ert-deftest opencode-ui--read-only-buffer-sets-flags ()
  "Verify read-only buffer sets buffer-read-only and truncate-lines.
Read-only buffers must prevent accidental edits; missing flags would
allow users to corrupt display-only content like session lists."
  (opencode-test-with-temp-buffer "*test-ui-ro*"
    (opencode-ui--read-only-buffer)
    (should buffer-read-only)
    (should truncate-lines)))

;;; --- Collapse preserves header newline ---

(ert-deftest opencode-ui--collapse-preserves-header-newline ()
  "Verify collapse keeps header visible with [collapsed] indicator.
Header line (including indicator and newline) stays visible while body
text becomes invisible. Users need header context to identify collapsed sections."
  (opencode-test-with-temp-buffer "*test-ui-collapse-nl*"
    (opencode-ui--with-section (opencode-ui--make-section 'test "t1")
      (insert "Header line\n")
      (insert "Body line 1\n")
      (insert "Body line 2\n"))
    (goto-char (point-min))
    (opencode-ui--toggle-section)
    ;; The [collapsed] indicator should be present
    (should (opencode-test-buffer-contains-p "[collapsed]"))
    ;; Find the end of the header line (after [collapsed] indicator)
    (goto-char (point-min))
    (let ((eol (pos-eol)))
      ;; Header line text should NOT be invisible
      (should-not (get-text-property (point-min) 'invisible))
      ;; Body text (after the header line's newline) should be invisible
      (should (get-text-property (1+ eol) 'invisible)))))

;;; --- Toggle updates collapse icon ---

(ert-deftest opencode-ui--toggle-section-updates-icon ()
  "Verify toggle swaps expand/collapse indicator icon (▼ ↔ ▶).
Icon must reflect current state; stale icon misleads users about
whether content is hidden or visible."
  (let ((expanded-icon (string #x25BC))   ; ▼
        (collapsed-icon (string #x25B6))) ; ▶
    (opencode-test-with-temp-buffer "*test-ui-icon-swap*"
      (opencode-ui--with-section (opencode-ui--make-section 'test "t1")
        (opencode-ui--insert-icon 'expanded)
        (insert " Header\n")
        (insert "Body\n"))
      (goto-char (point-min))
      ;; Initially expanded: should have ▼
      (should (string-match-p expanded-icon (buffer-string)))
      (should-not (string-match-p collapsed-icon (buffer-string)))
      ;; Collapse
      (goto-char (point-min))
      (opencode-ui--toggle-section)
      (should (string-match-p collapsed-icon (buffer-string)))
      (should-not (string-match-p expanded-icon (buffer-string)))
      ;; Expand again
      (goto-char (point-min))
      (opencode-ui--toggle-section)
      (should (string-match-p expanded-icon (buffer-string)))
      (should-not (string-match-p collapsed-icon (buffer-string))))))

(ert-deftest opencode-ui--insert-icon-marks-collapse-property ()
  "Verify only expand/collapse icons get opencode-collapse-icon property.
Property selectivity ensures icon swap targets correct characters;
applying to non-collapse icons would corrupt unrelated UI elements."
  (opencode-test-with-temp-buffer "*test-ui-icon-prop*"
    (opencode-ui--insert-icon 'expanded)
    (should (get-text-property (point-min) 'opencode-collapse-icon))
    (erase-buffer)
    (opencode-ui--insert-icon 'success)
    ;; Non-collapse icons should NOT have the property
    (should-not (get-text-property (point-min) 'opencode-collapse-icon))))

(provide 'opencode-ui-test)
;;; opencode-ui-test.el ends here
