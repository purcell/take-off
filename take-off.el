;;; take-off.el --- Emacs remote web access

;; Author: Thomas Burette <burettethomas@gmail.com>
;; Maintainer: Thomas Burette <burettethomas@gmail.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "24.3") (web-server "0.1.0"))
;; URL: https://github.com/tburette/take-off

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:
;;
;; A remote web access to emacs.
;;
;; Starts a web server allowing access to emacs through a webpage.
;; There is no security in this module at all! If you plan to use this
;; on a non local, secure network you must secure the access yourself.
;; To secure you can use an SSH tunnel, an SSH SOCKS proxy or a reverse
;; HTTPS proxy.
;;
;; If the error 'Caught Error: (void-function symbol-macrolet)' occurs
;; you need to execute '(require 'cl)' before using take-off. This issue
;; is fixed in emacs 24.4.
;;
;; The following starts the web-server:
;;
;; (take-off-start <port>)
;;
;; To stop the server:
;;
;; (take-off-stop)
;;
;; emacs will be available at : http://<address>:<port>/emacs.html
;;
;;; Code :

(require 'cl)
(require 'json)
(require 'web-server)

(defvar take-off-web-socket-process nil
  "web-server process of the web socket.")

(defvar take-off-server nil
  "Web server")

(defvar take-off-docroot (file-name-directory load-file-name))

(defun take-off-static-files (request)
  "Handler that serves all the static files"
      (with-slots (process headers) request
	(let ((serve-path (expand-file-name (concat take-off-docroot "front")))
	      (path (substring (cdr (assoc :GET headers)) 1)))
	  (if (ws-in-directory-p serve-path path)
	      (if (file-directory-p path)
		  (ws-send-directory-list process
		    (expand-file-name path serve-path) "^[^\.]")
		
		(ws-send-file process (expand-file-name path serve-path)))
	    (ws-send-404 process)))
      ))

(defun take-off-set-window-pos (window hashtable)
  (mapcar*;zip
   (lambda (key val)
     (puthash key val hashtable)
     )
  '(:left :top :right :bottom)
  (window-inside-edges window))
  hashtable
)

(defun take-off-set-point-pos (window hashtable)
  "Add window's point location to hashtable if window is the current window"
  (if (eq window (selected-window))
   (let* ((pointhash (make-hash-table))
	  (inside-edges (window-inside-edges))
	  (left (car inside-edges))
	  (top (cadr inside-edges))
	  ;position of point relative to the window
	  (pos-point-relative (pos-visible-in-window-p (window-point window) window t))
	  ;compute x y of point in abolute (relative to frame)
	  (x-point (+ left (car pos-point-relative)))
	  (y-point (+ top (cadr pos-point-relative)))
	  )
     (puthash
      :point
      pointhash
      hashtable)
     (puthash :x (car pos-point-relative) pointhash)
     (puthash :y (cadr pos-point-relative) pointhash)
  )))

;json encode : hashtable become js object
(defun take-off-visible-data ()
  "Return a json value representing the current visible state of emacs"
  (let ((windows-data (make-hash-table)))
    (puthash :width (frame-width) windows-data)
    (puthash :height (frame-height) windows-data)
    (puthash :windows
      (mapcar
       (lambda (window)
	 (with-current-buffer (window-buffer window)
  	   (let ((hash (make-hash-table)))
	     (take-off-set-window-pos window hash)
	     (take-off-set-point-pos window hash)
			     (puthash :tabWidth
		      tab-width
		      hash)
	     (puthash :text
		 ;TODO window-end can be wrong
		 ;https://github.com/rolandwalker/window-end-visible
	       (buffer-substring-no-properties 
		(window-start window) 
		(window-end window))
	       hash)
	     (puthash :modeLine
	       (format-mode-line mode-line-format t window)
	       hash)
	     hash
	     )))
       (window-list))
      windows-data)
    (json-encode windows-data))
  )

(defun take-off-web-socket-receive (proc string)
  "Handle web-socket requests sent by the browser agent"
  (let* ((json (condition-case nil
		   (json-read-from-string string)
		 (end-of file nil)
		 ))
	 (key (when (assoc 'key json) (cdr (assoc 'key json))))
	 (code (when (assoc 'code json) (cdr (assoc 'code json)))))
    (when key
      (execute-kbd-macro (kbd key))
    )
    (when code
      (eval-expression (read code))
    )
    (process-send-string proc
			 (ws-web-socket-frame (take-off-visible-data) ))
  )
)

(defun take-off-change-hook-function (beginning end length)
  (if take-off-web-socket-process
      (process-send-string take-off-web-socket-process
  			   (ws-web-socket-frame (take-off-visible-data) )))
)
	   
(defun take-off-web-socket-connect (request)
  "Open a web socket connection
Assumes request is a web socket connection request."
  (with-slots (process headers) request
    (if (ws-web-socket-connect 
	 request
	 'take-off-web-socket-receive)
	(prog1 
	  :keep-alive;prevent closing the connection immediatly after request
	  (setq take-off-web-socket-process process)
	  ;the hook is called after each character insertion.
	  ;as-is the client is flooded with data
	  ;shoud buffer before sending
	  ;(add-hook 'after-change-functions 'take-off-change-hook-function t)
	)
        (ws-response-header process 501 '("Content-Type" . "text/html"))
	(ws-send process "Unable to create socket"))))

(defun take-off-is-socket-request (request)
  (string-prefix-p "/socket" (cdr (assoc :GET (oref request headers)))))

;;;###autoload
(defun take-off-start (port)
  "Start a web server that allows remote web access to emacs."
  (interactive)
  (setq take-off-server
	(ws-start
	 '(
	   (take-off-is-socket-request .
				       take-off-web-socket-connect)
	   ((:GET . ".*") .  take-off-static-files)
	   ((lambda (request) t).
	    (lambda (request)
	      (with-slots (process headers) request
		(ws-response-header process
				    200
				    '("Content-Type" . "text/plain"))
		(process-send-string process "Default handler\n")))
	    )
	   )

	 port)))

;;;###autoload
(defun take-off-stop ()
  "Stop the web server."
  (interactive)
  (when take-off-server
  (ws-stop take-off-server)
  (setq take-off-server nil)
  (if take-off-web-socket-process
      (remove-hook 'after-change-functions 'take-off-change-hook-function))
  (setq take-off-web-socket-process nil)))


(provide 'take-off)

