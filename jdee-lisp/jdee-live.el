;;; jdee-live.el --- The JVM backend for JDE. -*- lexical-binding: t -*-

;; Version: 0.1
;; Package-Requires: ((cider "20151020.646")(load-relative "20150224.1722"))

;;; Commentary:
;;  Nrepl backend


;;; Code:
;; The contents of this file are subject to the GPL License, Version 3.0.
(require 'cider)
(require 'load-relative)
(require 'dash)

(defconst jdee-live-version "0.1-SNAPSHOT")

(defgroup jdee-live nil
  "Parameters for how the connection to the nREPL backend is made"
  :group 'jdee
  :prefix "jdee-live-")

(defcustom jdee-live-timeout 20
  "Time (in seconds) to wait for a response from the nREPL."
  :type 'number
  :group 'jdee-live
  :package-version '("jdee-live" . "0.1"))

(defcustom jdee-live-mvn-args nil
  "Additional args to pass to mvn when using mvn to start the nREPL.
This should be a list of strings.  No quoting is done of the values."
  :type '(repeat (string :tag "Command line arg"))
  :group 'jdee-live
  :package-version '("jdee-live" . "0.1"))

(defvar jdee-live-nrepl-alist nil
  "Mapping from pom files to the corresponding nREPL objects.")

(defvar jdee-live-launch-script
  ;; When packaged for MELPA, files get moved around
  (let ((script-1 (relative-expand-file-name "../jdee-live/clj/jdee-launch-nrepl.clj"))
        (script-2(relative-expand-file-name "clj/jdee-launch-nrepl.clj")))
    (if (file-exists-p script-2) script-2 script-1)))

(defun jdee-live-project-directory-for (dir-name)
  "Find the first directory in DIR-NAME contain a pom.xml.
This is the root of the maven project."
  (when dir-name
    (locate-dominating-file dir-name "pom.xml")))

(defun jdee-live-nrepl-available ()
  "Test if there is an nREPL available for use.
Also starts the nREPL if it exists.  This will return true if we
can find the pom.xml and either the server is already running or
we are able to successfully start it."

  (and (jdee-live-project-directory-for (cider-current-dir))
       (or (jdee-live-connected-p)
           (progn
             (jdee-live-jack-in)
             (jdee-live-connected-p)))))

(defclass jdee-live-nrepl ()
  ((client :type buffer
           :documentation "nREPL client process")
   (server :type process
           :documentation "nREPL server process")
   (key :type symbol
        :documentation "Key for lookup up this object")
   (response :type (or null string symbol)
             :initform nil
             :documentation "Response received from an eval request")
   (eval-filter :type function
                :documentation "Filter for evaluating function calls")
   (server-filter :type function
                  :documentation "Filter for evaluating output from server.
Used to determine when server is up and what port it is using.")))

(defmethod jdee-live-nrepl-get-session ((this jdee-live-nrepl))
  "The session is stored as a buffer-local variable in the client buffer"

  (when (slot-boundp this 'client)
    (with-current-buffer (oref this client)
      nrepl-session)))

(defmethod initialize-instance ((this jdee-live-nrepl) &rest args)
  "Constructor.
Sets fields to null and adds it to the nREPL registry."

  ;; Parent initialize-instance
  (call-next-method)

  (oset this key
        (intern (jdee-live-project-directory-for (cider-current-dir))))

  ;; Pass this to the filters, so it knows how to send back the response
  (oset this eval-filter
        (lambda (process output)
          (jdee-live-eval-filter process output this)))
  (oset this server-filter
        (lambda (process output)
          (jdee-live-server-filter process output this)))

  ;; Add to the registry.  Remove any existing entry.
  (-when-let (old-nrepl-cons (assq (oref this key) jdee-live-nrepl-alist))
    (jdee-live-nrepl-shutdown (cdr old-nrepl-cons)))
  (add-to-list 'jdee-live-nrepl-alist (cons (oref this key) this))
  (setq jdee-live-nrepl-alist
        (cl-remove-duplicates jdee-live-nrepl-alist
                              :key #'car
                              :from-end t)))



(defmethod jdee-live-nrepl-connect ((this jdee-live-nrepl) async)
  "Start the nREPL and connect to it."

  (with-slots (server server-filter key response) this
    (let ((project-dir (symbol-name key)))
      (-when-let (repl-buff (cider-find-reusable-repl-buffer nil project-dir))
        (let* ((nrepl-create-client-buffer-function #'cider-repl-create)
               (nrepl-use-this-as-repl-buffer repl-buff)
               (serv-proc
                (nrepl-start-server-process
                 project-dir
                 ;; TODO: FIXME: generalise!
                 (format
                  (concat "mvn jdee:jdee-maven-nrepl:java "
                          "-Dexec.mainClass=\"clojure.main\""
                          " -Dexec.args=\"%s\""
                          " -Dexec.includePluginsDependencies=true "
                          (mapconcat #'identity jdee-live-mvn-args " ")
                          )
                  jdee-live-launch-script)
                 (lambda (client-buf)
                   (oset this client client-buf)
                   (oset this response 'connected)))))
          (message "Starting nrepl server with mvn for %s" project-dir)
          (setq server serv-proc)
          ;; FIXME: clojure:nrepl drops strange strings out!

          ;; FIXME: There is a race condition here, if the server finishes
          ;; initalizing before the process filter is set.  I have only seen
          ;; this with the mvn build when debugging, so it is unlikely to be a
          ;; real-world problem unless we get a nREPL that starts much faster.
          ;;
          ;; On the up side, it seems that the nREPL is available and
          ;; functioning after the error.   -td 10/27/15 12:38am.
          (set-process-filter server server-filter)
          (if async
              (setq response 'initializing)
            (jdee-live-nrepl-wait-for-server-ready this))
          )))))

(defun jdee-live--get-nrepl ()
  "Get the nREPL class for this buffer.
This is shared by all classes under the pom.  Will return nil if
there is no pom or the nREPL has not been started."
  (let* ((project-dir (jdee-live-project-directory-for (cider-current-dir))))
    (when project-dir
      (cdr-safe (assq (intern project-dir) jdee-live-nrepl-alist)))))

(defmethod jdee-live-nrepl-shutdown ((this jdee-live-nrepl))
  "Shutdown the nREPL.
Stops the associated processes and removes it from the nREPL registry."

  (with-slots ( client server key ) this
    ;; Remove the server sentinal, so it does not issue error messages during
    ;; the shutdown
    (when (and (slot-boundp this 'server)
               (processp server)
               (process-live-p server))
      (set-process-filter server nil))

    ;; Gracefully shutdown the client.
    (let ((client-proc
           (and (slot-boundp this 'client)
                client
                (get-buffer-process client))))
      (when (process-live-p client-proc)
        (cider-quit)
        (kill-buffer client)))


    ;; Kill the server process
    ;; (unwind-protect
    ;;     (when (and (slot-boundp this 'server)
    ;;                (processp server)
    ;;                (process-live-p server))
    ;;       (signal-process server 'kill))
    ;;   (message "Unable to kill server"))

    ;; Remove it from the lookup table
    (setq jdee-live-nrepl-alist
          (assq-delete-all (oref this key) jdee-live-nrepl-alist))))


(defun jdee-live-stop-nrepl ()
  "Stop the nREPL for this project."
  (interactive)
  (let ((nrepl (jdee-live--get-nrepl)))
    (when nrepl
      (jdee-live-nrepl-shutdown nrepl))))

(defun jdee-live-connected-p ()
  "Test if there is a live server process for this buffer."
  (let ((nrepl (jdee-live--get-nrepl)))
    (and nrepl
         (slot-boundp nrepl 'server)
         (slot-boundp nrepl 'client)
         (not (eq (oref nrepl response) 'initializing))
         (let ((client-proc (get-buffer-process (oref nrepl client))))
           (and client-proc
                (process-live-p client-proc))))))


(defun jdee-live-eval (statement) ; &optional eval-return no-print-p)
  "Use the jdee-live nREPL to evaluate the Clojure expression EXPR.
If the
nREPL is not running, the JDEE starts an instance.  This function
returns any text output by the nREPL's standard out or
standard error pipes from evaluating STATEMENT.
If EVAL-RETURN is non-nil, this function
returns the result of evaluating the output as a Lisp
expression."

;; Copied from bsh version.  Not clear if this is relevant.

;; NO-PRINT-P, if non-nil, don't wrap STATEMENT with a `print'
;; command yeilding the output.  This is going to need to be true
;; for most things since unless `show()' was invoked and output
;; prints out, Emacs has nothing to evaluate or report."

  (interactive "sClojure to evaluate ")
  (when (jdee-live-nrepl-available)
    (let* ((nrepl (jdee-live--get-nrepl))
           (session (jdee-live-nrepl-get-session nrepl)))
      (with-slots (client) nrepl
        (nrepl-dict-get
         (nrepl-sync-request:eval statement client session)
         "value")))))

(defun jdee-live--sync-request (op &optional name)
  "Returns the result of a named request OP on the nREPL.  The result is extracted with the key NAME, which defaults to OP"

  (when (jdee-live-nrepl-available)
    (cider-ensure-op-supported op)
    (let ((nrepl (jdee-live--get-nrepl)))
      (with-slots (client) nrepl
        (thread-first (list "op" op
                            "session" (jdee-live-nrepl-get-session nrepl))
          (cider-nrepl-send-sync-request client)
          (nrepl-dict-get (or name op)))))))


(defun jdee-live-sync-request:classpath ()
  "Get class path using cider, but ensure that we use the correct session.
Cider can find the wrong session since it looks for Clojure files
to find the project root."
  (when (jdee-live-nrepl-available)
    (let ((nrepl (jdee-live--get-nrepl)))
      (cl-letf (((symbol-function 'cider-current-connection) (lambda nil (oref nrepl client))))
        (cider-sync-request:classpath)))))

(defun jdee-live-sync-request:sourcepath ()
  "Returns a list of the source paths from the nREPL"

  (jdee-live--sync-request "sourcepath"))

(defun jdee-live-sync-request:parent-path ()
  "Returns the path to the parent project from the nREPL.
Returns nil if there is no parent"

  (jdee-live--sync-request "parent-path"))

(defun jdee-live-sync-request:child-paths ()
  "Returns a list of the child paths from the nREPL"

  (jdee-live--sync-request "child-paths"))



;;;###autoload
(defun jdee-live-jack-in (&optional async)
  "Start a maven process which connects to the nrepl client.
Check the versions of the middle ware.  If ASYNC is present and
non-nil, start creating the nREPL, but do not block until it is
available.

If the nrepl is initializing because it was created
asynchronously, it waits for the nrepl to be ready (unless ASYNC
is again true)."

  (interactive "P")
  (if (jdee-live-connected-p)
      (message "nREPL server already running")
    ;; Get the existing nrepl (if the process died) or create a new one
    (let ((nrepl (jdee-live--get-nrepl)))
      (if (and nrepl (eq (oref nrepl response) 'initializing))
          ;; Repl was create asynchronously and is not yet done initializing.
          ;; Wait for it to finish starting, unless it was again request
          ;; asynchronously
          (unless async (jdee-live-nrepl-wait-for-server-ready nrepl))
        ;; Repl does not exist or is not doing asynchonous initialization.

        (jdee-live-nrepl-connect (or nrepl (make-instance 'jdee-live-nrepl))
                                 async)))))

(defun jdee-live-suppress-cider-buffer (cider-buffer)
  "Keep the cider buffer from popping up when it it is ready.
The user is programming in java and does not want to see a clojure buffer."
  (with-current-buffer cider-buffer
    (let ((nrepl (jdee-live--get-nrepl)))
      (when nrepl
        (set (make-local-variable 'cider-repl-pop-to-buffer-on-connect) nil))))
  ;; Don't actually change the return value
  cider-buffer)

(advice-add 'cider-repl-create :filter-return #'jdee-live-suppress-cider-buffer)


(defmethod jdee-live-nrepl-wait-for-server-ready ((this jdee-live-nrepl))
  "Wait for SERV-PROC to be ready to accept input."
  (with-slots (response server) this
    (setq response nil)
    (while (not response)
      (if (not (accept-process-output server jdee-live-timeout))
          (error "No response from nREPL")
        (cond
         ;; Successfully connected
         ((eq 'connected response))
         ;; String return means an error occurred
         ((stringp response)
          (error "Unable to connect to nREPL server:\n%s"
                 response))
         (;; Partial output, continue waiting
          (not response))
         (t
          (error "Jdee-live--response set to unexpected value: %s"
                 response)))))))


(defun jdee-live-eval-filter (_process output nrepl)
  "Process nREPL server output from _PROCESS contained in OUTPUT during evaluation."

  (oset nrepl response (concat (oref nrepl response) output)))

(defun jdee-live-server-filter (process output nrepl)
  "Process nREPL server output from PROCESS contained in OUTPUT.
If an error occurs, it is reported o NREPL."
  (nrepl-server-filter process output)
  ;; Check for errors
  (when (string-match "BUILD FAILURE" output)
    (oset nrepl response output)))

;;;###autoload
(define-minor-mode jdee-live-mode
  "Minor mode for JVM/Clojure interaction from a Java buffer."
  )

(provide 'jdee-live)
;;; jdee-live.el ends here