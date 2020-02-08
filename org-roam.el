;;; org-roam.el --- Roam Research replica with Org-mode

;;; Commentary:
;;

;;; Code:
(require 'org-element)
(require 'async)
(require 'subr-x)
(require 's)

;;; Customizations
(defgroup org-roam nil
  "Roam Research replica in Org-mode."
  :group 'org
  :prefix "org-roam-")

(defcustom org-roam-directory (expand-file-name "~/org-roam/")
  "Org-roam directory."
  :type 'directory
  :group 'org-roam)

(defcustom org-roam-zettel-indicator "§"
  "Indicator in front of a zettel."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-position 'right
  "Position of `org-roam' buffer.

Valid values are
 * left,
 * right."
  :type '(choice (const left)
                 (const right))
  :group 'org-roam)

(defcustom org-roam-buffer "*org-roam*"
  "Org-roam buffer name."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-preview-content-delimiter "------"
  "Delimiter for preview content."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-update-interval 5
  "Number of minutes to run asynchronous update of backlinks."
  :type 'number
  :group 'org-roam)

(defcustom org-roam-graph-viewer (executable-find "firefox")
  "Path to executable for viewing SVG."
  :type 'string
  :group 'org-roam)

(defcustom org-roam-graphviz-executable (executable-find "dot")
  "Path to graphviz executable."
  :type 'string
  :group 'org-roam)

;;; Polyfills
;; These are for functions I use that are only available in newer Emacs

;; Introduced in Emacs 27.1
(unless (fboundp 'make-empty-file)
  (defun make-empty-file (filename &optional parents)
    "Create an empty file FILENAME.
Optional arg PARENTS, if non-nil then creates parent dirs as needed.

If called interactively, then PARENTS is non-nil."
    (interactive
     (let ((filename (read-file-name "Create empty file: ")))
       (list filename t)))
    (when (and (file-exists-p filename) (null parents))
      (signal 'file-already-exists `("File exists" ,filename)))
    (let ((paren-dir (file-name-directory filename)))
      (when (and paren-dir (not (file-exists-p paren-dir)))
        (make-directory paren-dir parents)))
    (write-region "" nil filename nil 0)))

;;; Dynamic variables
(defvar org-roam-update-timer nil
  "Variable containing the timer that periodically updates the buffer.")

(defvar org-roam-cache nil
  "Cache containing backlinks for `org-roam' buffers.")

(defvar org-roam-current-file-id nil
  "Currently displayed file in `org-roam' buffer.")

;;; Utilities
(defun org-roam--find-files (dir)
  (if (file-exists-p dir)
      (let ((files (directory-files dir t "." t))
            (dir-ignore-regexp (concat "\\(?:"
                                       "\\."
                                       "\\|\\.\\."
                                       "\\)$"))
            result)
        (dolist (file files)
          (cond
           ((file-directory-p file)
            (when (not (string-match dir-ignore-regexp file))
              (setq result (append (org-roam--find-files file) result))))
           ((and (file-readable-p file)
                 (string= (file-name-extension file) "org"))
            (setq result (cons file result)))))
        result)))

(defun org-roam--find-all-files ()
  (org-roam--find-files org-roam-directory))

(defun org-roam--get-file-path-absolute (id)
  "Converts identifier `ID' to the absolute file path."
  (expand-file-name
   (concat id ".org")
   (file-truename org-roam-directory)))

(defun org-roam--get-file-path (id)
  "Converts identifier `ID' to the relative file path."
  (file-relative-name (org-roam--get-file-path-absolute id)))

(defun org-roam--get-id (file-path)
  (file-name-sans-extension
   (file-relative-name
    (file-truename file-path)
    (file-truename org-roam-directory))))

;;; Inserting org-roam links
(defun org-roam-insert (id)
  "Find `ID', and insert a relative org link to it at point."
  (interactive (list (completing-read "File: "
                                      (mapcar #'org-roam--get-id
                                              (org-roam--find-all-files)))))
  (let ((file-path (org-roam--get-file-path id)))
    (unless (file-exists-p file-path)
      (make-empty-file file-path))
    (insert (format "[[%s][%s]]"
                    (concat "file:" file-path)
                    (concat org-roam-zettel-indicator id)))))

;;; Finding org-roam files
(defun org-roam-find-file (id)
  "Find and open file with id `ID'."
  (interactive (list (completing-read "File: "
                                      (mapcar #'org-roam--get-id
                                              (org-roam--find-all-files)))))
  (let ((file-path (org-roam--get-file-path id)))
    (unless (file-exists-p file-path)
      (make-empty-file file-path))
    (find-file file-path)))

(defun org-roam-find-at-point ()
  "If point is above a link with a zettel indicator, open the file indicated by it."
  (interactive)
  (when (org-in-regexp org-bracket-link-regexp 1)
    (let* ((text (org-extract-attributes (org-link-unescape (org-match-string-no-properties 3))))
           (link (org-extract-attributes (org-link-unescape (org-match-string-no-properties 1))))
           (zettel-regexp (concat "^" org-roam-zettel-indicator))
           (file-regexp "^file:")
           (file (replace-regexp-in-string file-regexp "" link))
           (backlink-id (replace-regexp-in-string zettel-regexp "" text)))
      (when (string-match-p zettel-regexp text)
        (find-file file)))))

;;; Building the org-roam cache (asynchronously)
(defun org-roam--build-cache-async ()
  "Builds the cache asychronously, saving it into `org-roam-cache'."
  (interactive)
  (setq org-roam-files (org-roam--find-all-files))
  (async-start
   `(lambda ()
      (require 'org)
      (require 'org-element)
      (require 'subr-x)                 ; temp-fix
      (require 'cl-lib)
      ,(async-inject-variables "org-roam-files")
      ,(async-inject-variables "org-roam-directory")
      (let ((backlinks (make-hash-table :test #'equal)))
        (cl-flet* ((org-roam--get-id (file-path) (file-name-sans-extension
                                                  (file-relative-name
                                                   file-path
                                                   org-roam-directory)))
                   (org-roam--parse-content (file) (with-temp-buffer
                                                     (insert-file-contents file)
                                                     (with-current-buffer (current-buffer)
                                                       (org-element-map (org-element-parse-buffer) 'link
                                                         (lambda (link)
                                                           (let ((type (org-element-property :type link))
                                                                 (path (org-element-property :path link))
                                                                 (start (org-element-property :begin link)))
                                                             (when (and (string= type "file")
                                                                        (string= (file-name-extension path) "org"))
                                                               (goto-char start)
                                                               (let* ((element (org-element-at-point))
                                                                      (content (buffer-substring
                                                                                (or (org-element-property :content-begin element)
                                                                                    (org-element-property :begin element))
                                                                                (or (org-element-property :content-end element)
                                                                                    (org-element-property :end element)))))
                                                                 (list file
                                                                       (expand-file-name path org-roam-directory)
                                                                       (string-trim content))))))))))
                   (org-roam--build-backlinks (items) (mapcar
                                                       (lambda (item)
                                                         (pcase-let ((`(,file ,path ,content) item))
                                                           (let* ((link-id (org-roam--get-id path))
                                                                  (backlink-id (org-roam--get-id file))
                                                                  (contents-hash (gethash link-id backlinks)))
                                                             (if contents-hash
                                                                 (if-let ((contents-list (gethash backlink-id contents-hash)))
                                                                     (let ((updated (cons content contents-list)))
                                                                       (puthash backlink-id updated contents-hash)
                                                                       (puthash link-id contents-hash backlinks))
                                                                   (puthash backlink-id (list content) contents-hash)
                                                                   (puthash link-id contents-hash backlinks))
                                                               (let ((contents-hash (make-hash-table :test #'equal)))
                                                                 (puthash backlink-id (list content) contents-hash)
                                                                 (puthash link-id contents-hash backlinks))))))
                                                       items)))
          (mapcar #'org-roam--build-backlinks
                  (mapcar #'org-roam--parse-content org-roam-files)))
        (prin1-to-string backlinks)))
   (lambda (backlinks)
     (setq org-roam-cache (car (read-from-string
                                backlinks)))
     (org-roam--maybe-update-buffer))))


;;; Org-roam daily notes
(defun org-roam--new-file-named (slug)
  "Create a new file named `SLUG'.
`SLUG' is the short file name, without a path or a file extension."
  (interactive "sNew filename (without extension): ")
  (find-file (org-roam--get-file-path slug)))

(defun org-roam-today ()
  "Create the file for today."
  (interactive)
  (org-roam--new-file-named (format-time-string "%Y-%m-%d" (current-time))))

(defun org-roam-tomorrow ()
  "Create the file for tomorrow."
  (interactive)
  (org-roam--new-file-named (format-time-string "%Y-%m-%d" (time-add 86400 (current-time)))))

(defun org-roam-date ()
  "Create the file for any date using the calendar."
  (interactive)
  (let ((time (org-read-date nil 'to-time nil "Date:  ")))
    (org-roam--new-file-named (format-time-string "%Y-%m-%d" time))))

;;; Org-roam buffer updates
(defun org-global-props (&optional property buffer)
  "Get the plists of global org properties of current buffer."
  (unless property (setq property "PROPERTY"))
  (with-current-buffer (or buffer (current-buffer))
    (org-element-map (org-element-parse-buffer) 'keyword (lambda (el) (when (string-match property (org-element-property :key el)) el)))))

(defun org-roam-update (link-id)
  "Show the backlinks for given org file `FILE'."
  (when org-roam-cache
    (let ((title (or (org-element-property :value (car (org-global-props "TITLE")))
                     link-id)))
      (with-current-buffer org-roam-buffer
        (let ((inhibit-read-only t)
              (file-path (org-roam--get-file-path-absolute link-id)))
          (erase-buffer)
          (when (not (eq major-mode 'org-mode))
            (org-mode))
          (make-local-variable 'org-return-follows-link)
          (setq org-return-follows-link t)
          (insert title)
          (insert "\n\n* Backlinks\n")
          (when-let (backlinks (gethash link-id org-roam-cache))
            (maphash (lambda (backlink-id contents)
                       (insert (format "** [[file:%s][%s]]\n" (org-roam--get-file-path backlink-id) backlink-id))
                       (dolist (content contents)
                         (insert (format "%s\n" org-roam-preview-content-delimiter))
                         (insert (s-replace "\n" " " content))
                         (insert (format "\n%s\n\n" org-roam-preview-content-delimiter))))
                     backlinks)))
        (read-only-mode 1)))
    (setq org-roam-current-file-id link-id)))

;;; Show/hide the org-roam buffer
(define-inline org-roam--current-visibility ()
  "Return whether the current visibility state of the org-roam buffer.
Valid states are 'visible, 'exists and 'none."
  (declare (side-effect-free t))
  (inline-quote
   (cond
    ((get-buffer-window org-roam-buffer) 'visible)
    ((get-buffer org-roam-buffer) 'exists)
    (t 'none))))

(defun org-roam--setup-buffer ()
  "Setup the `org-roam' buffer at the `org-roam-position'."
  (display-buffer-in-side-window
   (get-buffer-create org-roam-buffer)
   `((side . ,org-roam-position))))

(defun org-roam ()
  "Initialize `org-roam'.
1. Setup to auto-update `org-roam-buffer' with the correct information.
2. Starts the timer to asynchronously build backlinks.
3. Pops up the window `org-roam-buffer' accordingly."
  (interactive)
  (pcase (org-roam--current-visibility)
    ('visible (delete-window (get-buffer-window org-roam-buffer)))
    ('exists (org-roam--setup-buffer))
    ('none (org-roam--setup-buffer))))

;;; The minor mode definition that updates the buffer
(defun org-roam--enable ()
  (add-hook 'post-command-hook #'org-roam--maybe-update-buffer -100 t)
  (unless org-roam-update-timer
    (setq org-roam-update-timer
          (run-with-timer 0 (* org-roam-update-interval 60) 'org-roam--build-cache-async)))
  (org-roam--maybe-update-buffer))

(defun org-roam--disable ()
  (remove-hook 'post-command-hook #'org-roam--maybe-update-buffer)
  (when org-roam-update-timer
    (cancel-timer org-roam-update-timer)
    (setq org-roam-update-timer nil)))

(defun org-roam--maybe-update-buffer ()
  "Update `org-roam-buffer' with the necessary information.
This needs to be quick/infrequent, because this is run at
`post-command-hook'."
  (with-current-buffer (window-buffer)
    (when (and (get-buffer org-roam-buffer)
               (buffer-file-name (window-buffer))
               (not (string= org-roam-current-file-id (org-roam--get-id (file-truename (buffer-file-name (window-buffer))))))
               (member (file-truename (buffer-file-name (window-buffer))) (org-roam--find-all-files)))
      (org-roam-update (org-roam--get-id (buffer-file-name (window-buffer)))))))

(define-minor-mode org-roam-mode
  "Global minor mode to automatically update the org-roam buffer."
  :require 'org-roam
  (if org-roam-mode
      (org-roam--enable)
    (org-roam--disable)))

;;; Building the Graphviz graph
(defun org-roam-build-graph ()
  "Build graphviz graph output."
  (with-temp-buffer
    (insert "digraph {\n")
    (mapcar (lambda (file)
              (insert
               (format "  \"%s\" [URL=\"roam://%s\"];\n"
                       (file-name-nondirectory (file-name-sans-extension file))
                       file)))
            (org-roam--find-all-files))
    (maphash
     (lambda (link-id backlinks)
       (maphash
        (lambda (backlink-id content)
          (insert (format "  \"%s\" -> \"%s\";\n" backlink-id link-id)))
        backlinks))
     org-roam-cache)
    (insert "}")
    (buffer-string)))

(defun org-roam-show-graph (&rest body)
  (interactive)
  (unless org-roam-graphviz-executable
    (setq org-roam-graphviz-executable (executable-find "dot")))
  (unless org-roam-graphviz-executable
    (user-error "Can't find graphviz executable. Please check if it is in your path"))
  (declare (indent 0))
  (let ((temp-dot (expand-file-name "graph.dot" temporary-file-directory))
        (temp-graph (expand-file-name "graph.svg" temporary-file-directory))
        (graph (org-roam-build-graph)))
    (with-temp-file temp-dot
      (insert graph))
    (call-process org-roam-graphviz-executable nil 0 nil temp-dot "-Tsvg" "-o" temp-graph)
    (call-process org-roam-graph-viewer nil 0 nil temp-graph)))



(provide 'org-roam)

;;; org-roam.el ends here

;; Local Variables:
;; outline-regexp: ";;;+ "
;; End:
