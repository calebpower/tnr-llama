;;; tnr-llama.el --- Manage tnr-based LLaMA servers -*- lexical-binding: t -*-

;; Copyright (C) 2026 Caleb L. Power <cpower@axonibyte.com>
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; Author: Axonibyte Innovations, LLC
;; Version: 0.1.2
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, processes, external
;; URL: https://github.com/yourusername/tnr-llama

;;; Commentary:

;; This package provides an interactive Emacs interface to launch,
;; manage, and destroy tnr-based LLaMA servers. It establishes
;; SSH tunnels and manages remote supervisor scripts asynchronously.

;;; Code:

(require 'json)
(require 'seq)

(defgroup tnr-llama nil
  "Manage tnr-based LLaMA servers."
  :group 'external)

;;; Customizable Variables

(defcustom tnr-llama-bin-path "tnr"
  "Path to the tnr executable. Can be an absolute path or just \"tnr\"."
  :type 'string)

(defcustom tnr-llama-mode "prototyping"
  "Mode parameter for the tnr server."
  :type 'string)

(defcustom tnr-llama-gpu "a100"
  "GPU type for the tnr server."
  :type 'string)

(defcustom tnr-llama-num-gpus 1
  "Number of GPUs to allocate."
  :type 'integer)

(defcustom tnr-llama-vcpus 4
  "Number of vCPUs to allocate."
  :type 'integer)

(defcustom tnr-llama-primary-disk 100
  "Size of the primary disk in GB."
  :type 'integer)

(defcustom tnr-llama-ephemeral-disk 30
  "Size of the ephemeral disk in GB."
  :type 'integer)

(defcustom tnr-llama-snapshot "llama-snapshot"
  "The template snapshot name to look for and deploy."
  :type 'string)

(defcustom tnr-llama-remote-script "/home/ubuntu/supervisor.sh"
  "Path to the remote script to execute in the background upon launch."
  :type 'string)

(defcustom tnr-llama-port 8080
  "Port to tunnel from localhost to the remote server."
  :type 'integer)

(defcustom tnr-llama-ssh-user "ubuntu"
  "The SSH username used to connect to the remote server."
  :type 'string)

(defcustom tnr-llama-idle-grace 600
  "Number of seconds the LLaMA server can be idle before termination."
  :type 'integer)

;;; Internal Variables

(defvar tnr-llama--ephemeral-key nil
  "In-memory storage of the ephemeral SSH private key.")

(defvar tnr-llama--ephemeral-key-file nil
  "Path to the temporary file containing the SSH private key.")

(defvar tnr-llama--tunnel-process nil
  "Stores the active SSH tunnel process so it can be managed and killed.")

(defvar tnr-llama--poll-timer nil
  "Timer object for background status polling.")

(defvar tnr-llama--polling-state nil
  "Tracks the background launch state. Can be `server' or `llama'.")

;;; Internal Helper Functions

(defun tnr-llama--get-key-file ()
  "Return the path to the temporary key file, creating it if necessary."
  (when tnr-llama--ephemeral-key
    (unless (and tnr-llama--ephemeral-key-file
                 (file-exists-p tnr-llama--ephemeral-key-file))
      (setq tnr-llama--ephemeral-key-file (make-temp-file "tnr-key-"))
      (set-file-modes tnr-llama--ephemeral-key-file #o600)
      (with-temp-file tnr-llama--ephemeral-key-file
        (insert tnr-llama--ephemeral-key)))
    tnr-llama--ephemeral-key-file))

(defun tnr-llama--cleanup-key-file ()
  "Delete the temporary key file if it exists."
  (when (and tnr-llama--ephemeral-key-file
             (file-exists-p tnr-llama--ephemeral-key-file))
    (delete-file tnr-llama--ephemeral-key-file)
    (setq tnr-llama--ephemeral-key-file nil)))

(defun tnr-llama--get-servers ()
  "Fetch the status of servers using \"tnr status --json\".
Returns a list of alists for any server matching `tnr-llama-snapshot'."
  (let* ((cmd (format "%s status --json 2>/dev/null" tnr-llama-bin-path))
         (json-string (string-trim (shell-command-to-string cmd))))
    (if (or (string-empty-p json-string)
            (not (string-prefix-p "[" json-string)))
        nil
      (condition-case nil
          (let ((json-array-type 'list)
                (json-object-type 'alist))
            (seq-filter
             (lambda (srv)
               (string= (alist-get 'template srv) tnr-llama-snapshot))
             (json-read-from-string json-string)))
        (error nil)))))

(defun tnr-llama--stop-polling ()
  "Cancel the background polling timer."
  (when (timerp tnr-llama--poll-timer)
    (cancel-timer tnr-llama--poll-timer)
    (setq tnr-llama--poll-timer nil)))

(defun tnr-llama--check-and-finish-setup ()
  "Fired by timer. Operates in two stages based on `tnr-llama--polling-state':
Stage 1 (`server'): Checks if server is RUNNING, executes script, builds tunnel.
Stage 2 (`llama'): Checks if /tmp/llama.ready exists on the remote server."
  (let* ((servers (tnr-llama--get-servers))
         (srv (car servers)))
    (when srv
      (let ((status (alist-get 'status srv))
            (ip (alist-get 'ip srv))
            (ssh-port (or (alist-get 'port srv) 22)))
        (cond
         ;; 1. ERROR/FAILURE STATE
         ((member status '("ERROR" "FAILED" "STOPPED"))
          (tnr-llama--stop-polling)
          (message "tnr-llama: Error - Server entered '%s' state during launch. Cleaning up..." status)
          (tnr-llama-destroy))

         ;; 2. SUCCESS STATE (RUNNING)
         ((string= status "RUNNING")
          (cond
           ;; STAGE 1: Wait for server to boot, establish connections
           ((eq tnr-llama--polling-state 'server)
            (if (not ip)
                (progn
                  (message "tnr-llama: Error - Server is RUNNING, but no IP address was found. Cleaning up...")
                  (tnr-llama-destroy))
              
              (message "tnr-llama: Server is RUNNING! Executing script and tunneling...")
              (let* ((key-file (tnr-llama--get-key-file))
                     (key-arg (if key-file (format "-i %s " key-file) ""))
                     (ssh-cmd (format "ssh -p %s %s-o StrictHostKeyChecking=accept-new -o BatchMode=yes %s@%s 'nohup %s %d %d %s </dev/null > /dev/null 2>&1 &'"
                                      ssh-port key-arg tnr-llama-ssh-user ip tnr-llama-remote-script tnr-llama-idle-grace tnr-llama-port tnr-llama-snapshot))
                     (ssh-exit-code (shell-command ssh-cmd)))
                
                (if (/= ssh-exit-code 0)
                    (progn
                      (message "tnr-llama: Error - SSH connection or auth failed (exit code %d). Cleaning up..." ssh-exit-code)
                      (tnr-llama-destroy))
                  
                  ;; SSH Success -> Establish Tunnel
                  (when (process-live-p tnr-llama--tunnel-process)
                    (kill-process tnr-llama--tunnel-process))
                  (let ((ssh-args (delq nil 
                                        (list "ssh" "-p" (format "%s" ssh-port) "-N" "-L" (format "%d:localhost:%d" tnr-llama-port tnr-llama-port)
                                              "-o" "StrictHostKeyChecking=accept-new" "-o" "BatchMode=yes"
                                              (when key-file "-i")
                                              (when key-file key-file)
                                              (format "%s@%s" tnr-llama-ssh-user ip)))))
                    (setq tnr-llama--tunnel-process (apply #'start-process "tnr-llama-tunnel" "*tnr-llama-tunnel*" ssh-args)))
                  
                  ;; Advance to Stage 2: Wait for Llama
                  (setq tnr-llama--polling-state 'llama)
                  (message "tnr-llama: Tunnel open. Waiting for Llama to become ready...")))))

           ;; STAGE 2: Wait for the lockfile
           ((eq tnr-llama--polling-state 'llama)
            (let* ((key-file (tnr-llama--get-key-file))
                   (key-arg (if key-file (format "-i %s " key-file) ""))
                   (ssh-test-cmd (format "ssh -p %s %s-o StrictHostKeyChecking=accept-new -o BatchMode=yes %s@%s 'test -f /tmp/llama.ready'"
                                         ssh-port key-arg tnr-llama-ssh-user ip))
                   (ssh-exit-code (call-process-shell-command ssh-test-cmd nil nil nil)))
              
              ;; `test -f` returns 0 if the file exists, 1 if it doesn't
              (when (= ssh-exit-code 0)
                (tnr-llama--stop-polling)
                (setq tnr-llama--polling-state nil)
                (message "tnr-llama: Success! Server is ready, script is running, tunnel is open, and Llama is answering!")))))))))))

;;; Interactive Commands

;;;###autoload
(defun tnr-llama-status ()
  "Check the current status of the tnr-llama server and SSH tunnel."
  (interactive)
  (let* ((servers (tnr-llama--get-servers))
         (existing (car servers))
         (tunnel-active (process-live-p tnr-llama--tunnel-process)))
    (if (not existing)
        (message "tnr-llama: No server found for snapshot '%s'." tnr-llama-snapshot)
      (let ((status (alist-get 'status existing))
            (ip (alist-get 'ip existing))
            (ssh-port (or (alist-get 'port existing) 22)))
        (message "tnr-llama: Server is [%s] at %s:%s | Tunnel is [%s]"
                 status 
                 (or ip "Unknown IP")
                 ssh-port
                 (if tunnel-active "ACTIVE" "INACTIVE"))))))

;;;###autoload
(defun tnr-llama-script-restart ()
  "Kill the remote script and llama, restart the script, and resume polling.
Useful for debugging script issues without redeploying the server."
  (interactive)
  (let* ((servers (tnr-llama--get-servers))
         (existing (car servers)))
    (if (not existing)
        (message "tnr-llama: No server found to restart script on.")
      (let ((ip (alist-get 'ip existing))
            (status (alist-get 'status existing))
            (ssh-port (or (alist-get 'port existing) 22)))
        (if (not (string= status "RUNNING"))
            (message "tnr-llama: Server is not RUNNING (status: %s). Cannot restart script." status)
          (if (not ip)
              (message "tnr-llama: Server is RUNNING but no IP address was found.")
            (message "tnr-llama: Attempting to restart script '%s' on %s:%s..." tnr-llama-remote-script ip ssh-port)
            (let* ((script-name (file-name-nondirectory tnr-llama-remote-script))
                   (safe-pkill-name (concat "[" (substring script-name 0 1) "]" (substring script-name 1)))
                   (key-file (tnr-llama--get-key-file))
                   (key-arg (if key-file (format "-i %s " key-file) ""))
                   (ssh-base (format "ssh -p %s %s-o StrictHostKeyChecking=accept-new -o BatchMode=yes %s@%s" 
                                     ssh-port key-arg tnr-llama-ssh-user ip))
                   ;; Kills supervisor, kills llama-server, and deletes the lock file
                   (ssh-kill-cmd (format "%s 'pkill -f \"%s\" || true; pkill -f \"[l]lama-server\" || true; rm -f /tmp/llama.ready'" 
                                         ssh-base safe-pkill-name))
                   ;; Pass the tnr-llama-idle-grace argument when restarting
                   (ssh-start-cmd (format "%s 'nohup %s %d %d %s </dev/null > /dev/null 2>&1 &' 2>&1" ssh-base tnr-llama-remote-script tnr-llama-idle-grace tnr-llama-port tnr-llama-snapshot)))
              
              (message "tnr-llama: Stopping existing script and llama...")
              (call-process-shell-command ssh-kill-cmd nil nil nil)
              
              (message "tnr-llama: Starting script...")
              (with-temp-buffer
                (let ((ssh-exit-code (call-process-shell-command ssh-start-cmd nil t nil)))
                  (if (/= ssh-exit-code 0)
                      (let ((output (string-trim (buffer-string))))
                        (message "tnr-llama: Error (code %d) starting script - %s" ssh-exit-code output))
                    
                    ;; If successful, start the timer to wait for Llama to become ready again
                    (message "tnr-llama: Script restarted. Polling for Llama readiness...")
                    (tnr-llama--stop-polling)
                    (setq tnr-llama--polling-state 'llama)
                    (setq tnr-llama--poll-timer (run-with-timer 5 5 #'tnr-llama--check-and-finish-setup))))))))))))

;;;###autoload
(defun tnr-llama-launch ()
  "Launch a tnr-llama server in the background.
Polls asynchronously until the server is RUNNING, then launches a script
and establishes an SSH tunnel."
  (interactive)
  (let* ((servers (tnr-llama--get-servers))
         (existing (car servers)))
    (if existing
        (message "tnr-llama: Server already exists with status: %s" (alist-get 'status existing))
      (message "tnr-llama: Launching server...")
      (let ((cmd (format "%s create --mode %s --gpu %s --num-gpus %d --vcpus %d --primary-disk %d --ephemeral-disk %d --snapshot %s --json 2>/dev/null"
                         tnr-llama-bin-path
                         tnr-llama-mode
                         tnr-llama-gpu
                         tnr-llama-num-gpus
                         tnr-llama-vcpus
                         tnr-llama-primary-disk
                         tnr-llama-ephemeral-disk
                         tnr-llama-snapshot)))
        
        (message "tnr-llama: Running command -> %s" cmd)
        
        (let ((output (shell-command-to-string cmd)))
          (let ((json-start (string-match-p "{" output)))
            (if (not json-start)
                (message "tnr-llama: Error - No JSON payload found. Output was: %s" output)
              (condition-case err
                  (let* ((json-object-type 'alist)
                         (json-array-type 'list)
                         (json-string (substring output json-start))
                         (data (json-read-from-string json-string))
                         (key (alist-get 'key data)))
                    (if (not key)
                        (message "tnr-llama: Error - Failed to extract SSH key. Output was: %s" output)
                      (setq tnr-llama--ephemeral-key key)
                      (tnr-llama--stop-polling)
                      (setq tnr-llama--polling-state 'server)
                      (setq tnr-llama--poll-timer (run-with-timer 5 5 #'tnr-llama--check-and-finish-setup))
                      (message "tnr-llama: Launch initiated. Polling status in the background...")))
                (error
                 (message "tnr-llama: Error parsing JSON from launch command: %s" err))))))))))

;;;###autoload
(defun tnr-llama-reconnect ()
  "Reconnect the SSH tunnel to the tnr-llama server.
Useful if Emacs was restarted but the remote server is still running."
  (interactive)
  (let* ((servers (tnr-llama--get-servers))
         (existing (car servers)))
    (if (not existing)
        (message "tnr-llama: No server found to reconnect to.")
      (let ((ip (alist-get 'ip existing))
            (status (alist-get 'status existing))
            (ssh-port (or (alist-get 'port existing) 22)))
        (if (not (string= status "RUNNING"))
            (message "tnr-llama: Server is not RUNNING (status: %s). Cannot reconnect tunnel." status)
          (if (not ip)
              (message "tnr-llama: Server is RUNNING but no IP address was found.")
            (message "tnr-llama: Re-establishing SSH tunnel to %s:%s..." ip ssh-port)
            
            ;; Clean up the old tunnel process if it exists
            (when (process-live-p tnr-llama--tunnel-process)
              (kill-process tnr-llama--tunnel-process))
            
            ;; Start a fresh tunnel
            (let* ((key-file (tnr-llama--get-key-file))
                   (ssh-args (delq nil
                                   (list "ssh" "-p" (format "%s" ssh-port) "-N" "-L" (format "%d:localhost:%d" tnr-llama-port tnr-llama-port)
                                         "-o" "StrictHostKeyChecking=accept-new" "-o" "BatchMode=yes"
                                         (when key-file "-i")
                                         (when key-file key-file)
                                         (format "%s@%s" tnr-llama-ssh-user ip)))))
              (setq tnr-llama--tunnel-process (apply #'start-process "tnr-llama-tunnel" "*tnr-llama-tunnel*" ssh-args))
              (message "tnr-llama: Tunnel reconnected on port %d!" tnr-llama-port))))))))

;;;###autoload
(defun tnr-llama-destroy ()
  "Destroy all TNR servers matching the configured snapshot.
Also kills the associated SSH tunnel."
  (interactive)
  (tnr-llama--stop-polling)
  (setq tnr-llama--polling-state nil)
  
  (when (process-live-p tnr-llama--tunnel-process)
    (message "tnr-llama: Closing SSH tunnel...")
    (kill-process tnr-llama--tunnel-process)
    (setq tnr-llama--tunnel-process nil))

  (tnr-llama--cleanup-key-file)
  (setq tnr-llama--ephemeral-key nil)

  (let ((servers (tnr-llama--get-servers)))
    (if (null servers)
        (message "tnr-llama: No server suitable for deletion exists.")
      (dolist (srv servers)
        (let ((id (alist-get 'id srv)))
          (when id
            (message "tnr-llama: Waiting 5 seconds before deleting server ID %s to prevent rate limiting..." id)
            (sleep-for 5)
            (shell-command (format "%s delete %s -y" tnr-llama-bin-path id)))))
      (message "tnr-llama: Deletion request dispatched."))))

(provide 'tnr-llama)
;;; tnr-llama.el ends here
